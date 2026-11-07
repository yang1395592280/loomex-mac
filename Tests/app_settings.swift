import Foundation

@main
struct AppSettingsTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("normal")
        let model = FlowSettingsModel(directory: directory)
        expect(model.launchEnabled && model.configurationError == nil, "New users enable Launch by default")
        expect(!FileManager.default.fileExists(atPath: directory.path), "Loading defaults does not create files")
        expect(!model.canOpenLauncher && model.launchStatus == "未启动", "Preferences alone cannot claim a running module")
        model.launcherStarted()
        expect(model.canOpenLauncher && model.launchStatus == "已启用", "Successful creation enables the open action")
        expect(model.setLaunchEnabled(false), "A real disable can be saved")
        let disabledData = try Data(contentsOf: model.file)
        let restarted = FlowSettingsModel(directory: directory)
        expect(!restarted.launchEnabled && restarted.launchStatus == "已关闭", "Disabled preference survives restart")
        expect(restarted.setLaunchEnabled(true), "A saved preference can be re-enabled")
        expect(try Data(contentsOf: model.file.appendingPathExtension("backup")) == disabledData,
               "Replacement preserves the previous bytes in a backup")

        for (name, contents) in [("broken", "{broken"), ("future", "{\"version\":2,\"launchEnabled\":true}"),
                                 ("missing", "{\"version\":1}"), ("type", "{\"version\":1,\"launchEnabled\":1}")] {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let file = target.appendingPathComponent("settings.json")
            let original = Data(contents.utf8)
            try original.write(to: file)
            let protected = FlowSettingsModel(directory: target)
            expect(protected.configurationError != nil && !protected.launchEnabled,
                   "Invalid configuration must not run Launch: \(name)")
            expect(!protected.setLaunchEnabled(false), "Invalid configuration cannot be overwritten: \(name)")
            expect(try Data(contentsOf: file) == original, "Original configuration bytes survive: \(name)")
        }

        let changed = Data("{\"version\":1,\"launchEnabled\":true}".utf8)
        try changed.write(to: model.file)
        expect(!model.setLaunchEnabled(true) && !model.settings.launchEnabled && model.saveError != nil,
               "External edits reject a stale write and retain the effective preference")
        expect(try Data(contentsOf: model.file) == changed, "Conflict handling preserves the external edit")
        model.reload()
        expect(model.launchEnabled && model.saveError == nil, "Explicit reload adopts the edited configuration")

        let blocked = root.appendingPathComponent("blocked")
        let failed = FlowSettingsModel(directory: blocked)
        try Data("not a directory".utf8).write(to: blocked)
        failed.launcherStarted()
        expect(!failed.setLaunchEnabled(false), "Filesystem errors reject the change")
        expect(failed.launchEnabled && failed.canOpenLauncher && failed.saveError != nil,
               "Failed persistence leaves the active module and preference unchanged")
        failed.launcherStopped(error: CocoaError(.fileReadCorruptFile))
        expect(failed.launchEnabled && !failed.canOpenLauncher && failed.launchStatus == "启动失败",
               "Layout failure is distinct from a disabled preference")
        failed.launcherStarted()
        expect(failed.canOpenLauncher && failed.launcherError == nil, "A successful retry clears the runtime error")

        let repairFile = root.appendingPathComponent("broken/settings.json")
        let repair = FlowSettingsModel(directory: repairFile.deletingLastPathComponent())
        try changed.write(to: repairFile)
        repair.reload()
        expect(repair.configurationError == nil && repair.launchEnabled, "A repaired file can be reloaded without reset")
        print("App settings: \(checks) passed / 0 failed")
    }
}
