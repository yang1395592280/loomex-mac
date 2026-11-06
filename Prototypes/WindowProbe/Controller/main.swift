import AppKit
import ApplicationServices

enum ProbeRunMode: String { case manual, verification }

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private let service = FixtureWindowService()
    private let queue = DispatchQueue(label: "com.loomex.flow.p0.ax", qos: .userInitiated)
    private let status = NSTextField(wrappingLabelWithString: "请创建测试窗口，再运行验证。")
    private let selection = NSPopUpButton()
    private let details = NSTextView()
    private var controls = [NSButton]()
    private var window: NSWindow!
    private var target: FixtureTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出窗口原型", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = applicationMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 600, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Loomex Flow · 窗口控制原型"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)
        ])
        let description = NSTextField(wrappingLabelWithString: "辅助功能用于读取和控制本工具创建的测试窗口。自动验证会关闭测试窗口 B，其他应用不参与测试。")
        stack.addArrangedSubview(description)
        description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(NSStackView(views: [button("创建测试窗口", #selector(startFixture)), button("辅助功能授权", #selector(requestPermission)), button("运行验证", #selector(verify))]))
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(selection)
        stack.addArrangedSubview(NSStackView(views: [button("刷新", #selector(refresh)), button("聚焦", #selector(focus)), button("最小化", #selector(minimize)), button("恢复", #selector(restore))]))
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--verify") { startFixture() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        controls.append(result)
        return result
    }

    private func busy(_ value: Bool) {
        controls.forEach { $0.isEnabled = !value }
        selection.isEnabled = !value
    }

    @objc private func startFixture() {
        if let previous = target, (try? previous.validate()) != nil { previous.application.terminate() }
        target = nil
        selection.removeAllItems()
        busy(true)
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Loomex Window Fixture.app")
        let session = UUID().uuidString
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [session]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                self.busy(false)
                guard let application, let launchDate = application.launchDate else {
                    self.status.stringValue = error?.localizedDescription ?? "无法启动测试程序。"
                    return
                }
                self.target = FixtureTarget(application: application, launchDate: launchDate, bundleURL: url, session: session)
                self.status.stringValue = AXIsProcessTrusted() ? "测试窗口已创建，可运行验证。" : "测试窗口已创建；等待辅助功能授权。"
                if CommandLine.arguments.contains("--verify") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.verify() }
                }
            }
        }
    }

    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func run(mode: ProbeRunMode = .manual, _ operation: @escaping (FixtureTarget) throws -> ProbeResult) {
        guard let target else { status.stringValue = "请先创建测试窗口。"; return }
        busy(true)
        status.stringValue = "正在验证测试窗口…"
        queue.async {
            let result = Result { try operation(target) }
            DispatchQueue.main.async {
                self.busy(false)
                switch result {
                case .success(let report):
                    self.status.stringValue = "完成：\(report.windows.count) 个测试窗口。"
                    self.details.string = report.checks.joined(separator: "\n")
                    self.selection.removeAllItems()
                    for window in report.windows {
                        self.selection.addItem(withTitle: window.title + (window.minimized ? "（已最小化）" : ""))
                        self.selection.lastItem?.representedObject = window.id
                    }
                    self.saveReport(mode: mode, status: "passed", checks: report.checks)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    let verification = error as? ProbeVerificationFailure
                    let checks = (verification?.completedChecks ?? []) + ["FAIL：\(error.localizedDescription)"]
                    self.details.string = checks.joined(separator: "\n")
                    let underlying = verification?.underlying ?? error
                    let state: String
                    if let failure = underlying as? ProbeError, case .permissionRequired = failure { state = "blocked_accessibility" }
                    else { state = "failed" }
                    self.saveReport(mode: mode, status: state, checks: checks)
                }
            }
        }
    }

    private func saveReport(mode: ProbeRunMode, status: String, checks: [String]) {
        let filename = mode == .verification ? "window-probe-result.json" : "window-probe-manual-result.json"
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(filename)
        do {
            let report: [String: Any] = ["mode": mode.rawValue, "status": status, "checks": checks,
                "accessibilityGranted": AXIsProcessTrusted(), "scope": "owned-fixture-only",
                "timestamp": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { details.string += "\n验证报告保存失败：\(error.localizedDescription)" }
    }

    private func selected(_ action: ProbeAction) {
        let identifier = selection.selectedItem?.representedObject as? String ?? ""
        run { target in
            let windows = try self.service.perform(action, target: target, id: identifier)
            return ProbeResult(windows: windows, checks: ["所选操作的系统状态已核对。"])
        }
    }

    @objc private func refresh() { selected(.list) }
    @objc private func focus() { selected(.focus) }
    @objc private func minimize() { selected(.minimize) }
    @objc private func restore() { selected(.restore) }
    @objc private func verify() { run(mode: .verification) { try self.service.verify($0) } }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let target, (try? target.validate()) != nil { target.application.terminate() }
    }
}

let application = NSApplication.shared
let delegate = ProbeDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
