import AppKit
import ApplicationServices

private final class HitWork {
    // Accessed only by the serial AX queue.
    var downHit = DockHit.unavailable
}

private struct CapturedPress {
    let press: DockPress
    let point: CGPoint
    let foregroundBefore: Bool
    let ordinaryWindowsBefore: Int
    let clickCount: Int
    let work: HitWork
    var hadModifiers: Bool
    var dragged = false
    var distance = 0.0
}

final class DockProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let status = NSTextField(labelWithString: "尚未开始观察")
    private let details = NSTextView()
    private let queue = DispatchQueue(label: "com.loomex.flow.p0.dock-hit", qos: .userInitiated)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var policy = DockClickPolicy(doubleClickInterval: NSEvent.doubleClickInterval)
    private var capture: CapturedPress?
    private var activeSequence: Int?
    private var observing = false
    private var primaryPressCount = 0
    private var unavailableHitCount = 0
    private var observations = [[String: Any]]()
    private var reportState = "idle"
    private let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
        saveReport()
    }

    private func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 490),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Loomex Dock Input Probe"
        panel.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "Dock 输入实验 · 只观察")
        heading.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(heading)
        let explanation = NSTextField(wrappingLabelWithString: "仅记录本实验应用的 Dock 图标。所有点击、右键和拖拽仍由系统处理，不会隐藏或最小化任何应用。开始后可点击本应用图标，比较点击前状态与判定。")
        stack.addArrangedSubview(explanation)
        stack.addArrangedSubview(status)
        let buttons = NSStackView()
        buttons.spacing = 8
        for (title, action) in [("开始观察", #selector(start)), ("停止观察", #selector(stop)),
                                ("辅助功能设置", #selector(openAccessibility)), ("输入监控设置", #selector(openInputMonitoring)),
                                ("进入无窗口场景", #selector(closeWindows))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = details
        stack.addArrangedSubview(scroll)
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
                explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        window = panel
        render()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func start() {
        stopObservation(state: "idle")
        guard AXIsProcessTrusted() else {
            reportState = "blocked_accessibility"
            status.stringValue = "等待本实验应用的辅助功能授权；未安装事件监听。"
            saveReport()
            return
        }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .otherMouseDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: mask,
                                             callback: { _, type, event, context in
            if let context {
                Unmanaged<DockProbeDelegate>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            reportState = "blocked_event_tap"
            status.stringValue = "只读鼠标监听不可用；请核对系统输入监控状态。"
            saveReport()
            return
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        observing = true
        reportState = "observing"
        status.stringValue = "正在只读观察自身 Dock 图标；单击等待 \(String(format: "%.2f", NSEvent.doubleClickInterval)) 秒确认。"
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AXIsProcessTrusted() { self.stopObservation(state: "permission_lost") }
        }
        saveReport()
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        // No AX, disk I/O, window control, event posting or synchronous queue waits in this callback.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { self.stopObservation(state: "tap_disabled") }
            return
        }
        guard observing else { return }
        let time = Double(event.timestamp) / 1_000_000_000
        let modified = !event.flags.intersection(modifierMask).isEmpty
        if type == .flagsChanged {
            if modified { capture?.hadModifiers = true }
            if modified && capture == nil { policy.cancel() }
            return
        }
        if type == .rightMouseDown || type == .otherMouseDown {
            _ = policy.begin(at: time)
            capture = nil
            return
        }
        if type == .leftMouseDown {
            primaryPressCount += 1
            let press = policy.begin(at: time)
            guard activeSequence == nil else { capture = nil; return }
            activeSequence = press.sequence
            let point = event.location
            let work = HitWork()
            capture = CapturedPress(press: press, point: point,
                foregroundBefore: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                ordinaryWindowsBefore: NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }.count,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), work: work, hadModifiers: modified)
            queue.async { work.downHit = self.hit(at: point) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard self.activeSequence == press.sequence else { return }
                self.capture = nil
                self.policy.cancel()
                // Keep the admission gate closed until the serial AX work has drained.
                self.queue.async {
                    DispatchQueue.main.async {
                        if self.activeSequence == press.sequence { self.activeSequence = nil }
                    }
                }
            }
        } else if type == .leftMouseDragged {
            capture?.dragged = true
            if modified { capture?.hadModifiers = true }
        } else if type == .leftMouseUp, var captured = capture {
            capture = nil
            captured.hadModifiers = captured.hadModifiers || modified
            captured.distance = hypot(event.location.x - captured.point.x, event.location.y - captured.point.y)
            let point = event.location
            let completed = captured
            queue.async {
                let down = completed.work.downHit
                let up = self.hit(at: point)
                let gesture = DockGesture(press: completed.press, upTime: time, downHit: down, upHit: up,
                    foregroundBefore: completed.foregroundBefore, ordinaryWindowsBefore: completed.ordinaryWindowsBefore,
                    hadModifiers: completed.hadModifiers, dragged: completed.dragged,
                    distance: completed.distance, clickCount: completed.clickCount)
                DispatchQueue.main.async {
                    guard self.activeSequence == completed.press.sequence else { return }
                    self.activeSequence = nil
                    guard self.observing else { return }
                    guard AXIsProcessTrusted() else { self.stopObservation(state: "permission_lost"); return }
                    if down == .unavailable || up == .unavailable { self.unavailableHitCount += 1 }
                    let result = self.policy.finish(gesture)
                    if case .fixture = down { self.record(result, gesture: gesture) }
                    if result == .pending {
                        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) {
                            guard self.observing, AXIsProcessTrusted() else { return }
                            guard NSApp.isActive, NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else {
                                self.policy.cancel()
                                return
                            }
                            guard let result = self.policy.settle(at: ProcessInfo.processInfo.systemUptime, for: gesture.press) else { return }
                            self.record(result, gesture: gesture)
                        }
                    }
                }
            }
        }
    }

    private func hit(at point: CGPoint) -> DockHit {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return .unavailable }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard AXUIElementSetMessagingTimeout(app, 0.2) == .success else { return .unavailable }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              let element else { return .unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == dock.processIdentifier,
              AXUIElementSetMessagingTimeout(element, 0.2) == .success else { return .unavailable }
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard attribute(kAXRoleAttribute) as? String == "AXDockItem",
              attribute(kAXSubroleAttribute) as? String == "AXApplicationDockItem" else { return .other }
        guard let url = attribute(kAXURLAttribute) as? URL else { return .unavailable }
        guard url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL else { return .other }
        guard !dock.isTerminated else { return .unavailable }
        return .fixture(dockPID: dock.processIdentifier)
    }

    private func record(_ decision: DockDecision, gesture: DockGesture) {
        observations.append(["decision": decision.rawValue, "foregroundBefore": gesture.foregroundBefore,
            "ordinaryWindowsBefore": gesture.ordinaryWindowsBefore, "dragged": gesture.dragged,
            "modified": gesture.hadModifiers, "clickCount": gesture.clickCount,
            "timestamp": ISO8601DateFormatter().string(from: Date())])
        if observations.count > 40 { observations.removeFirst(observations.count - 40) }
        render()
        saveReport()
    }

    private func render() {
        details.string = observations.map {
            "\($0["decision"] ?? "") | 点击前前台=\($0["foregroundBefore"] ?? false) 窗口=\($0["ordinaryWindowsBefore"] ?? 0) 拖动=\($0["dragged"] ?? false) 修饰键=\($0["modified"] ?? false)"
        }.joined(separator: "\n")
        if observations.isEmpty { details.string = "判定仅供实验，不执行收起动作。自身图标在正式产品中固定排除。\n无窗口场景：点击上方按钮关闭实验窗口，再点击 Dock 图标观察系统重新打开。" }
    }

    private func saveReport() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("dock-probe-result.json")
        let report: [String: Any] = ["status": reportState, "scope": "owned-probe-only", "eventTapMode": "listenOnly",
            "accessibilityGranted": AXIsProcessTrusted(), "listenEventAccess": CGPreflightListenEventAccess(),
            "eventTapInstalled": tap != nil, "primaryPressCount": primaryPressCount,
            "unavailableHitCount": unavailableHitCount,
            "observations": observations, "doubleClickInterval": NSEvent.doubleClickInterval,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { status.stringValue = "本地实验报告保存失败：\(error.localizedDescription)" }
    }

    private func stopObservation(state: String) {
        observing = false
        policy.cancel()
        capture = nil
        activeSequence = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        reportState = state
        status.stringValue = "已停止观察，未保留输入序列。"
        saveReport()
    }

    @objc private func stop() { stopObservation(state: "stopped") }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func closeWindows() { NSApp.windows.forEach { $0.close() } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { stopObservation(state: "stopped") }
}

let application = NSApplication.shared
let delegate = DockProbeDelegate()
application.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "退出 Dock 输入实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appItem = NSMenuItem()
appItem.submenu = appMenu
menu.addItem(appItem)
application.mainMenu = menu
application.delegate = delegate
application.run()
