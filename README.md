# Loomex Flow

[![macOS Build](https://github.com/yang1395592280/loomex-mac/actions/workflows/build.yml/badge.svg)](https://github.com/yang1395592280/loomex-mac/actions/workflows/build.yml)

Loomex Flow 是一款开源 macOS 交互增强工具，计划统一应用启动、窗口切换和 Dock 交互。仓库名为 `loomex-mac`。

## 当前状态

项目处于初始化阶段，已导入可独立构建的 ClassicLaunchpad 1.0.6 源码、测试与构建脚本，作为经典启动台模块的开发基线。

| 模块 | 状态 |
| --- | --- |
| 经典启动台 | 已导入：网格、搜索、分页、文件夹、拖拽、排序、撤销及布局备份 |
| 窗口切换 | 规划中：基于 AltTab 整合 |
| Dock 增强 | 规划中：点击隐藏、最小化及恢复 |
| 统一应用与设置 | 规划中：统一菜单栏、模块开关、权限和快捷键 |

当前构建仍输出“经典启动台.app”，使用原应用标识和布局目录；尚未完成 Loomex 品牌界面或三个模块的整合。

## 本地开发

需要 Apple Silicon Mac、macOS、Python 3 以及 Xcode Command Line Tools。当前构建目标为 arm64 / macOS 13+，具体系统兼容范围仍需实测。

```sh
git clone https://github.com/yang1395592280/loomex-mac.git
cd loomex-mac
python3 build.py --test --output dist
```

构建结果：`dist/经典启动台.app`。应用采用本地 ad-hoc 签名，尚未经过 Developer ID 签名或 Apple 公证。

现有 59 项测试涉及布局模型、排序、撤销、手势、偏好存储和真实视图命中，需要可用的 macOS 图形会话。仅构建可执行：

```sh
python3 build.py --output dist
```

在隔离目录中试运行，避免写入已有启动台布局：

```sh
CLASSIC_LAUNCHPAD_SUPPORT_DIR="$PWD/.local-data/launch" \
  "dist/经典启动台.app/Contents/MacOS/ClassicLaunchpad"
```

GitHub Actions 在 Apple Silicon macOS runner 上执行构建及脚本内的签名完整性校验；需要图形会话的测试和真实 Dock 交互在本机验证。

## 代码与文档

| 路径 | 内容 |
| --- | --- |
| `Sources/` | 当前经典启动台的 Swift / AppKit 实现 |
| `Tests/main.swift` | 现有回归测试 |
| `build.py` / `make_icon.swift` | 编译、图标生成及本地签名 |
| [产品与技术规划](docs/loomex-mac-plan.md) | 架构、选型、权限、迁移、版本路线和验收条件 |
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
