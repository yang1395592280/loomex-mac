import SwiftUI

struct FlowSettingsView: View {
    @ObservedObject var model: FlowSettingsModel
    let changeLaunchEnabled: (Bool) -> Void
    let openLauncher: () -> Void
    let reloadSettings: () -> Void
    let retryLauncher: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Loomex Flow").font(.largeTitle.bold())
                    Text("让 Mac 的常用交互集中在一处。")
                        .foregroundStyle(.secondary)
                }

                if let error = model.configurationError {
                    errorNotice("无法读取设置", detail: error + "\n原文件已保留，启动台暂不运行。")
                }
                if let error = model.saveError {
                    errorNotice("设置未保存", detail: error + "\n本次更改未生效。")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        moduleHeading("经典启动台", symbol: "square.grid.3x3.fill", status: model.launchStatus)
                        Text("用全屏网格、文件夹和搜索打开应用。")
                            .foregroundStyle(.secondary)
                        Toggle("启用经典启动台", isOn: Binding(
                            get: { model.settings.launchEnabled },
                            set: changeLaunchEnabled))
                            .toggleStyle(.switch)
                            .disabled(model.configurationError != nil)
                        Text("关闭后保留布局，并释放启动台窗口与监听。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = model.launcherError {
                            errorNotice("无法载入启动台布局", detail: error + "\n原布局未被覆盖。")
                            Button("重试启动台", action: retryLauncher)
                                .disabled(!model.launchEnabled)
                        }
                        HStack {
                            Spacer()
                            Button("打开启动台", action: openLauncher)
                                .disabled(!model.canOpenLauncher)
                        }
                    }.padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        moduleHeading("窗口切换", symbol: "rectangle.on.rectangle", status: "尚未接入")
                        Text("后续提供窗口选择与预览。当前开发版不注册切换快捷键。")
                            .foregroundStyle(.secondary)
                        Divider()
                        moduleHeading("Dock 增强", symbol: "dock.rectangle", status: "尚未接入")
                        Text("后续提供点击隐藏、最小化及恢复。当前开发版不拦截 Dock 点击。")
                            .foregroundStyle(.secondary)
                    }.padding(12)
                }
                HStack {
                    Text("开发版 · GPL-3.0 开源")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新读取设置", action: reloadSettings)
                }
            }.padding(28)
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private func moduleHeading(_ title: String, symbol: String, status: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            Text(status).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func errorNotice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle").font(.headline)
            Text(detail).font(.callout).textSelection(.enabled)
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
