# 代码来源与第三方许可

## 当前导入

本仓库初始化于 2026-11-07，迁入现有 ClassicLaunchpad 1.0.6 的 Swift 源码、回归测试、Python 构建脚本及程序化图标脚本，作为 Loomex Flow 的启动台开发基线。

当前 Swift 运行代码使用 macOS 系统框架，没有引入 AltTab、DockMinimize、DockTamer 或 DockDoor 的源码、二进制及品牌素材。

ClassicLaunchpad 原版说明保存在 docs/classic-launchpad.md。原说明中的历史制品和验证报告不全部包含在此仓库，当前能力及构建方式以根目录 README.md 为准。

## 计划评估的上游项目

| 项目 | 调研时许可证 | 计划用途 | 当前状态 |
| --- | --- | --- | --- |
| [AltTab](https://github.com/lwouis/alt-tab-macos) | GPL-3.0 | 窗口切换基础 | v11.10.1 已锁定为构建验证候选，尚未整合 |
| [DockMinimize](https://github.com/oidd/DockMinimize) | MIT | Dock 点击行为参考 | 尚未导入 |
| [DockTamer](https://github.com/fdamianenriquez/DockTamer) | MIT | 轻量 Dock 行为备选 | 尚未导入 |
| [DockDoor](https://github.com/ejbills/DockDoor) | GPL-3.0 | 完整窗口及 Dock 交互参考 | 尚未导入 |

许可证信息核对日期为 2026-11-07；实际引入前需按锁定版本复核。引入时在此文件增加具体版本、复用文件、版权、完整许可文本位置和修改说明。

项目提及不代表官方合作或背书。Loomex 使用自身品牌，不继承上游商标或发行身份。

## AltTab P0 验证候选

源码候选为 v11.10.1，提交 `c500294bdb01186011a5c64a412b04cef9931bef`。版本、项目文件、依赖来源与关键文件校验值记录在 [锁定文件](config/upstreams/alt-tab.json)。源码只下载到被忽略的 `.local-data/upstream/`，未复制进 Loomex 运行代码或发行包。

| 上游自带依赖 | 固定版本 | 本次核对的许可证据 |
| --- | --- | --- |
| ShortcutRecorder | `52c6273d233f7794e4fd5d22f50d2de0e4e41b19` | 固定提交的 LICENSE.txt 和源码头声明 CC BY 4.0 |
| Sparkle | 2.9.1 | 对应版本 LICENSE 主体为 MIT，另列 BSD、zlib 等外部组件许可 |
| AppCenter | 4.3.0 | 对应版本 LICENSE 和源码头声明 MIT |
| PLCrashReporter | 1.11.1 | 框架版本及固定版本许可已核对；macOS 二进制 SHA-256 与 Microsoft 官方发行包一致；完整发行许可仍需收集 |

这是构建候选的依赖记录，不是已经完成的发行许可清单。正式复用前需按实际保留文件整理完整许可、版权和修改说明，复核二进制来源及已知漏洞。Loomex 不沿用上游的更新、崩溃上报及 Pro 服务；具体抽离范围在构建原型通过后实施。
