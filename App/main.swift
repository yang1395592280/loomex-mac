import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = LoomexApplicationDelegate()
application.delegate = delegate
application.run()
