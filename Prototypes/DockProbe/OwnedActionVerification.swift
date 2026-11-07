import AppKit

// Drives real AppKit windows in the GUI session; this is not a Dock-input test.
final class OwnedActionVerification {
    private(set) var isRunning = false
    private var runID = UUID()
    private var results = [[String: Any]]()
    private var actions: OwnedWindowActions?
    private var panel: NSWindow?
    private var sample: NSWindow?
    private var completion: ((String) -> Void)?
    private var lifecycleObservers = [NSObjectProtocol]()
    private var timeline = [[String: Any]]()
    private var startedAt = TimeInterval(0)

    func run(actions: OwnedWindowActions, panel: NSWindow, sample: NSWindow,
             completion: @escaping (String) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        runID = UUID()
        results = []
        self.actions = actions
        self.panel = panel
        self.sample = sample
        self.completion = completion
        timeline = []
        startedAt = ProcessInfo.processInfo.systemUptime
        for (event, name) in [(NSApplication.didHideNotification, "didHide"),
                              (NSApplication.didUnhideNotification, "didUnhide"),
                              (NSApplication.didBecomeActiveNotification, "didBecomeActive"),
                              (NSApplication.didResignActiveNotification, "didResignActive")] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: event, object: NSApp, queue: .main) {
                [weak self] _ in self?.recordState(name)
            })
        }
        // The UI already prepared A/B. A queued activation/unhide here can undo the following hide.
        // Require the real foreground state instead of manufacturing it inside the verification.
        recordState("readyRequested")
        wait("两个自建窗口就绪", condition: {
            actions.windowCount == 2 && NSApp.isActive && panel.isVisible && sample.isVisible
                && !panel.isMiniaturized && !sample.isMiniaturized
        }) { self.hidePanel() }
    }

    private func hidePanel() {
        guard let actions, let panel else { return }
        perform("隐藏本原型应用", context: actions.snapshot(mode: .hideApplication, target: panel), restoring: false,
                condition: { NSApp.isHidden }) { self.restoreHidden() }
    }

    private func restoreHidden() {
        guard let actions, let panel else { return }
        perform("恢复隐藏并聚焦 A", context: actions.snapshot(mode: .hideApplication), restoring: true,
                condition: { !NSApp.isHidden && NSApp.keyWindow === panel && !panel.isMiniaturized }) {
            self.minimizePair()
        }
    }

    private func minimizePair() {
        guard let actions, let panel, let sample else { return }
        // Simulate a manual minimize: deliberately create no recovery record for A.
        panel.miniaturize(nil)
        sample.makeKeyAndOrderFront(nil)
        wait(nil, condition: { panel.isMiniaturized && NSApp.keyWindow === sample }) {
            self.perform("手动收起 A 后仅最小化 B", context: actions.snapshot(mode: .minimizeWindow, target: sample),
                         restoring: false, condition: { panel.isMiniaturized && sample.isMiniaturized }) {
                self.restoreSample()
            }
        }
    }

    private func restoreSample() {
        guard let actions, let panel, let sample else { return }
        perform("仅恢复 B，保留 A 的手动最小化", context: actions.snapshot(mode: .minimizeWindow), restoring: true,
                condition: { panel.isMiniaturized && !sample.isMiniaturized && NSApp.keyWindow === sample }) {
            self.invalidateSample()
        }
    }

    private func invalidateSample() {
        guard let actions, let panel, let sample else { return }
        let token = runID
        actions.perform(actions.snapshot(mode: .minimizeWindow, target: sample), restoring: false) { outcome in
            guard self.isRunning, self.runID == token else { return }
            guard case .success = outcome else { self.fail("准备失效窗口", outcome: outcome); return }
            let stale = actions.snapshot(mode: .minimizeWindow)
            sample.close()
            actions.forget(sample)
            actions.perform(stale, restoring: true) { result in
                guard self.isRunning, self.runID == token else { return }
                let rejected: Bool
                if case .failure(let error) = result, case OwnedDockError.stale = error { rejected = true }
                else { rejected = false }
                guard self.check("关闭 B 后拒绝旧恢复且 A 仍最小化", rejected && panel.isMiniaturized) else { return }
                self.finish(state: "passed")
            }
        }
    }

    private func perform(_ name: String, context: OwnedDockContext, restoring: Bool,
                         condition: @escaping () -> Bool, next: @escaping () -> Void) {
        let token = runID
        recordState("request: \(name)")
        actions?.perform(context, restoring: restoring) { result in
            guard self.isRunning, self.runID == token else { return }
            self.recordState("confirmed: \(name)")
            guard case .success = result else { self.fail(name, outcome: result); return }
            if self.check(name, condition()) { next() }
        }
    }

    private func wait(_ name: String?, condition: @escaping () -> Bool, next: @escaping () -> Void) {
        let token = runID
        actions?.waitUntil(condition) { result in
            guard self.isRunning, self.runID == token else { return }
            guard case .success = result else {
                self.results.append(["name": name ?? "准备窗口状态", "passed": false, "error": "等待系统状态超时",
                    "registered": self.actions?.windowCount ?? 0, "active": NSApp.isActive,
                    "panelVisible": self.panel?.isVisible ?? false, "sampleVisible": self.sample?.isVisible ?? false,
                    "panelMinimized": self.panel?.isMiniaturized ?? false, "sampleMinimized": self.sample?.isMiniaturized ?? false])
                self.finish(state: "failed")
                return
            }
            if let name, !self.check(name, condition()) { return }
            next()
        }
    }

    private func check(_ name: String, _ passed: Bool) -> Bool {
        results.append(["name": name, "passed": passed])
        if !passed { finish(state: "failed") }
        return passed
    }

    private func fail(_ name: String, outcome: Result<String, Error>) {
        let message: String
        if case .failure(let error) = outcome { message = error.localizedDescription }
        else { message = "系统状态与预期不符" }
        results.append(["name": name, "passed": false, "error": message])
        finish(state: "failed")
    }

    private func recordState(_ event: String) {
        guard isRunning else { return }
        timeline.append(["event": event, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - startedAt,
            "active": NSApp.isActive, "hidden": NSApp.isHidden,
            "runningApplicationHidden": NSRunningApplication.current.isHidden,
            "panelVisible": panel?.isVisible ?? false, "sampleVisible": sample?.isVisible ?? false,
            "panelMinimized": panel?.isMiniaturized ?? false, "sampleMinimized": sample?.isMiniaturized ?? false])
        if timeline.count > 80 { timeline.removeFirst() }
    }

    func cancel() {
        guard isRunning else { return }
        finish(state: "cancelled")
    }

    private func finish(state: String) {
        recordState("finish: \(state)")
        isRunning = false
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
        runID = UUID()
        actions?.cancelPending()
        sample?.close()
        if let sample { actions?.forget(sample) }
        if NSApp.isHidden { NSApp.unhide(nil) }
        panel?.deminiaturize(nil)
        panel?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let actions { _ = actions.snapshot(mode: .observe) }
        let report: [String: Any] = ["status": state, "scope": "owned-AppKit-actions-only",
            "checks": results, "lifecycle": timeline, "timestamp": ISO8601DateFormatter().string(from: Date())]
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("dock-actions-verification.json")
        var summary = "本地动作验证：\(state)，\(results.filter { $0["passed"] as? Bool == true }.count)/6；Dock 监听已停止。"
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { summary = "本地动作报告保存失败：\(error.localizedDescription)" }
        let callback = completion
        completion = nil
        actions = nil
        panel = nil
        sample = nil
        callback?(summary)
    }
}
