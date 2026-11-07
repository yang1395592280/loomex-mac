import Combine
import Foundation

struct FlowSettings: Codable, Equatable {
    var version = 1
    var launchEnabled = true
}

final class FlowSettingsModel: ObservableObject {
    @Published private(set) var settings = FlowSettings()
    @Published private(set) var configurationError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var launcherAvailable = false
    @Published private(set) var launcherError: String?
    let file: URL
    private var persistedData: Data?

    init(directory: URL = LauncherProduct.loomex.supportDirectory().deletingLastPathComponent()) {
        file = directory.appendingPathComponent("settings.json")
        reload()
    }

    var launchEnabled: Bool { configurationError == nil && settings.launchEnabled }
    var canOpenLauncher: Bool { launchEnabled && launcherAvailable }
    var launchStatus: String {
        if configurationError != nil { return "配置不可用" }
        if !settings.launchEnabled { return "已关闭" }
        if launcherError != nil { return "启动失败" }
        return launcherAvailable ? "已启用" : "未启动"
    }

    func reload() {
        do {
            let data = try readData()
            let value = try data.map(decode) ?? FlowSettings()
            persistedData = data
            settings = value
            configurationError = nil
            saveError = nil
        } catch {
            // Keep the original bytes intact; a broken or newer file must never become defaults on disk.
            configurationError = error.localizedDescription
        }
    }

    @discardableResult
    func setLaunchEnabled(_ enabled: Bool) -> Bool {
        guard configurationError == nil else { return false }
        if enabled == settings.launchEnabled { return true }
        var candidate = settings
        candidate.launchEnabled = enabled
        do {
            // Refuse a stale write when another process or editor changed the file after loading it.
            guard try readData() == persistedData else { throw SettingsError.changedExternally }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let old = persistedData {
                try old.write(to: file.appendingPathExtension("backup"), options: .atomic)
            }
            try data.write(to: file, options: .atomic)
            persistedData = data
            settings = candidate
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func launcherStarted() {
        launcherError = nil
        launcherAvailable = true
    }

    func launcherStopped(error: Error? = nil) {
        launcherAvailable = false
        launcherError = error?.localizedDescription
    }

    private func readData() throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func decode(_ data: Data) throws -> FlowSettings {
        let value = try JSONDecoder().decode(FlowSettings.self, from: data)
        guard value.version == 1 else { throw SettingsError.unsupportedVersion(value.version) }
        return value
    }

    private enum SettingsError: LocalizedError {
        case unsupportedVersion(Int), changedExternally

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "设置版本 \(version) 暂不受支持，请使用兼容的 Loomex Flow 版本。"
            case .changedExternally:
                return "设置文件已被其他进程修改。请重新读取设置后再操作。"
            }
        }
    }
}
