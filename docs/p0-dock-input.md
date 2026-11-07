# P0 / T0.3 Dock 输入原型

日期：2026-11-07。状态：第一切片已实现，策略与构建、真实未授权路径通过；用户确认后已完成辅助功能授权，只读监听已安装。真实输入已记录后台激活、双击取消、Shift 排除、拖动时的安全放行和无窗口 reopen；用户确认右键菜单正常。前台普通单击尚未完成结算验证，T0.3 尚未通过。

## 运行

```sh
python3 scripts/dock_probe.py --test --build
python3 scripts/dock_probe.py --launch
```

产物：`.local-data/build/dock-probe/Loomex Dock Input Probe.app`。Bundle ID：`com.loomex.flow.p0.dockprobe`。最低构建目标 arm64 / macOS 13；本机为 macOS 27.0 / Xcode 27.2，其他版本未实际运行。

这是独立 AppKit 实验应用，同时充当自建 Fixture。自身图标仅在实验中作为目标，正式产品中 Loomex 自身固定排除。没有调用 AltTab，没有引入另一套产品窗口服务，也没有修改启动台布局或 T0.2 窗口原型。

## 输入设计与当前边界

1. 只有点击“开始观察”才尝试安装 `CGEventTap`，采用 `listenOnly`，始终返回原事件。无事件吞掉、重放、窗口控制或 Dock 配置写入。未授权时不安装监听，不自动反复弹权限提示。
2. 主线程在鼠标按下回调中记录当前前台 PID 是否为自身、自己的可见/最小化窗口数量、时间、修饰键与多击计数。事件回调内没有同步 AX、文件 I/O、截图、网络或等待队列。
3. 串行队列分别异步读取按下和抬起位置的 Dock AX 元素，只比较 role、subrole 与自身 bundle URL。每次重新取得 Dock 进程，AX 单次消息 timeout 为 0.2 秒；不同 Dock PID、未知命中或过时结果放行。不会把其他应用 URL、PID、名称、窗口标题、指针坐标或键盘内容写入报告。
4. 主线程拥有手势和策略状态；同时只允许一个在途命中序列，过载放行。缺少抬起 2 秒后清空序列，停止/退出/权限失效/tap 停用清空候选。命中读操作无法强制中断；其旧结果会因序列失效被丢弃。
5. 任意拖动事件（包括极短拖动）、移动超过 4 点、超过 0.5 秒的长按、修饰键、右键和非目标项目不产生候选。保留系统 Dock 菜单和重排行为。
6. 点击前不在前台则判定 `background`；点击前无普通窗口则判定 `noWindows`。由系统正常激活或 reopen，不根据抬起时的新前台/窗口状态反推按下前状态。
7. 单击在抬起后等待系统 `NSEvent.doubleClickInterval`；第二次按下取消候选，快速连击与系统多击计数均放行。最终只记录 `wouldHide`，仍不执行隐藏。延迟结果绑定手势序列，旧 timer 不能结算新点击。

AX 命中发生在事件回调之后，可能受 Dock 动画和队列延迟影响。本切片用于采集输入事实，**不能证明正式拦截可在系统处理前获得可靠命中**。最终拦截或放行序列、丢失按键风险和动作时序需另一个切片验证；不能依据本原型直接启用产品增强。

## 权限

- AX 读取 Dock 需要本实验应用的辅助功能授权；原 Window Probe 的授权不覆盖新 Bundle ID。
- 鼠标只读 tap 的实际可用性由系统创建结果决定；`CGPreflightListenEventAccess` 仅记录当前状态，未提前申请输入监控。只有系统阻止 tap 且证实需要时才进一步申请。
- 本机授权后实际返回 `accessibilityGranted=true`、`eventTapInstalled=true`、`listenEventAccess=false`，状态为 `observing`；随后已收到用户真实鼠标操作和自身图标命中，未额外申请输入监控。该结论限于本机环境，不代表整个输入矩阵已通过。
- 不需要屏幕录制。未操作 TCC 数据库，不修改签名以冒充其他应用。
- 本地 ad-hoc 重建后权限可能失效，需核对当前进程真实状态，不能仅看设置开关。

## 验证记录

| 验证 | 实际结果 |
| --- | --- |
| `python3 scripts/dock_probe.py --test --build --launch` | 策略 36 passed / 0 failed；app 编译、ad-hoc 签名及严格校验成功，已真实启动 |
| GUI：点击“开始观察” | 显示“等待本实验应用的辅助功能授权；未安装事件监听。” |
| 本地报告 | `status=blocked_accessibility`、`accessibilityGranted=false`、`observations=[]` |
| 用户确认后刷新原型授权、点击开始 | `status=observing`、`accessibilityGranted=true`、`eventTapInstalled=true`；未开启额外输入监控 |
| 用户第一轮：单击 | 按下前不在前台，记录 `background`，保持系统激活行为；本项不替代前台单击验证 |
| 用户第一轮：快速双击 | 首次 `pending`，第二次 `rapidClick`、`clickCount=2`；后续无 `wouldHide`，候选已取消 |
| 用户第一轮：Shift 点击 | 记录 `modifiers`、`modified=true`，未产生收起候选 |
| 用户第一轮：短拖后放回 | 记录 `dragged=true`、`decision=uncertain`；抬起命中不可确认时放行，不宣称拖动精确命中通过 |
| 用户补测：前台单击 | 两次输入均记录 `dragged=true`、`decision=drag`，按保守规则排除；尚不能判定普通单击结算通过，已请求静止指针再确认 |
| 用户补测：无窗口后点 Dock | 记录 `ordinaryWindowsBefore=0`、`decision=noWindows`；用户确认窗口重新打开正常 |
| 用户补测：右键菜单 | 用户确认系统菜单正常并可关闭；只读原型不吞右键，也不写非主键候选 |
| GUI：停止、关闭实验窗口、重新打开、⌘Q | 停止状态正确；实验进程在关闭窗口后保留；重新打开恢复面板，新增退出菜单支持 ⌘Q。此项不代表 Dock 命中测试通过 |
| `python3 build.py --test --output dist-p0-dock` | 启动台 59 passed / 0 failed，构建和签名通过 |
| `python3 scripts/window_probe.py --test` | 窗口原型确认逻辑 7 passed / 0 failed |
| T0.2 最新 CI run 42274828019 | 首次 hosted runner 容量不足，未执行构建；重跑后两项 job 成功 |

策略测试覆盖单击等待、一次结算、点击前后台状态、后台激活后的连击、第二次 down 取消、无窗口、修饰键、短拖、移动、长按、其他项目、未知命中、释放到不同项目、Dock PID 改变、系统多击、旧 AX 结果、暂停/撤销/停用取消、旧 timer 不结算新手势。测试是纯策略证据，不是系统事件与 Dock 命中的实机证据。

报告位于 `.local-data/build/dock-probe/dock-probe-result.json`，保留最近 40 条自身图标的脱敏观察结果；生成物与报告不提交 Git。报告不是自动验收通过标记。

第一轮报告副本：`.local-data/p0/dock-probe-manual-round1.json`。原始记录包含 5 条决策：后台单击 1 条、双击 2 条、Shift 点击 1 条、短拖 1 条；均未执行窗口动作。

补测报告副本：`.local-data/p0/dock-probe-manual-round2.json`。新增 2 条 `drag` 和 1 条 `noWindows`。当前任意 `leftMouseDragged` 都会被排除；用户意图为单击的输入若包含这类事件也会放行，点击容忍度仍需实机评估，不能只凭纯策略测试认定可用性。

## 待执行的实机矩阵

CUA 获取 Dock 界面超时，真实 Dock 输入由用户手动操作，并由本地报告核对；没有改用其他自动化方式发送鼠标事件。第一轮和无窗口/右键补测已完成。当前补测：静止指针的前台单击等待结算；随后验证停止监听与退出。首次短拖的抬起命中及实际重排仍需进一步验证。

Dock 三个位置、自动隐藏、放大、Dock 重启、多屏、权限撤销、睡眠唤醒和最低系统仍未验证。修改系统 Dock 配置或重启 Dock 前单独说明范围并按用户授权执行。
