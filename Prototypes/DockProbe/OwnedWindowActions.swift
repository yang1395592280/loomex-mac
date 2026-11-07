import AppKit

enum OwnedDockMode: String, CaseIterable {
    case observe, hideApplication, minimizeWindow
    var title: String {
        switch self {
        case .observe: return "只观察"
        case .hideApplication: return "隐藏本原型"
        case .minimizeWindow: return "最小化本窗口"
        }
    }
}

enum OwnedDockRecovery: Equatable {
    case hidden(UUID)
    case minimized(UUID)
    var windowID: UUID {
        switch self { case .hidden(let id), .minimized(let id): return id }
    }
}

struct OwnedDockContext {
    let mode: OwnedDockMode
    let revision: Int
    let windowID: UUID?
    let recovery: OwnedDockRecovery?
}

enum OwnedDockError: LocalizedError {
    case stale, unsupported, busy, notConfirmed
    var errorDescription: String? {
        switch self {
        case .stale: return "测试窗口或动作上下文已失效，本次未操作。"
        case .unsupported: return "当前测试窗口状态不支持此动作。"
        case .busy: return "上一动作仍在确认，本次未操作。"
        case .notConfirmed: return "系统未确认预期窗口状态。"
        }
    }
}

// An AppKit fixture actuator: it can address only NSWindows registered by this process.
// It is not a discovery/cache backend and is not the product's shared window service.
final class OwnedWindowActions {
    private var windows = [UUID: NSWindow]()
    private var recovery: OwnedDockRecovery?
    private var revision = 0
    private var operation = 0
    private(set) var isBusy = false

    var windowCount: Int { windows.count }

    @discardableResult
    func register(_ window: NSWindow) -> UUID {
        if let item = windows.first(where: { $0.value === window }) { return item.key }
        let id = UUID()
        windows[id] = window
        revision += 1
        return id
    }

    func forget(_ window: NSWindow) {
        guard let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        if recovery?.windowID == id { recovery = nil }
        revision += 1
    }

    func snapshot(mode: OwnedDockMode, target: NSWindow? = nil) -> OwnedDockContext {
        if let record = recovery {
            let current = windows[record.windowID]
            let valid: Bool
            switch record {
            case .hidden: valid = current != nil && NSApp.isHidden
            case .minimized: valid = current?.isMiniaturized == true
            }
            if !valid { recovery = nil; revision += 1 }
        }
        let selected = target ?? NSApp.keyWindow ?? NSApp.mainWindow
        let id = windows.first(where: { $0.value === selected })?.key
        return OwnedDockContext(mode: mode, revision: revision, windowID: id,
                                recovery: mode == .observe ? nil : recovery)
    }

    func perform(_ context: OwnedDockContext, restoring: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isBusy else { completion(.failure(OwnedDockError.busy)); return }
        guard context.mode != .observe, context.revision == revision else {
            completion(.failure(OwnedDockError.stale)); return
        }
        let id = restoring ? context.recovery?.windowID : context.windowID
        guard let id, let window = windows[id] else { completion(.failure(OwnedDockError.stale)); return }
        guard !window.styleMask.contains(.fullScreen), window.attachedSheet == nil, NSApp.modalWindow == nil else {
            completion(.failure(OwnedDockError.unsupported)); return
        }
        var expectedMinimized: Bool?
        var expectedHidden: Bool?
        let message: String
        if restoring {
            guard let record = context.recovery, record == recovery else {
                completion(.failure(OwnedDockError.stale)); return
            }
            switch record {
            case .hidden:
                // Unhiding must not expand windows the user minimized before our hide action.
                guard !window.isMiniaturized else { completion(.failure(OwnedDockError.stale)); return }
                if NSApp.isHidden { NSApp.unhide(nil) }
                expectedHidden = false
                message = "已恢复本原型应用"
            case .minimized:
                window.deminiaturize(nil)
                expectedMinimized = false
                message = "已恢复本次收起的测试窗口"
            }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        } else {
            guard recovery == nil, NSApp.isActive, window.isVisible, !window.isMiniaturized else {
                completion(.failure(OwnedDockError.stale)); return
            }
            switch context.mode {
            case .observe: completion(.failure(OwnedDockError.unsupported)); return
            case .hideApplication:
                recovery = .hidden(id)
                NSApp.hide(nil)
                expectedHidden = true
                message = "已隐藏本原型应用"
            case .minimizeWindow:
                guard window.styleMask.contains(.miniaturizable) else {
                    completion(.failure(OwnedDockError.unsupported)); return
                }
                recovery = .minimized(id)
                window.miniaturize(nil)
                expectedMinimized = true
                message = "已最小化点击前的测试窗口"
            }
        }
        revision += 1
        isBusy = true
        operation += 1
        let token = operation
        let minimized = expectedMinimized
        let hidden = expectedHidden
        waitUntil({
            guard self.windows[id] === window else { throw OwnedDockError.stale }
            if let minimized, window.isMiniaturized != minimized { return false }
            if let hidden, NSApp.isHidden != hidden { return false }
            return !restoring || (NSApp.isActive && NSApp.keyWindow === window)
        }) { result in
            guard self.operation == token else { return }
            self.isBusy = false
            switch result {
            case .success:
                if restoring { self.recovery = nil }
                completion(.success(message))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    // Main-thread timers let AppKit finish animations without blocking its event loop.
    func waitUntil(_ condition: @escaping () throws -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let token = operation
        func check(_ attempt: Int) {
            guard self.operation == token else { return }
            do {
                if try condition() { completion(.success(())); return }
                guard attempt < 11 else { throw OwnedDockError.notConfirmed }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(attempt + 1) }
            } catch { completion(.failure(error)) }
        }
        DispatchQueue.main.async { check(0) }
    }

    func cancelPending() {
        operation += 1
        isBusy = false
    }
}
