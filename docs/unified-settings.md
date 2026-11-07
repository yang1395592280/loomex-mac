# Loomex Flow 统一设置切片

日期：2026-11-07。本切片提供统一设置窗口和 Launch 实际启停，属于开发版；Switch、Dock 产品模块及 P0 整体仍未完成。

## 当前行为

- AppKit 管理一个可关闭、可重开的设置窗口，内容使用 SwiftUI；应用菜单和菜单栏提供“设置…”入口。
- 设置及菜单栏显示 Launch 的已启用、已关闭、未启动、配置不可用或启动失败状态。开关表达启用意愿，运行状态与布局加载结果独立。
- 关闭 Launch 会释放窗口、画布及其本地键盘监听、顶部背景和布局对象，不删除布局。已在途扫描继续完成，但旧代次结果不写入布局；始终最多一个物理扫描请求。
- 重新启用只准备模块，保持设置窗口。点击“打开启动台”再显示网格，并收起设置。打开设置则只收起网格，不隐藏整个应用。
- Launch 可见时 ⌘, 保留原启动台选项；其余界面 ⌘, 指向统一设置。⌘1 为应用内显示启动台快捷键，模块不可用时菜单禁用。
- Switch 和 Dock 标为“尚未接入”，没有可假启用的开关；本切片不请求系统权限、不注册全局快捷键或事件 tap。
- Launch 已关闭或配置/布局不可用时，启动或重开应用仍可进入设置和退出。显式重开应用且 Launch 可用时显示网格；这与单纯前台激活是两条路径。

## 设置与数据保护

应用配置为 `~/Library/Application Support/LoomexFlow/settings.json`；开发时由 `LOOMEX_FLOW_SUPPORT_DIR` 覆盖根目录。`Launch/layout.json` 和 `Launch/preferences.json` 仍保持原格式，本切片不导入旧产品数据。

```json
{
  "launchEnabled": true,
  "version": 1
}
```

首次缺少文件时采用默认启用，单纯读取不创建文件。更改先保存，成功后才应用模块状态；原子替换前将已有字节备份到 `settings.json.backup`。读取失败、缺字段、类型错误或未来版本不会静默覆盖。保存失败保持当前偏好和运行状态；外部修改与读取时的字节不符时拒绝覆盖，用户可“重新读取设置”。这是一项单应用进程内的保护，不提供多进程事务锁。

配置读取失败时停止 Launch 并显示错误。布局加载失败只使 Launch 不可用，保留原文件，设置窗口与菜单栏继续运行；修复布局后可“重试启动台”。共享的 Classic 入口仍保留原来的保护提示及退出行为。

## 工程与验证

`App/FlowSettings.swift` 承载设置持久化与可观察状态，`FlowSettingsView.swift` 展示界面，`LoomexApplicationDelegate` 协调菜单与焦点；共享 `LauncherApplicationDelegate` 提供创建、单独收起和停止 Launch 的方法。新 Swift 文件显式加入 Xcode target，原 `build.py` 不编译 Loomex 设置。

本机 Apple Silicon / macOS 27.0 / Xcode 27.2 / 单屏普通桌面，实际执行：

```sh
python3 scripts/app_settings.py
python3 build.py --test --output .local-data/build/settings-classic
xcodebuild -quiet -project LoomexFlow.xcodeproj -scheme LoomexFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local-data/build/unified-settings build
xcodebuild -quiet -project LoomexFlow.xcodeproj -scheme LoomexFlow \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local-data/build/unified-settings-release build
```

| 验证 | 实际结果 |
| --- | --- |
| 启动台回归 | 67 项通过：原 64 项，加隐藏创建/单实例/释放、禁用后的迟到扫描、扫描期间重新启用三项生命周期测试 |
| 应用设置 | 28 个断言通过：默认值、持久化和备份、重启、坏 JSON/版本/字段/类型、外部修改、保存失败、错误恢复与实际可用状态 |
| 构建 | Classic 构建与签名；Loomex Debug/Release 构建及严格签名检查通过 |
| 正常 GUI | 实际应用菜单打开设置，网格收起；开关关闭后状态与菜单禁用；退出重启保留关闭；重新启用保持设置；按钮打开六个自建应用网格；⌘, 在网格打开原快捷选项，在设置中保持设置 |
| 故障 GUI | 损坏配置时设置可用且原字节保留；修复后重读恢复；备份文件写失败时开关保持关闭，排除故障后可重试；损坏布局只显示模块失败，原字节保留，修复后重试恢复 |
| 数据隔离 | 使用 `.local-data/unified-settings-gui/` 及自建应用；验证前后两个默认产品目录的存在性与文件 SHA-256 完全一致 |
| 退出 | 每个测试实例经应用菜单退出，应用列表确认无 Loomex Flow 残留；未退出用户的原 Classic 产品 |

技术日志由 `LOOMEX_FLOW_UI_TRACE=1` 显式开启，输出显隐、资源计数和重开事件，不输出应用列表；截图仅用于界面检查，测试布局及日志保存在本地忽略目录。CI 新增无需图形会话的设置测试，图形生命周期回归在本机执行。

## 验证边界与后续

CUA 对无窗口应用的观察会触发 `reopen`：关闭设置后的本轮日志记录到 `event=reopen visible_windows=false`，随后按产品重开规则显示网格。因此本轮不能把它当作“自然关闭设置后不重开网格”或“真实后台切换不抢焦点”的验收，仍待直接人工点击补测。实现通过 `prefersSettings` 区分前台激活与显式重开，但该区别的真人系统行为尚未全部验收。

系统菜单栏的新“设置…”入口、Dock 真实点击、设置最小化、VoiceOver、其他系统/多屏也未在本轮实测。上一切片的菜单栏“显示启动台”已由用户真实点击确认，不要求重复该项。

后续先补齐这几项入口与焦点验收，再推进共享窗口服务和 AltTab 适配。全局暂停、权限页、登录启动、快捷键编辑、布局导入、正式签名公证及三模块组合仍属后续需求。

回退代码时可继续使用此前开发包；不需逆向迁移布局。旧开发包忽略新的应用级配置文件，后续重新启用本切片时继续读取它。
