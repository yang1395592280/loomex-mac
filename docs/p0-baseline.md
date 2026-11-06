# P0：工具链与 AltTab 构建基线

日期：2026-11-07。用户已认可架构与需求方案。本记录对应 [开发方案](requirements-and-development.md) 的 T0.1；原启动台与固定 AltTab 的本机构建门禁已通过，组合应用及窗口行为尚未验证。

## 当前证据

| 项目 | 结果 |
| --- | --- |
| 原启动台回归 | `python3 build.py --test --output dist-p0-xcode`：新工具链下 59 passed，0 failed |
| 原启动台制品 | `dist-p0-xcode/经典启动台.app` 已构建，脚本内 ad-hoc 签名完整性校验通过 |
| 主机 | Apple Silicon / macOS 27.0（26A428） |
| 当前命令行工具链 | Swift 6.4.2，SDK 27.2；选中 `/Applications/Xcode.app/Contents/Developer` |
| 完整 Xcode | 用户已安装并完成准备；Xcode 27.2（27B52） |
| AltTab 源码 | v11.10.1，`c500294bdb01186011a5c64a412b04cef9931bef`，与官方 tag 对应 |
| 源码校验与保护 | 固定提交及 11 份文件校验通过；验证脚本的 8 项行为测试通过 |
| PLCrashReporter 二进制 | macOS 切片版本为 1.11.1；与 Microsoft 官方 XCFramework 发行包中的同名二进制 SHA-256 一致，值已写入锁定文件 |
| AltTab 构建与运行 | `python3 scripts/alt_tab_baseline.py --build`：Debug / arm64 构建与 `codesign --verify --deep --strict` 通过；未启动完整上游应用 |

该固定版本现为“构建已验证”的整合候选。验证范围限于本机系统、工具链和架构；启动台测试和 AltTab 编译通过不代表 AltTab 窗口控制、Dock 或组合应用已经可用。

## 固定来源与依赖

机器可读锁定文件为 [config/upstreams/alt-tab.json](../config/upstreams/alt-tab.json)。固定发行提交而非 master；记录许可证、工程及三个本地 SPM 包的关键文件 SHA-256。依赖版本来自该提交中的 vendor/*/UPSTREAM，随整个 AltTab 提交固定。

| 依赖 | 上游声明版本 | 当前处理 |
| --- | --- | --- |
| ShortcutRecorder | `52c6273d233f7794e4fd5d22f50d2de0e4e41b19` | CC BY 4.0，保留归属及许可；是否进入最终整合按实际复用决定 |
| Sparkle | 2.9.1 | 上游构建依赖；Loomex 更新渠道和接入版本另按方案验证 |
| AppCenter | 4.3.0 | 只记录原基线依赖，Loomex 不接入上游崩溃上报 |
| PLCrashReporter | 1.11.1 | macOS 二进制已对照官方制品；固定版本 LICENSE 和 ThirdPartyNotices 入口已核对，整合发行时收集完整文本 |

各依赖当前只是隔离目录内的上游内容，未进入 Loomex 应用。完整发行许可收集和漏洞审查尚未完成，不能将此表称为依赖安全审计。详见 [第三方记录](../THIRD_PARTY_NOTICES.md)。

## 可复现验证入口

需要 Python 3、Git；构建另需完整 Xcode。所有命令从仓库根目录执行。

```sh
# 首次下载并核对源码；已有 checkout 时只读校验，不 fetch/reset/clean。
python3 scripts/alt_tab_baseline.py --fetch

# 验证版本、工作区与关键文件；不需要 Xcode，不运行上游应用。
python3 scripts/alt_tab_baseline.py

# 验证工具链后构建 Debug / arm64，并校验 ad-hoc 签名。
python3 scripts/alt_tab_baseline.py --build

# Xcode 安装在其他位置时，仅为本次子进程选择开发目录。
python3 scripts/alt_tab_baseline.py --build --developer-dir /Applications/Xcode.app

# 验证脚本对本地改动、版本偏移和构建覆盖项的保护。
python3 -m unittest discover -s Tests -p 'test_alt_tab_baseline.py'
```

默认源码位置为 `.local-data/upstream/alt-tab-macos`；构建输出为 `.local-data/build/alt-tab`。两者均被忽略，不进入提交。可用 `--source-dir` 指向另一个干净 checkout。脚本检查完整提交、origin、已跟踪及未跟踪修改和关键文件校验值；拒绝可能改变签名与服务地址的 `config/local.xcconfig`。

脚本按固定 tag 克隆后比对提交；tag 如有移动立即失败。已有目录验证失败时保护本地内容，由开发者另选干净目录。构建不会全局运行 xcode-select，不创建签名证书或 Keychain，不运行上游发布流水线。

GitHub Actions 增加独立 Ubuntu 任务，运行上述 Python 测试并从干净目录下载、核对固定上游源码。此任务不编译 AltTab；完整 Xcode 构建和系统交互仍需在 Mac 上完成。

安装 Xcode 后需先打开并完成首次组件准备、许可接受；脚本优先使用显式 `--developer-dir`，再使用已有 DEVELOPER_DIR，未设置时可自动选择标准 `/Applications/Xcode.app`。所有选择只作用于该构建进程。

## 上游构建边界

该版本使用 Xcode 工程和 vendor 下的三个本地 Swift Package，无远程 SPM 包解析。源码配置为 Swift 5.8、macOS 12 部署目标；上游 CI 选择 Xcode 27.1。本机已在 Xcode 27.2 / SDK 27.2 下构建成功；最低目标与其他系统的运行兼容性仍未验证。

唯一工程 shell build phase 为 Copy Sparkle Helpers：它修改生成的框架资源并重新签名。验证入口对 Debug 构建覆盖为 ad-hoc 身份，避免使用上游开发者证书；构建完成仍不自动启动 AltTab。许可、激活、反馈、更新和崩溃服务在后续 Loomex 适配时分离，不通过运行完整上游应用来验证窗口行为。

## T0.1 退出条件与后续

- 已通过：新 Xcode 下原启动台 59 项测试、构建与签名；固定 AltTab 构建与签名；源码锁定和本地变更保护；依赖版本与许可入口清单；PLCrashReporter macOS 二进制与官方发行包一致。
- 整合前仍需完成：实际复用范围的完整许可收集、其他上游二进制来源和依赖漏洞复核。上游 Test scheme 单元测试本轮未执行。
- 下一步：T0.2 以 Loomex 身份建立受控窗口样本，验证枚举、聚焦、最小化/恢复和拒绝授权路径；随后进入 Dock 输入序列原型。

在上述原型门禁通过前，保持当前启动台入口与布局格式，暂不大规模抽离 AltTab 源码。
