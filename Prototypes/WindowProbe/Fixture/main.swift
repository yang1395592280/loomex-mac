import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows = [NSWindow]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2 else { NSApp.terminate(nil); return }
        let session = CommandLine.arguments[1]
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        for (index, name) in ["A", "B"].enumerated() {
            let frame = NSRect(x: visible.midX + CGFloat(index * 32), y: visible.midY - CGFloat(index * 48), width: 360, height: 220)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Loomex Test Window \(name)"
            window.setAccessibilityIdentifier("loomex-fixture-\(session)-\(name)")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let label = NSTextField(labelWithString: "Loomex 自建测试窗口 \(name)")
            label.frame = NSRect(x: 24, y: 100, width: 300, height: 26)
            window.contentView?.addSubview(label)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
