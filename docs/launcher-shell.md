# Loomex Flow / Launch 应用骨架

日期：2026-11-07。状态：仅接入经典启动台的开发骨架，版本字段为 0.1.0，尚非 v0.1 正式交付。P0 整体、统一设置和三模块整合仍未完成。

## 实际实现

| 部分 | 当前行为 |
| --- | --- |
| Xcode target | `LoomexFlow.xcodeproj` / 共享 `LoomexFlow` scheme，arm64，macOS 13 部署目标，Swift 5 / AppKit |
| Loomex 入口 | `App/main.swift` 创建唯一 NSApplication，delegate 为 `LoomexApplicationDelegate`；target 不编译 `Sources/main.swift` |
| 共享启动台 | `Sources/LauncherApplicationDelegate.swift` 从原入口提取，保持窗口显示、失活、扫描、收起和资源释放路径；继续复用原视图及布局模型 |
| 原版入口 | `Sources/main.swift` 通过默认 Classic 配置使用共享 delegate；`build.py` 的独立产品身份和输出保持原样 |
| Loomex 身份 | Bundle ID `com.loomex.flow`；窗口、关于与退出菜单使用 Loomex Flow 名称；当前使用开发包默认图标 |
| 菜单栏 | 网格图标菜单提供显示、收起、关于、退出；窗口切换与 Dock 增强标为尚未接入 |
| 应用菜单 | 显示启动台 ⌘1、启动台选项 ⌘,、隐藏 ⌘H、退出 ⌘Q；保留编辑菜单；这些是应用内快捷键 |

采用共享 delegate 配合 Loomex 子类的原因是两个产品当前只有品牌、存储位置及应用菜单不同。复制完整启动台会导致两套行为分叉；本切片也不需要重组全部目录或引入空的模块服务。后续统一设置与模块生命周期接入时，再按实际职责拆分应用层。

## 布局与运行隔离

| 产品 | 默认布局目录 | 开发覆盖变量 |
| --- | --- | --- |
| 经典启动台 | `~/Library/Application Support/ClassicLaunchpad/` | `CLASSIC_LAUNCHPAD_SUPPORT_DIR` 直接指向布局目录，语义保持原样 |
| Loomex Flow | `~/Library/Application Support/LoomexFlow/Launch/` | `LOOMEX_FLOW_SUPPORT_DIR` 指向根目录，布局放在其 `Launch/` 子目录 |

Loomex 忽略旧产品的目录覆盖变量，不自动读取、复制或迁移旧布局。`layout.json`、备份、排序撤销和动画偏好格式保持原样。开发者应始终使用独立目录；显式覆盖变量时也不要指向个人正式布局。

Debug 构建可通过 `LOOMEX_FLOW_APPLICATIONS_DIR` 指向自建 `.app` 目录，避免扫描个人应用。该目录覆盖入口不编入 Release。`LOOMEX_FLOW_UI_TRACE=1` 可选输出显隐、资源暂停及图标缓存计数，不输出应用列表或窗口标题，默认关闭。

## 构建与试运行

```sh
python3 build.py --test --output .local-data/build/classic
xcodebuild -quiet -project LoomexFlow.xcodeproj -scheme LoomexFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local-data/build/loomex-shell build
codesign --verify --deep --strict \
  '.local-data/build/loomex-shell/Build/Products/Debug/Loomex Flow.app'
```

隔离试运行：

```sh
LOOMEX_FLOW_SUPPORT_DIR="$PWD/.local-data/loomex-launch" \
  '.local-data/build/loomex-shell/Build/Products/Debug/Loomex Flow.app/Contents/MacOS/Loomex Flow'
```

Release 验证将构建命令中的 `Debug` 替换为 `Release`，产物也位于 `Release/`。开发 target 采用本地 ad-hoc 签名，未启用 App Sandbox / hardened runtime，未做 Developer ID 签名或公证；正式分发配置另行处理。本 target 不请求辅助功能、屏幕录制或输入监控权限。

## 已执行的验证

本机环境：Apple Silicon、macOS 27.0、Xcode 27.2、单屏普通桌面。

| 验证 | 实际结果 |
| --- | --- |
| 原回归及新增产品隔离测试 | `python3 build.py --test --output .local-data/build/launcher-shell-classic`：64 passed / 0 failed，原 59 项全部保留 |
| 新增 5 项覆盖 | 原默认/覆盖目录语义；Loomex 忽略旧变量；新根目录的 Launch 子目录；不隐式导入；新布局及偏好写入保持旧文件字节不变 |
| 原产品构建与签名 | 通过，仍输出经典启动台.app |
| Xcode Debug / Release | 两种配置均构建成功，实际 Bundle ID 与版本字段已核对，严格签名检查通过 |
| 隔离 GUI | 6 个自建样本网格、中文搜索、无结果搜索、点击打开样本应用、Esc 清除及收起、应用重开恢复网格 |
| 菜单与整理 | 应用菜单“显示启动台”、关于、启动台选项、名称倒序排序及撤销恢复原序、菜单退出均已实际操作 |
| 隐藏资源 | 技术日志为 `visible=false`、`resources_suspended=true`、`icon_cache_count=0`；重开为 `resources_suspended=false` |
| 数据保护 | 试运行前后，两个默认产品目录的存在性与文件 SHA-256 均一致；仅隔离目录产生布局及排序撤销数据 |
| 退出 | Loomex 与自建样本均从应用菜单退出；进程检查及应用列表确认无本轮进程残留 |

界面截图仅用于本地观察；原始技术摘要、日志、测试布局和自建样本均在忽略的 `.local-data/` 内，不提交。CI 增加 Loomex Release 构建与签名检查；需要图形会话的 64 项测试在本机执行。

## 未完成与下一步

本轮 CUA 无法读取系统 Dock 和 SystemUIServer（超时），所以没有完成菜单栏图标点击及 Dock 图标点击重开的系统入口验收。应用自身菜单及重新打开事件已验证，不能替代这两项真实入口。新骨架中的文件夹拖拽、边缘跨页、多屏和其他 macOS 版本也未在本轮实测。

后续先完成上述入口验收，再接入统一设置、真实模块状态与开关。登录启动、全局快捷键、旧布局导入、应用图标、正式签名公证分别作为后续切片；Switch / Dock 仍需通过 [P0 门禁](p0-readiness.md) 后接入同一个窗口服务。

回退时可继续使用原 `build.py` 产物及原布局目录；本切片不需要逆向数据迁移。
