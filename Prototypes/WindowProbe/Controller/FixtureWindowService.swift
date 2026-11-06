import AppKit
import ApplicationServices

struct FixtureTarget {
    let application: NSRunningApplication
    let launchDate: Date
    let bundleURL: URL
    let session: String

    func validate() throws {
        guard !application.isTerminated,
              let current = NSRunningApplication(processIdentifier: application.processIdentifier),
              current.bundleIdentifier == "com.loomex.flow.p0.fixture",
              current.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL,
              current.launchDate == launchDate else { throw ProbeError.targetGone }
    }
}

struct FixtureWindow {
    let id: String
    let title: String
    let minimized: Bool
}

struct ProbeResult {
    let windows: [FixtureWindow]
    let checks: [String]
}

struct ProbeVerificationFailure: LocalizedError {
    let completedChecks: [String]
    let failedCheck: String
    let underlying: Error

    var errorDescription: String? { "\(failedCheck)：\(underlying.localizedDescription)" }
}

enum ProbeError: LocalizedError {
    case permissionRequired, targetGone, windowGone, unsupported, stateNotConfirmed
    case stateNotConfirmedAt(String)
    case accessibility(String, Int32)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "等待辅助功能授权。授权后可直接再次运行验证。"
        case .targetGone: return "测试进程已退出或身份改变，请重新创建测试窗口。"
        case .windowGone: return "目标测试窗口已关闭，本次操作已停止。"
        case .unsupported: return "该测试窗口不支持所选操作。"
        case .stateNotConfirmed: return "系统尚未确认预期窗口状态，未将操作判定为成功。"
        case .stateNotConfirmedAt(let state): return "系统尚未确认\(state)，未将操作判定为成功。"
        case .accessibility(let operation, let code): return "\(operation)失败（AX \(code)）。"
        }
    }
}

enum ProbeAction { case list, focus, minimize, restore, close }

final class FixtureWindowService {
    private func checked(_ status: AXError, _ operation: String) throws {
        guard status == .success else { throw ProbeError.accessibility(operation, status.rawValue) }
    }

    private func attribute<T>(_ element: AXUIElement, _ key: String) throws -> T {
        var value: CFTypeRef?
        try checked(AXUIElementCopyAttributeValue(element, key as CFString, &value), key)
        guard let result = value as? T else { throw ProbeError.unsupported }
        return result
    }

    private func applicationElement(_ target: FixtureTarget) throws -> AXUIElement {
        try target.validate()
        guard AXIsProcessTrusted() else { throw ProbeError.permissionRequired }
        let element = AXUIElementCreateApplication(target.application.processIdentifier)
        try checked(AXUIElementSetMessagingTimeout(element, 0.5), "设置查询超时")
        return element
    }

    private func elements(_ target: FixtureTarget) throws -> [(FixtureWindow, AXUIElement)] {
        let application = try applicationElement(target)
        let windows: [AXUIElement] = try attribute(application, kAXWindowsAttribute)
        return try windows.compactMap { element in
            try checked(AXUIElementSetMessagingTimeout(element, 0.5), "设置窗口查询超时")
            let identifier: String = try attribute(element, kAXIdentifierAttribute)
            guard identifier.hasPrefix("loomex-fixture-\(target.session)-") else { return nil }
            let title: String = try attribute(element, kAXTitleAttribute)
            let minimized: Bool = try attribute(element, kAXMinimizedAttribute)
            return (FixtureWindow(id: identifier, title: title, minimized: minimized), element)
        }
    }

    func list(_ target: FixtureTarget) throws -> [FixtureWindow] {
        try elements(target).map { $0.0 }.sorted { $0.id < $1.id }
    }

    private func resolve(_ target: FixtureTarget, _ id: String) throws -> AXUIElement {
        // Re-resolve each action from the current process/session; never reuse a closed window's AX handle.
        guard let match = try elements(target).first(where: { $0.0.id == id }) else { throw ProbeError.windowGone }
        return match.1
    }

    private func setMinimized(_ element: AXUIElement, _ minimized: Bool) throws {
        var writable: DarwinBoolean = false
        try checked(AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &writable), "检查最小化能力")
        guard writable.boolValue else { throw ProbeError.unsupported }
        try checked(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse), "修改最小化状态")
    }

    private func setHidden(_ hidden: Bool, target: FixtureTarget) throws {
        let application = try applicationElement(target)
        var writable: DarwinBoolean = false
        try checked(AXUIElementIsAttributeSettable(application, kAXHiddenAttribute as CFString, &writable), "检查隐藏能力")
        guard writable.boolValue else { throw ProbeError.unsupported }
        try checked(AXUIElementSetAttributeValue(application, kAXHiddenAttribute as CFString, hidden ? kCFBooleanTrue : kCFBooleanFalse), "修改测试应用隐藏状态")
        try waitFor(context: hidden ? "测试应用已隐藏" : "应用已解除隐藏") {
            let current = try self.applicationElement(target)
            let state: Bool = try self.attribute(current, kAXHiddenAttribute)
            return state == hidden && target.application.isHidden == hidden
        }
    }

    func waitFor(context: String? = nil, pause: () -> Void = { Thread.sleep(forTimeInterval: 0.08) }, _ condition: () throws -> Bool) throws {
        // AppKit can temporarily reject AX reads during minimize/restore animations.
        // Retry only that transport error, only inside bounded post-action confirmation.
        for attempt in 0..<10 {
            do {
                if try condition() { return }
            } catch let error as ProbeError {
                guard case .accessibility(_, let code) = error,
                      code == AXError.cannotComplete.rawValue,
                      attempt < 9 else { throw error }
            }
            if attempt < 9 { pause() }
        }
        if let context { throw ProbeError.stateNotConfirmedAt(context) }
        throw ProbeError.stateNotConfirmed
    }

    func perform(_ action: ProbeAction, target: FixtureTarget, id: String) throws -> [FixtureWindow] {
        if case .list = action { return try list(target) }
        let element = try resolve(target, id)
        try target.validate()
        switch action {
        case .list: break
        case .minimize, .restore:
            let minimized = action == .minimize
            try setMinimized(element, minimized)
            try waitFor(context: "最小化状态") {
                let current = try self.resolve(target, id)
                let state: Bool = try self.attribute(current, kAXMinimizedAttribute)
                return state == minimized
            }
        case .focus:
            let minimized: Bool = try attribute(element, kAXMinimizedAttribute)
            if minimized {
                try setMinimized(element, false)
                try waitFor(context: "最小化窗口已展开") {
                    let current = try self.resolve(target, id)
                    let state: Bool = try self.attribute(current, kAXMinimizedAttribute)
                    return !state
                }
            }
            let hidden: Bool = try attribute(applicationElement(target), kAXHiddenAttribute)
            if hidden { try setHidden(false, target: target) }
            DispatchQueue.main.sync {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: target.application)
                    target.application.activate(from: .current, options: [])
                } else {
                    target.application.activate(options: [])
                }
            }
            try waitFor(context: "目标应用激活与窗口焦点") {
                // Raising is idempotent; re-resolve after restoration before retrying a busy target.
                let current = try self.resolve(target, id)
                try self.checked(AXUIElementSetAttributeValue(current, kAXMainAttribute as CFString, kCFBooleanTrue), "选择主测试窗口")
                try self.checked(AXUIElementPerformAction(current, kAXRaiseAction as CFString), "聚焦测试窗口")
                let app = try self.applicationElement(target)
                let focused: AXUIElement = try self.attribute(app, kAXFocusedWindowAttribute)
                let focusedID: String = try self.attribute(focused, kAXIdentifierAttribute)
                return focusedID == id && target.application.isActive
            }
        case .close:
            let button: AXUIElement = try attribute(element, kAXCloseButtonAttribute)
            try checked(AXUIElementPerformAction(button, kAXPressAction as CFString), "关闭测试窗口")
            try waitFor { try !self.list(target).contains { $0.id == id } }
        }
        return try list(target)
    }

    func verify(_ target: FixtureTarget) throws -> ProbeResult {
        var checks = [String]()
        func check(_ description: String, _ operation: () throws -> Void) throws {
            do {
                try operation()
                checks.append("PASS：\(description)")
            } catch {
                throw ProbeVerificationFailure(completedChecks: checks, failedCheck: description, underlying: error)
            }
        }
        var initial = [FixtureWindow]()
        try check("仅枚举到本会话的两个测试窗口") {
            initial = try list(target)
            guard initial.count == 2 else { throw ProbeError.unsupported }
        }
        let first = initial[0].id
        let second = initial[1].id
        try check("最小化 A，B 保持展开") {
            _ = try perform(.minimize, target: target, id: first)
            guard try list(target).first(where: { $0.id == second })?.minimized == false else { throw ProbeError.stateNotConfirmed }
        }
        try check("恢复最小化窗口 A 并聚焦") {
            _ = try perform(.focus, target: target, id: first)
        }
        try check("切换到窗口 B") {
            _ = try perform(.focus, target: target, id: second)
        }
        try check("恢复隐藏应用并聚焦窗口 A") {
            try setHidden(true, target: target)
            _ = try perform(.focus, target: target, id: first)
        }
        try check("已关闭窗口的旧选择被拒绝") {
            _ = try perform(.close, target: target, id: second)
            do {
                _ = try perform(.minimize, target: target, id: second)
                throw ProbeError.stateNotConfirmed
            } catch ProbeError.windowGone {}
        }
        return ProbeResult(windows: try list(target), checks: checks)
    }
}
