# P0 / T0.3 监听会话与环境失效

日期：2026-11-07。状态：会话策略 21/21、原点击策略 51/51、构建签名、三轮真实监听启停，以及实际权限撤销/恢复与单次 Dock 重启通过。睡眠等其余系统变化尚待实测。仅适用于隔离 DockProbe，产品整合及 T0.3 全部兼容矩阵尚未完成。

## 行为

`DockObservationSession` 为每次监听分配代次并固定本次 Dock PID。事件 tap 的上下文保留创建时的 token；AX 返回、两秒输入超时、双击等待后的结算和动作确认都校验原 token。停止后开始新会话，即使 Dock PID 相同，旧结果仍不能进入新监听；延迟的 tap 停用通知也不能停止新会话。

除按下/抬起命中 Dock PID 必须一致外，结算前再次检查当前 Dock PID。这样可以拒绝“鼠标已抬起，但等待双击间隔期间 Dock 重启”的旧候选。检查在事件回调之外执行，回调仍为 `listenOnly`，没有同步 AX、磁盘写入、窗口动作或等待队列。

原有 0.5 秒权限轮询同时核对 Dock 和 tap 可用性；还订阅系统睡眠、屏幕睡眠、用户会话失活、屏幕参数变化及 Dock 启动/终止通知。只关注系统 Dock 的进程通知，其他应用启动不会暂停监听。

| 条件 | 报告状态 | 结果 |
| --- | --- | --- |
| 启动时没有权限或 Dock | `blocked_accessibility` / `blocked_dock` | 不安装监听 |
| 权限失效 | `permission_lost` | 清空输入、取消动作确认并释放监听 |
| Dock 退出或身份变化 | `dock_changed` | 丢弃旧会话候选并释放监听 |
| 系统停用 tap | `tap_disabled` | 释放监听，不循环重新启用 |
| 睡眠、屏幕睡眠或用户会话失活 | `sleeping` / `screen_sleeping` / `session_inactive` | 暂停监听 |
| 屏幕参数变化 | `display_changed` | 暂停监听，避免旧坐标与候选继续执行 |

这些路径释放 tap、run-loop source、回调上下文和轮询定时器。用户需要手动点击“开始观察”重新检查环境；不在唤醒、重新授权或 Dock 重启后自动启用。自建窗口的恢复记录保留，下一次快照按真实窗口状态校验；暂停不会自动展开或收起窗口。

## 验证

```sh
python3 scripts/dock_probe.py --test --build
python3 scripts/dock_probe.py --launch
```

新增纯测试将监听 token 与实际点击策略组合，覆盖停止后的旧结果、同 Dock PID 下的新监听、过期停用通知、Dock 消失/变化、双击等待中失效，以及收起/恢复两类候选在失效后取消、手动重启后可接受新输入。纯测试只证明状态门禁，不证明系统通知已经实际触发。

“验证监听启停”按钮把模式切到只观察，连续三次实际创建并释放本机的 `listenOnly` tap，分别核对安装和资源清理；它不注入或伪造系统权限、Dock 或睡眠事件。报告为 `.local-data/build/dock-probe/dock-listening-verification.json`。

| 验证 | 结果与边界 |
| --- | --- |
| 点击策略 | 51 passed / 0 failed |
| 新监听会话策略 | 21 passed / 0 failed |
| 构建、ad-hoc 签名与严格校验 | 通过，arm64 / macOS 13 构建目标；实际运行在 macOS 27.0 / Xcode 27.2 |
| CUA 触发“验证监听启停” | 3 轮安装/释放、6 项检查通过；结束 `status=stopped`、`eventTapInstalled=false`、`observationSessionActive=false` |
| 实际关闭/恢复本原型辅助功能权限 | `observing` → `permission_lost`，监听与会话均释放；恢复权限后保持停用，手动开始成功 |
| 实际单次重启系统 Dock | 系统 Dock PID 已变化；原型进入 `dock_changed`，监听与会话均释放；Dock 恢复后保持停用，手动开始成功 |
| 故障实测后停止并退出 | `status=stopped`、`eventTapInstalled=false`、`observationSessionActive=false`，进程检查无原型残留 |
| 睡眠/屏幕/会话变化 | 尚未执行，不由纯测试或以上实测推断为通过 |

真实启停报告副本保存在 `.local-data/p0/dock-lifecycle-listening-passed.json`，生成物与原始报告不提交。此前自建窗口及真实 Dock 基础动作证据见 [输入与动作原型](p0-dock-input.md)，本轮不要求重复已通过的手工点击。

## 真实故障实测

用户明确同意两项实测后，使用 `c15234c` 构建全程保持 `mode=observe`。先刷新同一原型身份的既有 ad-hoc 授权，再实际点击“开始观察”，核对权限、tap 和会话均有效。

1. 在系统设置仅关闭本原型的辅助功能开关。界面显示权限失效，报告为 `permission_lost`，`accessibilityGranted=false`、`eventTapInstalled=false`、`observationSessionActive=false`。恢复同一开关后，界面仍保持停用；手动开始后报告更新为 `observing`，权限、tap 和会话均有效。
2. 在活动监视器按进程名称和 PID 核对系统“程序坞”，普通退出一次，由系统自动恢复。只读进程检查和活动监视器均确认 Dock PID 已变化；原型显示 Dock 变化，报告为 `dock_changed`，tap 和会话均无效。Dock 恢复后仍保持停用，手动开始后可重新安装监听。
3. 点击停止并退出，报告确认监听和会话释放，`pgrep -fl 'Loomex Dock Input Probe'` 无匹配。辅助功能权限已恢复，不修改 Dock 偏好，不退出其他用户应用。

停用后的报告是最后一次保存的快照，不继续轮询权限。恢复开关后“不自动监听”由界面保持停用及报告未变化共同核对；权限已恢复由系统开关和随后手动开始产生的新报告核对，不能把旧快照中的 `accessibilityGranted=false` 当作恢复后的实时权限。

本地证据位于 `.local-data/p0/dock-lifecycle-permission-{before,lost,restored-idle,restarted}.json`、`dock-lifecycle-dock-{before,changed,restarted}.json` 与 `dock-lifecycle-stopped.json`，均不提交。本次实际故障在没有鼠标候选时触发；故障期间已有收起/恢复候选的取消由纯策略组合测试覆盖，尚未进行真实输入中的故障注入。

## 后续实测边界

睡眠唤醒、屏幕重配置、多屏、Dock 三个位置/自动隐藏/放大、实际图标重排和最低系统尚未覆盖；轻微移动容忍仍保留既有保守规则。正式产品仍需 AltTab 适配的共享窗口服务，此处没有引入另一套窗口发现或缓存引擎。
