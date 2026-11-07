import AppKit

class LauncherApplicationDelegate: NSObject, NSApplicationDelegate {
    let product: LauncherProduct
    private let applicationRoots: [URL]?

    init(product: LauncherProduct = .classic, applicationRoots: [URL]? = nil) {
        self.product = product
        self.applicationRoots = applicationRoots
        super.init()
    }
    var launcherWindow: LaunchWindow?
    var canvas: LaunchCanvas?
    var store: LayoutStore?
    private var scanning = false
    private var openingLauncher = false
    private var menuBarCover: MenuBarCoverWindow?
    private var lastScan = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let support = product.supportDirectory()
        do {
            let store = try LayoutStore(directory: support)
            self.store = store
            let window = LaunchWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = product.name
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            let canvas = LaunchCanvas(store: store)
            canvas.applicationName = product.name
            canvas.dismiss = { [weak self] in self?.hideLauncher() }
            canvas.launch = { [weak self] item in self?.openApplication(item) }
            canvas.rescan = { [weak self] in self?.scanApplications() }
            canvas.showAbout = { [weak self] in self?.about() }
            window.contentView = canvas
            self.canvas = canvas
            launcherWindow = window
            showLauncher()
            scanApplications()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法读取启动台布局"
            alert.informativeText = "为保护原有排序，程序没有覆盖布局文件。可在布局目录中找到上一版 layout.json.backup。\n\n" + error.localizedDescription
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "查看布局目录")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(support)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLauncher()
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showLauncher()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Dock activation may restore a hidden application before delivering its reopen event.
        if let window = launcherWindow, !openingLauncher,
           !window.isVisible || canvas?.resourcesSuspended == true { showLauncher() }
        updateLauncherPresentation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        restoreLauncherPresentation()
        DispatchQueue.main.async { [weak self] in
            // Clicking exposed desktop edges activates Finder; that alone must not dismiss the grid.
            guard !NSApp.isActive, let foreground = NSWorkspace.shared.frontmostApplication,
                  foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  foreground.activationPolicy == .regular,
                  foreground.bundleIdentifier != "com.apple.finder" else { return }
            self?.hideLauncher()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showLauncher() {
        guard let window = launcherWindow, !openingLauncher else { return }
        openingLauncher = true
        defer { openingLauncher = false }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let screen = screen {
            window.setFrame(screen.frame, display: true)
            canvas?.updateWallpaper(for: screen)
        }
        canvas?.resetForOpening()
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        updateLauncherPresentation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            window.animator().alphaValue = 1
        }
        if ProcessInfo.processInfo.environment[product.traceEnvironmentKey] == "1" {
            fputs("UI_TRACE show visible=\(window.isVisible) resources_suspended=\(canvas?.resourcesSuspended ?? false)\n", stderr)
        }
        if Date().timeIntervalSince(lastScan) > 30 { scanApplications() }
    }

    private func updateLauncherPresentation() {
        guard NSApp.isActive, let window = launcherWindow, window.isVisible,
              let screen = window.screen, let canvas = canvas else { return }
        // A narrow backdrop covers the menu strip while the real Dock stays visible. AppKit's
        // menu-hiding presentation modes also hide the Dock, unlike the reference Launchpad.
        let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
        let cover: MenuBarCoverWindow
        if let existing = menuBarCover { cover = existing }
        else {
            cover = MenuBarCoverWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.title = "启动台顶部背景"
            cover.isReleasedWhenClosed = false
            cover.hasShadow = false
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = MenuBarCoverView(frame: NSRect(origin: .zero, size: frame.size))
            view.canvas = canvas
            view.appearance = canvas.appearance
            cover.contentView = view
            menuBarCover = cover
        }
        cover.setFrame(frame, display: false)
        (cover.contentView as? MenuBarCoverView)?.update(wallpaper: canvas.wallpaper, screenSize: screen.frame.size)
        cover.orderFrontRegardless()
        if ProcessInfo.processInfo.environment[product.traceEnvironmentKey] == "1" {
            fputs("UI_TRACE menu_cover=visible height=\(height) presentation=\(NSApp.currentSystemPresentationOptions.rawValue)\n", stderr)
        }
    }

    private func restoreLauncherPresentation() {
        menuBarCover?.orderOut(nil)
        (menuBarCover?.contentView as? MenuBarCoverView)?.releaseContents()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreLauncherPresentation()
        canvas?.suspendResources()
    }

    func hideLauncher() {
        restoreLauncherPresentation()
        launcherWindow?.orderOut(nil)
        canvas?.suspendResources()
        NSApp.hide(nil)
        if ProcessInfo.processInfo.environment[product.traceEnvironmentKey] == "1" {
            fputs("UI_TRACE dismiss visible=\(launcherWindow?.isVisible ?? false) hidden=\(NSApp.isHidden) resources_suspended=\(canvas?.resourcesSuspended ?? false) icon_cache_count=\(canvas?.icons.count ?? 0)\n", stderr)
        }
    }

    func applicationDidHide(_ notification: Notification) {
        restoreLauncherPresentation()
        canvas?.suspendResources()
    }

    func scanApplications() {
        guard !scanning else { return }
        scanning = true
        let identifier = Bundle.main.bundleIdentifier
        let roots = applicationRoots
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppScanner.scan(roots: roots, excluding: identifier)
            DispatchQueue.main.async {
                guard let self = self, let store = self.store else { return }
                self.scanning = false
                self.lastScan = Date()
                do { try store.reconcile(apps: apps); self.canvas?.refresh() }
                catch { self.canvas?.report(error) }
            }
        }
    }

    private func openApplication(_ item: LaunchItem) {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = "应用程序已移动或删除"
            alert.informativeText = "请在空白处右键，选择重新扫描应用程序。"
            alert.runModal()
            return
        }
        hideLauncher()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { [weak self] _, error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                self?.showLauncher()
                let alert = NSAlert()
                alert.messageText = "未能打开“\(item.name)”"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        let about = app.addItem(withTitle: "关于\(product.name)", action: #selector(about), keyEquivalent: "")
        about.target = self
        let options = app.addItem(withTitle: "启动台选项…", action: #selector(launcherOptions), keyEquivalent: ",")
        options.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏\(product.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出\(product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    @objc private func launcherOptions() { canvas?.showOptions() }

    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "经典启动台 1.0.6"
        alert.informativeText = "为熟悉旧 Launchpad 的使用习惯制作。\n本地运行 · 无广告 · 无订阅\n\n独立开发的替代应用，非 Apple 原版。\n支持全屏网格、分页、文件夹、排序和搜索。"
        alert.runModal()
    }
}
