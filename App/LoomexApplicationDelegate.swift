import AppKit
import SwiftUI

final class LoomexApplicationDelegate: LauncherApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let settings = FlowSettingsModel()
    private var settingsWindow: NSWindow?
    private var prefersSettings = false
    private var settingsMenuItem: NSMenuItem?
    private var launcherOptionsItem: NSMenuItem?
    private var launchStatusItem: NSMenuItem?
    private var hasFinishedLaunching = false

    override var isLauncherEnabled: Bool { settings.launchEnabled }
    override var shouldPresentLauncherOnActivation: Bool {
        !prefersSettings && settings.canOpenLauncher
    }

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

    override func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        buildMenu()
        applySettings()
        if settings.canOpenLauncher { showLauncher() }
        else { showSettings() }
    }

    override func buildMenu() {
        super.buildMenu()
        let show = NSMenuItem(title: "显示启动台", action: #selector(openLauncher), keyEquivalent: "1")
        show.target = self
        NSApp.mainMenu?.items.first?.submenu?.insertItem(show, at: 0)
        if let menu = NSApp.mainMenu?.items.first?.submenu {
            launcherOptionsItem = menu.items.first { $0.action == #selector(launcherOptions) }
            let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
            settingsItem.target = self
            menu.insertItem(settingsItem, at: 2)
            settingsMenuItem = settingsItem
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Loomex Flow")
            button.toolTip = "Loomex Flow"
        }
        let menu = NSMenu(title: "Loomex Flow")
        menu.addItem(withTitle: "显示启动台", action: #selector(openLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "收起启动台", action: #selector(closeLauncher), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(.separator())
        launchStatusItem = menu.addItem(withTitle: "经典启动台：未启动", action: nil, keyEquivalent: "")
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
        launcherVisibilityDidChange()
    }

    @objc private func openLauncher() { showLauncher() }
    @objc private func closeLauncher() { hideLauncher() }

    override func showLauncher() {
        // LaunchServices can send openUntitled before the module has been initialized.
        guard hasFinishedLaunching else { return }
        guard settings.canOpenLauncher else { showSettings(); return }
        prefersSettings = false
        settingsWindow?.orderOut(nil)
        super.showLauncher()
    }

    @objc private func showSettings() {
        // Activation can arrive during makeKeyAndOrderFront. Set the destination first so the
        // shared Launch delegate cannot reopen its full-screen window over this one.
        prefersSettings = true
        dismissLauncher()
        if settingsWindow == nil {
            let view = FlowSettingsView(model: settings,
                                        changeLaunchEnabled: { [weak self] in self?.changeLaunchEnabled($0) },
                                        openLauncher: { [weak self] in self?.showLauncher() },
                                        reloadSettings: { [weak self] in self?.reloadSettings() },
                                        retryLauncher: { [weak self] in self?.applySettings() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Loomex Flow 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        launcherVisibilityDidChange()
    }

    private func changeLaunchEnabled(_ enabled: Bool) {
        guard settings.setLaunchEnabled(enabled) else { return }
        applySettings()
    }

    private func reloadSettings() {
        settings.reload()
        applySettings()
    }

    private func applySettings() {
        if settings.launchEnabled {
            do {
                try startLauncher()
                settings.launcherStarted()
            } catch { launcherFailedToStart(error) }
        } else {
            stopLauncher()
            settings.launcherStopped()
        }
        launcherVisibilityDidChange()
    }

    override func launcherFailedToStart(_ error: Error) {
        stopLauncher()
        settings.launcherStopped(error: error)
    }

    override func launcherVisibilityDidChange() {
        let visible = launcherWindow?.isVisible == true
        launcherOptionsItem?.keyEquivalent = visible ? "," : ""
        settingsMenuItem?.keyEquivalent = visible ? "" : ","
        launchStatusItem?.title = "经典启动台：\(settings.launchStatus)"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openLauncher): return settings.canOpenLauncher
        case #selector(closeLauncher), #selector(launcherOptions): return launcherWindow?.isVisible == true
        default: return true
        }
    }

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
