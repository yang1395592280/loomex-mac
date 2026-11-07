# Loomex Flow

[![macOS Build](https://github.com/yang1395592280/loomex-mac/actions/workflows/build.yml/badge.svg)](https://github.com/yang1395592280/loomex-mac/actions/workflows/build.yml)

Loomex Flow 是一款开源 macOS 交互增强工具，计划统一应用启动、窗口切换和 Dock 交互。仓库名为 `loomex-mac`。

## 当前状态

项目已导入可独立构建的 ClassicLaunchpad 1.0.6 基线，并接入 Loomex Flow 应用、统一设置与启动台启停。

| 模块 | 状态 |
| --- | --- |
| 经典启动台 | 已导入：网格、搜索、分页、文件夹、拖拽、排序、撤销及布局备份 |
| 窗口切换 | 规划中：基于 AltTab 整合 |
| Dock 增强 | 规划中：点击隐藏、最小化及恢复 |
| 统一应用与设置 | 已有独立身份、菜单栏、SwiftUI 设置和 Launch 启停；Switch/Dock 接入、全局暂停、权限及快捷键编辑待开发 |

`build.py` 继续输出“经典启动台.app”；新 Xcode target 输出“Loomex Flow.app”，使用独立应用标识和布局目录。三个模块尚未完成整合，当前开发包仅本地 ad-hoc 签名，未做 Apple 公证或正式发布。

## 本地开发

需要 Apple Silicon Mac、macOS、Python 3 以及 Xcode Command Line Tools。当前构建目标为 arm64 / macOS 13+，具体系统兼容范围仍需实测。

```sh
git clone https://github.com/yang1395592280/loomex-mac.git
cd loomex-mac
python3 build.py --test --output dist
```

构建结果：`dist/经典启动台.app`。应用采用本地 ad-hoc 签名，尚未经过 Developer ID 签名或 Apple 公证。

现有 67 项测试涉及布局模型、排序、撤销、手势、偏好存储、真实视图命中、两个产品的数据隔离及模块生命周期，需要可用的 macOS 图形会话。仅构建可执行：

```sh
python3 build.py --output dist
```

在隔离目录中试运行，避免写入已有启动台布局：

```sh
CLASSIC_LAUNCHPAD_SUPPORT_DIR="$PWD/.local-data/launch" \
  "dist/经典启动台.app/Contents/MacOS/ClassicLaunchpad"
```

Loomex 骨架需要完整 Xcode，可打开 `LoomexFlow.xcodeproj` 选择 `LoomexFlow` scheme，或执行：

```sh
xcodebuild -quiet -project LoomexFlow.xcodeproj -scheme LoomexFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .local-data/build/loomex-shell build
```

构建结果位于 `.local-data/build/loomex-shell/Build/Products/Debug/Loomex Flow.app`。试运行隔离方式与原交互验证见 [Launch 应用骨架](docs/launcher-shell.md)，设置、启停和最新验证边界见 [统一设置](docs/unified-settings.md)。新应用默认写入 `~/Library/Application Support/LoomexFlow/Launch/`，本切片不自动导入原版布局。

GitHub Actions 在 Apple Silicon macOS runner 上构建两个产品及三个隔离原型，校验签名，并执行无需 GUI 的窗口状态、Dock 点击策略和预览生命周期测试；另一个 Ubuntu 任务执行上游验证脚本测试，并下载核对固定 AltTab 源码。67 项启动台回归及需要系统授权的行为在本机图形会话中验证。应用级设置另有 28 个无 GUI 断言：`python3 scripts/app_settings.py`，并进入 CI。

## 代码与文档

| 路径 | 内容 |
| --- | --- |
| `Sources/` | 当前经典启动台的 Swift / AppKit 实现 |
| `App/` / `LoomexFlow.xcodeproj` | Loomex 入口、菜单栏、SwiftUI 设置与仅接入 Launch 的 Xcode target |
| `Tests/main.swift` | 现有回归测试 |
| `build.py` / `make_icon.swift` | 编译、图标生成及本地签名 |
| [技术选型与整体架构](docs/technical-architecture.md) | 原生技术栈、候选比较、模块依赖、系统 API、线程、权限与工程迁移 |
| [整体需求与开发方案](docs/requirements-and-development.md) | 功能规格、默认行为、任务拆解、性能预算与验收矩阵 |
| [P0 构建基线](docs/p0-baseline.md) | AltTab 固定版本、依赖核对、验证命令与当前工具链状态 |
| [P0 窗口原型](docs/p0-window-probe.md) | 自建窗口的控制实验、辅助功能授权与实际验证边界 |
| [P0 Dock 原型](docs/p0-dock-input.md) | 默认观察自身 Dock 图标；可选自建窗口隐藏、最小化与定向恢复实验，尚非产品功能 |
| [P0 Dock 监听生命周期](docs/p0-dock-lifecycle.md) | 会话隔离、环境失效暂停与真实监听启停验证 |
| [P0 自建窗口预览](docs/p0-preview-probe.md) | 单次截图、图标降级、容量限制及捕获生命周期验证 |
| [P0 预览资源基线](docs/p0-preview-budget.md) | 只读 footprint/CPU 采样、50 次真实截图开关与空闲基线 |
| [P0 门禁与开发范围](docs/p0-readiness.md) | 原型证据、当前兼容矩阵及 Launch 骨架的开发边界 |
| [Launch 应用骨架](docs/launcher-shell.md) | 两个入口的构建、独立存储、真实交互验证及未完成项 |
| [初期产品规划](docs/loomex-mac-plan.md) | 初期构想及开源项目调研，细化方案以以上两份文档为准 |
| [经典启动台原版说明](docs/classic-launchpad.md) | 迁入前 1.0.6 使用说明，作为历史基线保留 |
| [开发贡献说明](CONTRIBUTING.md) | 分支、提交和验证方式 |
| [上游与许可说明](THIRD_PARTY_NOTICES.md) | 已导入代码及计划参考项目的边界 |

## 开发路线

1. 技术验证：固定 AltTab 版本，验证构建、权限与 Dock 点击处理。
2. v0.1：Loomex 应用骨架、统一设置和经典启动台。
3. v0.2：窗口切换。
4. v0.3：Dock 点击增强，完成三项能力闭环。
5. v1.0：兼容性验证、签名公证和正式分发。

## 许可证

本仓库原创代码采用 **GNU GPL version 3 only（GPL-3.0-only）**，完整条款见 [LICENSE](LICENSE)。今后引入的第三方代码保留其原始版权与许可证，并记录对应版本和修改。

Loomex 为本项目品牌。项目为独立开发的 macOS 工具，与 Apple、AltTab 或其他参考项目没有官方隶属关系。
