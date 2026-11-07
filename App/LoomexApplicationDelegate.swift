import AppKit

final class LoomexApplicationDelegate: LauncherApplicationDelegate {
    private var statusItem: NSStatusItem?

    init() {
        var roots: [URL]?
        #if DEBUG
        // Isolated GUI runs use fixtures instead of scanning the developer's application list.
        if let path = ProcessInfo.processInfo.environment["LOOMEX_FLOW_APPLICATIONS_DIR"] {
            roots = [URL(fileURLWithPath: path)]
        }
        #endif
        super.init(product: .loomex, applicationRoots: roots)
    }

    override func buildMenu() {
        super.buildMenu()
        let show = NSMenuItem(title: "显示启动台", action: #selector(openLauncher), keyEquivalent: "1")
        show.target = self
        NSApp.mainMenu?.items.first?.submenu?.insertItem(show, at: 0)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Loomex Flow")
            button.toolTip = "Loomex Flow"
        }
        let menu = NSMenu(title: "Loomex Flow")
        menu.addItem(withTitle: "显示启动台", action: #selector(openLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "收起启动台", action: #selector(closeLauncher), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "窗口切换：尚未接入", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Dock 增强：尚未接入", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关于 Loomex Flow", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "退出 Loomex Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func openLauncher() { showLauncher() }
    @objc private func closeLauncher() { hideLauncher() }

    override func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let alert = NSAlert()
        alert.messageText = "Loomex Flow \(version)"
        alert.informativeText = "Mac 交互增强工具\n\n经典启动台已接入。\n窗口切换与 Dock 增强仍在开发中。\n\nGPL-3.0 开源 · Loomex"
        alert.runModal()
    }

    override func applicationWillTerminate(_ notification: Notification) {
        super.applicationWillTerminate(notification)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
