# P0：受控窗口验证原型

日期：2026-11-07。对应 [开发方案](requirements-and-development.md) 的 T0.2。该原型用于验证 Loomex 自有身份下的公共辅助功能 API 和失败路径；尚未接入 AltTab，不能据此判定产品窗口服务已完成。

## 实现与边界

`Prototypes/WindowProbe/Fixture` 创建普通 AppKit 测试窗口 A、B；`Controller` 提供枚举、聚焦、最小化、恢复和完整验证按钮。两者独立于现有 `Sources/` 与启动台布局，构建结果只写入被忽略的 `.local-data/build/window-probe/`。

控制器核对测试进程的 PID、Bundle ID、路径与启动时间，并只接受当前会话 UUID 对应的窗口标识。每次动作重新解析窗口；跨进程 AX 调用使用串行后台队列和 0.5 秒消息超时，动作后的状态确认有次数上限。程序没有持续窗口扫描、截图、全局输入拦截或网络功能。

这些限制来自代码。macOS 的辅助功能授权本身允许应用控制其他应用，并不提供“仅限测试窗口”的系统权限范围。授权是手动入口；启动或运行验证不会自动申请权限。未授权时立即显示等待提示并生成阻塞报告，其他应用不进入测试列表。退出控制器时请求终止当前自建测试进程。

本原型仅作为技术实验。正式 Switch 与 Dock 按既定架构共用 AltTab 适配层，不将实验里的窗口枚举服务演变为第二套产品窗口引擎。

## 本机使用

需要 Apple Silicon Mac、Python 3、可用的图形会话和 Xcode 工具链。从仓库根目录执行：

```sh
# 编译两个隔离应用并校验 ad-hoc 签名。
python3 scripts/window_probe.py --build

# 打开控制器，手动创建测试窗口及执行操作。
python3 scripts/window_probe.py --launch

# 控制器未运行时使用：启动、创建 A/B 并自动尝试完整验证。
python3 scripts/window_probe.py --launch --verify
```

重新构建或使用 `--verify` 启动前先退出旧控制器；已运行的应用不会重新处理启动参数。ad-hoc 重建后系统可能要求重新确认辅助功能权限。

如需验证已授权场景，由开发者明确同意后，通过控制器的“辅助功能授权”入口前往系统设置，只为 `Loomex Window Probe` 开启辅助功能。回到控制器点击“运行验证”。此实验不需要屏幕录制权限。

完整验证按顺序检查：

1. 仅枚举当前会话的两个测试窗口。
2. 最小化 A，确认 B 未被最小化。
3. 恢复最小化的 A 并确认其真实焦点。
4. 切换到 B 并确认其真实焦点。
5. 隐藏测试应用，再恢复并聚焦 A。
6. 关闭 B，再用旧选择请求最小化 B，确认拒绝失效窗口。

第 6 步会关闭自建 B 窗口。再次执行整套验证前点击“创建测试窗口”重建样本。手动操作可选择窗口后使用刷新、聚焦、最小化与恢复按钮。

## 报告与通过判据

完整验证写入 `.local-data/build/window-probe/window-probe-result.json`；单次按钮操作写入 `window-probe-manual-result.json`，不会覆盖完整验证的结论。报告包含运行模式、时间、授权状态、作用范围和检查结果，不包含个人应用或窗口信息。

整套通过必须同时满足：报告时间属于本次运行、`mode` 为 `verification`、`status` 为 `passed`、`accessibilityGranted` 为 `true`，并有 6 条 PASS。单次操作通过、旧报告或仅编译成功均不算整套通过。

| 状态 | 含义 |
| --- | --- |
| `passed` | 本次对应模式执行成功；仍需区分单次操作与完整验证 |
| `blocked_accessibility` | 辅助功能尚未授权，没有执行窗口控制 |
| `failed` | 目标退出、窗口失效、能力不足或系统未确认预期状态 |

## 当前验证证据

| 项目 | 结果 |
| --- | --- |
| 环境 | Apple Silicon，macOS 27.0（26A428），Xcode 27.2，Swift 6.4.2 |
| 编译与签名 | `python3 scripts/window_probe.py --build --launch --verify`：两个应用编译、ad-hoc 签名与完整性校验通过 |
| 真实 GUI | 控制器已启动，读取了辅助功能树并检查界面截图；首次运行的布局约束异常已修复并重新验证启动 |
| 未授权路径 | 真实报告 `mode=verification`、`status=blocked_accessibility`、`accessibilityGranted=false`；界面显示等待授权 |
| 已授权 6 项窗口检查 | 尚未执行，等待开发者确认授权 |

CI 仅编译两个原型并校验签名，不授予权限、不启动 GUI，也不替代本机窗口验证。

未验证：权限撤销、应用卡顿、睡眠唤醒、多显示器、Space、全屏、其他应用兼容性及最低系统版本；尚未执行 AltTab 适配、窗口缩略图、MRU 或 Dock 输入序列验证。
