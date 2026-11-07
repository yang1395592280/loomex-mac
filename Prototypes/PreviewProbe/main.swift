import AppKit

final class PreviewProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let capture = OwnedPreviewCapture()
    private var control: NSWindow!
    private var sample: NSWindow?
    private var panel: NSPanel!
    private let imageView = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let panelStatus = NSTextField(wrappingLabelWithString: "")
    private var observers = [NSObjectProtocol]()
    private var selectionCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        control = makeWindow(title: "Loomex Preview Probe", width: 760, height: 330)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        let intro = NSTextField(wrappingLabelWithString: "窗口预览实验\n仅捕获本原型创建的固定样本；图片只留在内存。无权限时使用图标，仍可选择样本。默认不捕获、不申请权限。")
        intro.font = .systemFont(ofSize: 15)
        content.addArrangedSubview(intro)
        content.addArrangedSubview(buttons([
            ("打开自建样本", #selector(showSample)), ("打开预览面板", #selector(showPanel)),
            ("捕获一次", #selector(captureOnce)), ("选择样本窗口", #selector(selectSample))]))
        content.addArrangedSubview(buttons([
            ("收起预览并释放", #selector(hidePanel)), ("申请屏幕录制权限", #selector(requestPermission))]))
        content.addArrangedSubview(status)
        control.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: control.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: control.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: control.contentView!.topAnchor, constant: 24)])
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Loomex Sample Preview"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        imageView.frame = NSRect(x: 10, y: 50, width: 640, height: 400)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("自建样本预览或应用图标")
        panelStatus.frame = NSRect(x: 16, y: 8, width: 628, height: 36)
        panel.contentView?.addSubview(imageView)
        panel.contentView?.addSubview(panelStatus)
        capture.onChange = { [weak self] in self?.refresh() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel()
            })
        }
        refresh()
        control.center()
        control.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }

    private func buttons(_ items: [(String, Selector)]) -> NSStackView {
        let row = NSStackView()
        row.spacing = 10
        for (title, action) in items { row.addArrangedSubview(NSButton(title: title, target: self, action: action)) }
        return row
    }

    private func makeMenu() {
        let menu = NSMenu()
        let app = NSMenu()
        let item = NSMenuItem()
        item.submenu = app
        menu.addItem(item)
        app.addItem(withTitle: "显示控制面板", action: #selector(showControl), keyEquivalent: "1").target = self
        app.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }

    @objc private func showControl() { control.makeKeyAndOrderFront(nil) }

    @objc private func showSample() {
        if sample == nil {
            let window = makeWindow(title: "Loomex Preview Sample", width: 560, height: 320)
            let background = window.contentView!
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.systemIndigo.cgColor
            let title = NSTextField(labelWithString: "LOOMEX · PREVIEW SAMPLE")
            title.font = .boldSystemFont(ofSize: 25)
            title.textColor = .white
            title.frame = NSRect(x: 24, y: 240, width: 510, height: 40)
            background.addSubview(title)
            for index in 0..<3 {
                let block = NSView(frame: NSRect(x: 24 + index * 174, y: 60, width: 160, height: 150))
                block.wantsLayer = true
                block.layer?.backgroundColor = [NSColor.systemTeal, .systemOrange, .systemPink][index].cgColor
                block.layer?.cornerRadius = 18
                let label = NSTextField(labelWithString: "\(index + 1)")
                label.font = .boldSystemFont(ofSize: 64)
                label.textColor = .white
                label.frame = NSRect(x: 58, y: 36, width: 80, height: 80)
                block.addSubview(label)
                background.addSubview(block)
            }
            window.center()
            sample = window
        }
        sample?.deminiaturize(nil)
        sample?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func showPanel() {
        capture.show()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func captureOnce() {
        guard capture.state.visible else { return }
        guard let sample else { refresh(); return }
        capture.request(sample)
    }

    @objc private func selectSample() {
        guard let sample, sample.isVisible || sample.isMiniaturized else { return }
        selectionCount += 1
        hidePanel()
        sample.deminiaturize(nil)
        sample.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func hidePanel() {
        panel?.orderOut(nil)
        capture.hide()
    }

    @objc private func requestPermission() {
        hidePanel()
        // Only this explicit button may prompt. Preflight and icon mode never request access.
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    private func refresh() {
        let messages = ["idle": "尚未打开预览。", "icons": "图标模式；可选择样本窗口。",
                        "stopped": "预览已收起，图片已释放。", "permission_required": "未取得屏幕录制权限，保留图标模式。",
                        "unsupported_system": "当前系统尚未验证截图路线，保留图标模式。",
                        "target_unavailable": "样本窗口当前不可捕获，保留图标模式。",
                        "waiting_for_previous_request": "等待之前的系统请求返回，未排队新请求。",
                        "capturing": "正在捕获自建样本……", "timed_out_waiting_for_os": "预览已超时，保留图标；等待系统返回后才可重试。",
                        "preview_ready": "自建样本预览已就绪。", "capture_failed": "本次截图失败，保留图标模式。",
                        "cancelled": "本次截图已失效，保留图标模式。"]
        let message = messages[capture.status] ?? capture.status
        status.stringValue = "\(message)\n内存图片：\(capture.state.cachedBytes) 字节；系统在途：\(capture.state.inFlight == nil ? 0 : 1)；权限：\(CGPreflightScreenCaptureAccess() ? "已预检通过" : "未预检通过")"
        panelStatus.stringValue = message
        if let image = capture.image, capture.state.visible {
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else {
            imageView.image = capture.state.visible ? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "图标模式") : nil
        }
        saveReport()
    }

    private func saveReport() {
        let report: [String: Any] = ["status": capture.status, "scope": "same-process-owned-sample-only",
            "screenCapturePreflight": CGPreflightScreenCaptureAccess(), "captureSupported": capture.supported,
            "panelVisible": capture.state.visible, "cachedBytes": capture.state.cachedBytes,
            "inFlightCount": capture.state.inFlight == nil ? 0 : 1, "requestCount": capture.requestCount,
            "completedCount": capture.completedCount, "selectionCount": selectionCount,
            "sampleVisible": sample?.isVisible ?? false, "sampleKey": sample?.isKeyWindow ?? false,
            "imageWidth": capture.image?.width ?? 0, "imageHeight": capture.image?.height ?? 0,
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("preview-probe-result.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { status.stringValue = "实验报告无法保存；请检查输出目录。" }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === sample { sample = nil; hidePanel() }
        else if window === panel { hidePanel() }
        else if window === control { NSApp.terminate(nil) }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === sample { hidePanel() }
    }

    func applicationDidHide(_ notification: Notification) { hidePanel() }
    func applicationWillTerminate(_ notification: Notification) {
        hidePanel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}

let application = NSApplication.shared
let delegate = PreviewProbeDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
