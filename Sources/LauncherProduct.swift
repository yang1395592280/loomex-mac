import Foundation

enum LauncherProduct {
    case classic, loomex

    var name: String { self == .classic ? "经典启动台" : "Loomex Flow" }
    var traceEnvironmentKey: String {
        self == .classic ? "CLASSIC_LAUNCHPAD_UI_TRACE" : "LOOMEX_FLOW_UI_TRACE"
    }

    func supportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                          applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                             in: .userDomainMask)[0]) -> URL {
        switch self {
        case .classic:
            if let override = environment["CLASSIC_LAUNCHPAD_SUPPORT_DIR"] {
                return URL(fileURLWithPath: override)
            }
            return applicationSupport.appendingPathComponent("ClassicLaunchpad", isDirectory: true)
        case .loomex:
            // A separate root prevents either product from reconciling the other's layout.
            let root = environment["LOOMEX_FLOW_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? applicationSupport.appendingPathComponent("LoomexFlow", isDirectory: true)
            return root.appendingPathComponent("Launch", isDirectory: true)
        }
    }
}
