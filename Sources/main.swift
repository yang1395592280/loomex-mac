import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = LauncherApplicationDelegate()
application.delegate = delegate
application.run()
