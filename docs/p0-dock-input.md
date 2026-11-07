# P0 / T0.3 Dock 输入原型

日期：2026-11-07。状态：只观察切片的基础输入实测已完成，包含前台单击、后台激活、双击取消、Shift、拖动放行及无窗口 reopen；用户确认右键菜单正常。第二切片的自身 AppKit 动作 6/6、真实 Dock 隐藏/恢复及最小化/定向恢复链均已通过，恢复 B 后 A 保持手动最小化。已停止监听并退出；兼容矩阵尚未完成，T0.3 整体门禁尚未通过。

## 运行

```sh
python3 scripts/dock_probe.py --test --build
python3 scripts/dock_probe.py --launch
```

产物：`.local-data/build/dock-probe/Loomex Dock Input Probe.app`。Bundle ID：`com.loomex.flow.p0.dockprobe`。最低构建目标 arm64 / macOS 13；本机为 macOS 27.0 / Xcode 27.2，其他版本未实际运行。

这是独立 AppKit 实验应用，同时充当自建 Fixture。自身图标仅在实验中作为目标，正式产品中 Loomex 自身固定排除。没有调用 AltTab，没有引入另一套产品窗口服务，也没有修改启动台布局或 T0.2 窗口原型。

## 输入设计与当前边界

1. 只有点击“开始观察”才尝试安装 `CGEventTap`，采用 `listenOnly`，始终返回原事件。默认只观察，不执行窗口动作；可选动作仅限本进程登记的测试窗口。无事件吞掉、重放或 Dock 配置写入。未授权时不安装监听，不自动反复弹权限提示。
2. 主线程在鼠标按下回调中记录当前前台 PID 是否为自身、已登记的自身普通窗口数（含隐藏/最小化）、时间、修饰键、多击计数及动作上下文。事件回调内没有同步 AX、文件 I/O、窗口控制、截图、网络或等待队列。
3. 串行队列分别异步读取按下和抬起位置的 Dock AX 元素，只比较 role、subrole 与自身 bundle URL。每次重新取得 Dock 进程，AX 单次消息 timeout 为 0.2 秒；不同 Dock PID、未知命中或过时结果放行。不会把其他应用 URL、PID、名称、窗口标题、指针坐标或键盘内容写入报告。
4. 主线程拥有手势和策略状态；同时只允许一个在途命中序列，过载放行。缺少抬起 2 秒后清空序列，停止/退出/权限失效/tap 停用清空候选。命中读操作无法强制中断；其旧结果会因序列失效被丢弃。
5. 任意拖动事件（包括极短拖动）、移动超过 4 点、超过 0.5 秒的长按、修饰键、右键和非目标项目不产生候选。保留系统 Dock 菜单和重排行为。
6. 点击前不在前台且没有自身恢复记录则判定 `background`；点击前无普通窗口则判定 `noWindows`。由系统正常激活或 reopen，不根据抬起时的新前台/窗口状态反推按下前状态。有自身恢复记录时可进入 `pendingRestore`。
7. 单击在抬起后等待系统 `NSEvent.doubleClickInterval`；第二次按下取消候选，快速连击与系统多击计数均放行。默认仅记录 `wouldHide`；动作模式按 `wouldHide` / `wouldRestore` 分别请求收起或恢复。延迟结果绑定手势序列，旧 timer 不能结算新点击；执行前还检查当前前台、权限、模式、登记窗口和上下文版本。

AX 命中发生在事件回调之后，可能受 Dock 动画和队列延迟影响。原事件全部放行，**不能证明正式拦截可在系统处理前获得可靠命中**。系统默认行为与增强动作时序仍须实测；不能依据本原型直接启用产品增强。

## 自身窗口动作实验

模式默认为“只观察”。“隐藏本原型”调用本进程的 AppKit 隐藏；“最小化本窗口”仅操作按下前捕获的自身主窗口。A 为控制面板，B 由“打开测试窗口 B”创建。全屏、附带 sheet、模态、未登记窗口、过期上下文与正在确认的动作均拒绝执行。

A/B 明确禁用自动标签页合并。应用菜单的“显示控制面板 A”（⌘1）可在 B 显示时显式打开或恢复 A；该入口由用户主动调用，Dock 的 `reopen` 仍不展开已有手动最小化窗口。动作完成记录与报告附带自身 A/B 的可见、最小化和 key 状态，用于核对定向恢复，没有保存实际窗口标题。

`OwnedWindowActions` 是夹具动作器，只持有本进程主动登记的 `NSWindow`，不枚举或控制其他应用，不承担产品窗口发现、MRU 或缓存职责。正式 Switch / Dock 仍须使用 AltTab 适配的共享窗口服务。

每次收起记录窗口会话 UUID 和动作类型；关闭后注销，同一窗口对象重新打开获得新身份。恢复隐藏不批量展开已最小化窗口，恢复最小化只展开记录窗口。用户手动恢复后，下次快照会清理旧记录。已有普通窗口时，`reopen` 不无条件展开控制面板；仅零登记窗口时重新打开面板。

“运行本地动作验证”暂停监听，异步驱动真实 AppKit A/B：两窗口就绪、隐藏、恢复并聚焦 A、手动最小化 A 后收起 B、只恢复 B 保留 A、关闭 B 后拒绝旧恢复。过程使用主线程定时确认，不阻塞主线程。停止、退出或切换模式会取消验证；收尾恢复控制面板并保持监听停止。

本地结果单独写入 `.local-data/build/dock-probe/dock-actions-verification.json`，不覆盖 Dock 输入报告。**这六项是 AppKit 自建窗口动作验证，不代表真实 Dock 输入到动作的整链通过。** 通过自动化按钮触发时曾因 `NSApp.isActive=false` 在第一项超时，报告确认 A/B 均可见且未最小化；保留门禁，需在真实前台会话触发验证。

用户随后从桌面前台触发，第一项就绪通过，但“隐藏本原型应用”未确认，后续四项未执行。报告副本为 `.local-data/p0/dock-actions-failed-hide.json`。验证准备阶段移除多余的激活/取消隐藏请求，避免排队的准备动作与下一步隐藏互相干扰；恢复动作也仅在需要时请求激活或取消隐藏。修正后用户从同一前台入口复测 **6/6 passed**，六项原断言全部保留，没有延长确认超时。完整动作证据为 `.local-data/p0/dock-actions-passed.json`。

动作报告新增本进程的 `didHide` / `didUnhide` / 激活生命周期及相对时间、窗口可见和最小化状态，最多 80 条，不包含其他应用身份。新构建已刷新同一原型的既有辅助功能记录，实际可建立只读监听；本地动作验证期间仍保持监听停止。

新增纯策略回归：恢复同样等待双击间隔、第二次按下取消、只结算一次、修饰键/拖动/零窗口/未知命中不能绕过、停止使恢复候选失效。当前 `python3 scripts/dock_probe.py --test` 为 **51 passed / 0 failed**；构建及签名校验通过。输入报告新增自身手势的相对位移和时长，不记录绝对坐标。

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
| 早期前台补测（含移动） | 两次输入均记录 `dragged=true`、`decision=drag`，按保守规则排除，不计作普通单击通过证据 |
| 用户最终补测：静止指针前台单击 | 连续记录 3 次 `pending → wouldHide`，均为 `foregroundBefore=true`、`dragged=false`、`modified=false`、`clickCount=1`；只记录判定，未隐藏窗口 |
| 用户补测：无窗口后点 Dock | 记录 `ordinaryWindowsBefore=0`、`decision=noWindows`；用户确认窗口重新打开正常 |
| 用户补测：右键菜单 | 用户确认系统菜单正常并可关闭；只读原型不吞右键，也不写非主键候选 |
| GUI：停止、关闭实验窗口、重新打开、⌘Q | 停止状态正确；实验进程在关闭窗口后保留；重新打开恢复面板，新增退出菜单支持 ⌘Q。此项不代表 Dock 命中测试通过 |
| GUI：实测结束后停止监听、⌘Q 退出 | 界面显示停止；报告 `status=stopped`、`eventTapInstalled=false`；进程检查确认无 `DockInputExperiment` 残留 |
| `python3 build.py --test --output dist-p0-dock` | 启动台 59 passed / 0 failed，构建和签名通过 |
| `python3 scripts/window_probe.py --test` | 窗口原型确认逻辑 7 passed / 0 failed |
| T0.2 最新 CI run 42274828019 | 首次 hosted runner 容量不足，未执行构建；重跑后两项 job 成功 |
| 第二切片 `python3 scripts/dock_probe.py --test --build` | 点击策略 51/51、app 构建与签名校验通过；不代表 GUI 动作验收 |
| 用户真实前台运行本地动作验证（4d383bd） | **6/6 passed**；生命周期记录 `didHide`、`didUnhide`，A 保留手动最小化、B 定向恢复、关闭 B 后旧请求被拒绝 |
| 用户真实 Dock 单击隐藏、再次点击恢复 | `pending → wouldHide → 隐藏 action=true`，随后点击前处于后台且持有恢复记录，`pendingRestore → wouldRestore → 恢复 action=true`；用户确认隐藏和恢复正常 |
| 真实 Dock 最小化/定向恢复 | CUA 点击 A 黄色按钮手动最小化后，用户令 B 前台并单击 Dock：收起 `action=true`，A/B 均最小化；再次单击后恢复 `action=true`，B 可见且 key，A 仍最小化且不可见；用户确认 B 已收起并恢复 |
| 第二切片停止/退出 | CUA 点击停止，报告 `status=stopped`、`eventTapInstalled=false`；⌘Q 后进程检查为 0 |
| CI run 42345094563（4d383bd） | 固定上游验证与 Apple Silicon 构建两项 job 均成功；CI 未运行 GUI 动作 |

策略测试覆盖单击等待、一次结算、点击前后台状态、后台激活后的连击、第二次 down 取消、无窗口、修饰键、短拖、移动、长按、其他项目、未知命中、释放到不同项目、Dock PID 改变、系统多击、旧 AX 结果、暂停/撤销/停用取消、旧 timer 不结算新手势。测试是纯策略证据，不是系统事件与 Dock 命中的实机证据。

报告位于 `.local-data/build/dock-probe/dock-probe-result.json`，保留最近 40 条自身图标的脱敏观察结果；生成物与报告不提交 Git。报告不是自动验收通过标记。

第一轮报告副本：`.local-data/p0/dock-probe-manual-round1.json`。原始记录包含 5 条决策：后台单击 1 条、双击 2 条、Shift 点击 1 条、短拖 1 条；均未执行窗口动作。

补测报告副本：`.local-data/p0/dock-probe-manual-round2.json`。新增 2 条 `drag` 和 1 条 `noWindows`。当前任意 `leftMouseDragged` 都会被排除；用户意图为单击的输入若包含这类事件也会放行，点击容忍度仍需实机评估，不能只凭纯策略测试认定可用性。

最终完整输入副本：`.local-data/p0/dock-probe-manual-complete.json`，包含 3 次前台普通单击结算。停止与退出报告：`.local-data/p0/dock-probe-stopped.json`。真实鼠标输入由用户操作，界面停止与退出由 CUA 操作，本地报告和进程检查交叉核对；没有为通过测试放宽拖动规则。

第二切片证据：`.local-data/p0/dock-actions-passed.json` 保存本地 AppKit 6 项实测；`dock-actions-hide-chain.json` 保存真实 Dock 隐藏/恢复；`dock-actions-minimize-chain.json` 保存最小化/恢复及每次动作完成时的 A/B 状态；`dock-actions-stopped.json` 保存停止状态。早期 `dock-actions-minimize-incomplete.json` 虽记录了收起/恢复，但缺少 A 手动最小化的状态证据，不用于证明保留 A。新增窗口入口后已按完整场景重新验证，无需再重复这组手工操作。

## 剩余验证与实现

本轮基础输入与清理验证已结束，无需重复以上手工操作。CUA 获取 Dock 界面超时，真实 Dock 输入由用户手动操作；没有改用其他自动化方式发送鼠标事件。首次短拖的抬起命中仍不确定，实际 Dock 重排尚未验证。

第二切片在本机完成了自建 AppKit 动作与真实 Dock 的基础单击链。该结果限于本原型和当前系统环境，不覆盖其他应用、所有系统默认行为时序或兼容矩阵。轻微移动容忍度仍待评估，当前任何拖动事件都放行。`wouldHide` / `wouldRestore` 是策略结果，实际动作另记 `action` 与 `succeeded`，不能把策略结算当作动作成功。

Dock 三个位置、自动隐藏、放大、多屏、睡眠唤醒和最低系统仍未验证。权限撤销/恢复与单次 Dock 重启已在第三切片的只观察模式完成，结果见下方生命周期文档；不代表输入中的故障注入或完整兼容矩阵已通过。修改系统 Dock 配置或重启 Dock 前单独说明范围并按用户授权执行。

第三切片的会话隔离、环境失效暂停及真实监听启停结果见 [监听生命周期验证](p0-dock-lifecycle.md)。系统故障实测状态以该文档逐项记录为准。
