import AppKit
import ApplicationServices

private final class HitWork {
    // Accessed only by the serial AX queue.
    var downHit = DockHit.unavailable
}

private final class TapContext {
    weak var owner: DockProbeDelegate?
    let token: DockObservationToken
    init(owner: DockProbeDelegate, token: DockObservationToken) {
        self.owner = owner
        self.token = token
    }
}

private struct CapturedPress {
    let press: DockPress
    let point: CGPoint
    let foregroundBefore: Bool
    let ordinaryWindowsBefore: Int
    let clickCount: Int
    let work: HitWork
    let actionContext: OwnedDockContext
    let observationToken: DockObservationToken
    var hadModifiers: Bool
    var dragged = false
    var distance = 0.0
}

final class DockProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var sampleWindow: NSWindow?
    private let actions = OwnedWindowActions()
    private let verifier = OwnedActionVerification()
    private let modePicker = NSPopUpButton()
    private var mode = OwnedDockMode.observe
    private let status = NSTextField(labelWithString: "尚未开始观察")
    private let details = NSTextView()
    private let queue = DispatchQueue(label: "com.loomex.flow.p0.dock-hit", qos: .userInitiated)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var tapContext: TapContext?
    private var session = DockObservationSession()
    private var workspaceObservers = [NSObjectProtocol]()
    private var displayObserver: NSObjectProtocol?
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
        observeEnvironment()
        showWindow()
        saveReport()
    }

    private func showWindow() {
        if let window {
            actions.register(window)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Loomex Dock Input Probe"
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "Dock 输入与自建窗口动作实验")
        heading.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(heading)
        let explanation = NSTextField(wrappingLabelWithString: "默认只观察自身 Dock 图标。选择动作模式后，仅操作本原型的 A/B 窗口；恢复只处理本次收起记录。所有输入仍放行，其他应用不参与实验。")
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
        let actionButtons = NSStackView()
        actionButtons.spacing = 8
        modePicker.addItems(withTitles: OwnedDockMode.allCases.map(\.title))
        modePicker.target = self
        modePicker.action = #selector(changeMode)
        actionButtons.addArrangedSubview(modePicker)
        actionButtons.addArrangedSubview(NSButton(title: "打开测试窗口 B", target: self, action: #selector(showSample)))
        actionButtons.addArrangedSubview(NSButton(title: "运行本地动作验证", target: self, action: #selector(verifyActions)))
        actionButtons.addArrangedSubview(NSButton(title: "验证监听启停", target: self, action: #selector(verifyListening)))
        stack.addArrangedSubview(actionButtons)
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
        actions.register(panel)
        render()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func start() {
        cancelVerification()
        stopObservation(state: "idle")
        guard AXIsProcessTrusted() else {
            reportState = "blocked_accessibility"
            status.stringValue = "等待本实验应用的辅助功能授权；未安装事件监听。"
            saveReport()
            return
        }
        guard let dockPID = currentDockPID() else {
            reportState = "blocked_dock"
            status.stringValue = "未找到系统 Dock；等待 Dock 恢复后手动开始。"
            saveReport()
            return
        }
        let token = session.begin(dockPID: dockPID)
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .otherMouseDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callbackContext = TapContext(owner: self, token: token)
        let context = Unmanaged.passUnretained(callbackContext).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: mask,
                                             callback: { _, type, event, context in
            if let context {
                let original = Unmanaged<TapContext>.fromOpaque(context).takeUnretainedValue()
                original.owner?.receive(type, event, token: original.token)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            session.end()
            reportState = "blocked_event_tap"
            status.stringValue = "只读鼠标监听不可用；请核对系统输入监控状态。"
            saveReport()
            return
        }
        tap = newTap
        tapContext = callbackContext
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            stopObservation(state: "blocked_event_source")
            return
        }
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        observing = true
        reportState = "observing"
        status.stringValue = "已启用：\(mode.title)；单击等待 \(String(format: "%.2f", NSEvent.doubleClickInterval)) 秒确认。"
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            _ = self.validateObservation(token)
        }
        saveReport()
    }

    private func receive(_ type: CGEventType, _ event: CGEvent, token: DockObservationToken) {
        // No AX, disk I/O, window control, event posting or synchronous queue waits in this callback.
        guard observing, session.accepts(token) else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async {
                guard self.session.accepts(token) else { return }
                self.stopObservation(state: "tap_disabled")
            }
            return
        }
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
            guard activeSequence == nil, !actions.isBusy else { capture = nil; return }
            activeSequence = press.sequence
            let point = event.location
            let work = HitWork()
            capture = CapturedPress(press: press, point: point,
                foregroundBefore: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                ordinaryWindowsBefore: actions.windowCount,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), work: work,
                actionContext: actions.snapshot(mode: mode), observationToken: token, hadModifiers: modified)
            queue.async { work.downHit = self.hit(at: point, dockPID: token.dockPID) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard self.session.accepts(token), self.activeSequence == press.sequence else { return }
                self.capture = nil
                self.policy.cancel()
                // Keep the admission gate closed until the serial AX work has drained.
                self.queue.async {
                    DispatchQueue.main.async {
                        if self.session.accepts(token), self.activeSequence == press.sequence { self.activeSequence = nil }
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
                let up = self.hit(at: point, dockPID: completed.observationToken.dockPID)
                var gesture = DockGesture(press: completed.press, upTime: time, downHit: down, upHit: up,
                    foregroundBefore: completed.foregroundBefore, ordinaryWindowsBefore: completed.ordinaryWindowsBefore,
                    hadModifiers: completed.hadModifiers, dragged: completed.dragged,
                    distance: completed.distance, clickCount: completed.clickCount)
                gesture.hasOwnedRecovery = completed.actionContext.recovery != nil
                let finishedGesture = gesture
                DispatchQueue.main.async {
                    guard self.session.accepts(completed.observationToken),
                          self.activeSequence == completed.press.sequence else { return }
                    self.activeSequence = nil
                    guard self.validateObservation(completed.observationToken) else { return }
                    if down == .unavailable || up == .unavailable { self.unavailableHitCount += 1 }
                    let result = self.policy.finish(finishedGesture)
                    if case .fixture = down { self.record(result, gesture: finishedGesture) }
                    if result == .pending || result == .pendingRestore {
                        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) {
                            guard self.validateObservation(completed.observationToken) else { return }
                            guard NSApp.isActive, self.actions.windowCount > 0,
                                  self.mode == completed.actionContext.mode else {
                                self.policy.cancel()
                                return
                            }
                            guard let result = self.policy.settle(at: ProcessInfo.processInfo.systemUptime, for: finishedGesture.press) else { return }
                            self.record(result, gesture: finishedGesture)
                            guard self.mode != .observe else { return }
                            self.actions.perform(completed.actionContext, restoring: result == .wouldRestore) { outcome in
                                guard self.session.accepts(completed.observationToken) else { return }
                                switch outcome {
                                case .success(let message): self.recordAction(message, succeeded: true)
                                case .failure(let error): self.recordAction(error.localizedDescription, succeeded: false)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func hit(at point: CGPoint, dockPID: Int32) -> DockHit {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier == dockPID else { return .unavailable }
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

    private func currentDockPID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    private func validateObservation(_ token: DockObservationToken) -> Bool {
        // Called outside the event callback, including after the double-click wait.
        guard observing, session.accepts(token) else { return false }
        guard AXIsProcessTrusted() else { stopObservation(state: "permission_lost"); return false }
        guard session.permits(token, dockPID: currentDockPID()) else {
            stopObservation(state: "dock_changed"); return false
        }
        guard let tap, CGEvent.tapIsEnabled(tap: tap) else {
            stopObservation(state: "tap_disabled"); return false
        }
        return true
    }

    private func observeEnvironment() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.willSleepNotification, "sleeping"),
                               (NSWorkspace.screensDidSleepNotification, "screen_sleeping"),
                               (NSWorkspace.sessionDidResignActiveNotification, "session_inactive")] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.observing else { return }
                self.stopObservation(state: reason)
            })
        }
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, self.observing, let token = self.session.current,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                if name == NSWorkspace.didTerminateApplicationNotification {
                    if app.processIdentifier == token.dockPID { self.stopObservation(state: "dock_changed") }
                } else { _ = self.validateObservation(token) }
            })
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            guard let self, self.observing else { return }
            self.stopObservation(state: "display_changed")
        }
    }

    private func record(_ decision: DockDecision, gesture: DockGesture) {
        observations.append(["decision": decision.rawValue, "foregroundBefore": gesture.foregroundBefore,
            "ordinaryWindowsBefore": gesture.ordinaryWindowsBefore, "dragged": gesture.dragged,
            "modified": gesture.hadModifiers, "clickCount": gesture.clickCount,
            "mode": mode.rawValue, "hasOwnedRecovery": gesture.hasOwnedRecovery,
            "distancePoints": gesture.distance, "durationSeconds": gesture.upTime - gesture.press.time,
            "timestamp": ISO8601DateFormatter().string(from: Date())])
        if observations.count > 40 { observations.removeFirst(observations.count - 40) }
        render()
        saveReport()
    }

    private func recordAction(_ message: String, succeeded: Bool) {
        observations.append(["action": message, "succeeded": succeeded, "mode": mode.rawValue,
            "ownedWindows": ownedWindowStates(),
            "timestamp": ISO8601DateFormatter().string(from: Date())])
        if observations.count > 40 { observations.removeFirst(observations.count - 40) }
        status.stringValue = message
        render()
        saveReport()
    }

    private func render() {
        details.string = observations.map {
            if let action = $0["action"] { return "动作：\(action) | 成功=\($0["succeeded"] ?? false)" }
            return "\($0["decision"] ?? "") | 点击前前台=\($0["foregroundBefore"] ?? false) 窗口=\($0["ordinaryWindowsBefore"] ?? 0) 拖动=\($0["dragged"] ?? false) 修饰键=\($0["modified"] ?? false)"
        }.joined(separator: "\n")
        if observations.isEmpty { details.string = "默认只观察；动作模式仅供自建样本实验。自身图标在正式产品中固定排除。\n本地动作验证会暂停 Dock 监听，检查隐藏、最小化、定向恢复与过期窗口拒绝。" }
    }

    private func saveReport() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("dock-probe-result.json")
        let report: [String: Any] = ["status": reportState, "scope": "owned-probe-only", "eventTapMode": "listenOnly",
            "accessibilityGranted": AXIsProcessTrusted(), "listenEventAccess": CGPreflightListenEventAccess(),
            "eventTapInstalled": tap != nil, "primaryPressCount": primaryPressCount,
            "observationSessionActive": session.current != nil,
            "mode": mode.rawValue, "registeredWindowCount": actions.windowCount,
            "ownedWindows": ownedWindowStates(),
            "unavailableHitCount": unavailableHitCount,
            "observations": observations, "doubleClickInterval": NSEvent.doubleClickInterval,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { status.stringValue = "本地实验报告保存失败：\(error.localizedDescription)" }
    }

    private func ownedWindowStates() -> [String: Any] {
        var states = [String: Any]()
        for (name, candidate) in [("A", window), ("B", sampleWindow)] {
            if let candidate {
                states[name] = ["visible": candidate.isVisible, "miniaturized": candidate.isMiniaturized,
                                "key": candidate.isKeyWindow]
            }
        }
        return states
    }

    private func stopObservation(state: String) {
        observing = false
        session.end()
        policy.cancel()
        actions.cancelPending()
        capture = nil
        activeSequence = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        tapContext = nil
        reportState = state
        let reason: String
        switch state {
        case "permission_lost": reason = "辅助功能权限已失效"
        case "dock_changed": reason = "系统 Dock 已变化或退出"
        case "tap_disabled": reason = "系统已停用鼠标监听"
        case "sleeping", "screen_sleeping", "session_inactive": reason = "系统会话已暂停"
        case "display_changed": reason = "屏幕参数已变化"
        default: reason = "已停止观察"
        }
        status.stringValue = "\(reason)，已清空输入候选。需要时请手动开始。"
        saveReport()
    }

    @objc private func stop() { cancelVerification(); stopObservation(state: "stopped") }
    @objc private func changeMode() {
        let selectedIndex = modePicker.indexOfSelectedItem
        cancelVerification()
        policy.cancel()
        capture = nil
        actions.cancelPending()
        mode = OwnedDockMode.allCases[selectedIndex]
        modePicker.selectItem(at: selectedIndex)
        status.stringValue = "模式：\(mode.title)；\(observing ? "正在监听" : "尚未监听")。"
        saveReport()
    }
    @objc private func showSample() {
        guard !verifier.isRunning else { return }
        _ = makeSampleWindow()
    }
    @objc func showControlPanel() {
        guard !verifier.isRunning else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        showWindow()
    }
    private func makeSampleWindow() -> NSWindow {
        if let sampleWindow {
            actions.register(sampleWindow)
            sampleWindow.deminiaturize(nil)
            sampleWindow.makeKeyAndOrderFront(nil)
            return sampleWindow
        }
        let sample = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 420, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        sample.title = "Loomex 测试窗口 B"
        sample.tabbingMode = .disallowed
        sample.isReleasedWhenClosed = false
        sample.delegate = self
        let label = NSTextField(wrappingLabelWithString: "这是本原型创建的窗口 B。\n最小化模式按 Dock 点击前的主窗口操作；恢复只针对本次收起的窗口。")
        label.frame = NSRect(x: 24, y: 60, width: 370, height: 100)
        sample.contentView?.addSubview(label)
        sampleWindow = sample
        actions.register(sample)
        sample.makeKeyAndOrderFront(nil)
        return sample
    }
    @objc private func verifyActions() {
        guard !verifier.isRunning else { return }
        stopObservation(state: "local_verification")
        showWindow()
        guard let window else { return }
        let sample = makeSampleWindow()
        status.stringValue = "正在验证本原型窗口；Dock 监听已暂停。"
        verifier.run(actions: actions, panel: window, sample: sample) { [weak self] summary in
            guard let self else { return }
            self.mode = .observe
            self.modePicker.selectItem(at: 0)
            self.status.stringValue = summary
            self.reportState = "stopped"
            self.saveReport()
        }
    }
    @objc private func verifyListening() {
        guard !verifier.isRunning else { return }
        mode = .observe
        modePicker.selectItem(at: 0)
        var checks = [[String: Any]]()
        for cycle in 1...3 {
            start()
            let installed = observing && session.current != nil && source != nil && permissionTimer != nil
                && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
            checks.append(["cycle": cycle, "phase": "install", "passed": installed, "status": reportState])
            stopObservation(state: "stopped")
            let released = !observing && session.current == nil && tap == nil && source == nil
                && tapContext == nil && permissionTimer == nil && capture == nil && activeSequence == nil
            checks.append(["cycle": cycle, "phase": "release", "passed": released])
            if !installed || !released { break }
        }
        let passed = checks.count == 6 && checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["status": passed ? "passed" : "failed", "checks": checks,
            "evidence": "real-listenOnly-tap-install-and-release", "systemFaultsInjected": false,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("dock-listening-verification.json")
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            status.stringValue = "监听启停验证：\(passed ? "通过 3 轮" : "失败，请检查报告")；当前已停止。"
        } catch { status.stringValue = "启停验证报告保存失败：\(error.localizedDescription)" }
    }
    private func cancelVerification() { verifier.cancel() }
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        actions.forget(closed)
        policy.cancel()
        capture = nil
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func closeWindows() {
        cancelVerification()
        window?.close()
        sampleWindow?.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if actions.windowCount == 0 { showWindow() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelVerification()
        stopObservation(state: "stopped")
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }
}

let application = NSApplication.shared
let delegate = DockProbeDelegate()
application.setActivationPolicy(.regular)
let menu = NSMenu()
let appMenu = NSMenu()
let showPanelItem = appMenu.addItem(withTitle: "显示控制面板 A", action: #selector(DockProbeDelegate.showControlPanel), keyEquivalent: "1")
showPanelItem.target = delegate
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "退出 Dock 输入实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appItem = NSMenuItem()
appItem.submenu = appMenu
menu.addItem(appItem)
application.mainMenu = menu
application.delegate = delegate
application.run()
