# P0 / T0.5 预览原型资源基线

日期：2026-11-07。范围仅为已授权的 Preview Probe 固定自建样本；不是整合后的 Loomex 应用。截图始终只在内存，测量报告只含数值和技术状态。

## 机器与方法

| 条件 | 本轮环境 |
| --- | --- |
| 硬件 | Mac16,10 / Apple M4 / 32 GiB / arm64 |
| 系统与构建 | macOS 27.0（26A428）/ Xcode 27.2；预览实现基线 `3565cf2` |
| 显示 | 单屏 2560×1440 @ 144 Hz；不据此推断其他缩放或多屏表现 |
| 内容 | 同进程固定样本；截图 560×352、811,008 字节；没有其他应用样本 |
| 采样 | 每秒一次 `proc_pid_rusage(RUSAGE_INFO_V0)`；记录 physical footprint，RSS 另列而不替代 footprint |
| CPU | 用户与系统 CPU 时间增量 / monotonic 墙钟增量，按单核百分比；不除以 CPU 核数 |

`scripts/preview_budget.py` 核对本地原型的构建标记、Bundle ID 和精确可执行路径，采样期间核对进程启动时间及可执行 UUID。退出、PID 复用、换程序或计数回退会终止测量；不读取窗口列表、标题或图片，不控制 GUI，不申请权限，不提权。

本机原生验证先发现 CPU 计数使用 Mach ticks；脚本通过 `mach_timebase_info` 转换，与独立的 `time.process_time_ns()` 交叉校验。没有用未经转换的数值形成基线。`vmmap -summary` 的冷启动 footprint 约 25.3 MiB，与相邻时刻原生采样约 25.4 MiB 相符；不要求异步读数逐字节一致。

## 实测

先冷启动采样，再预热截图一次；随后通过真实 GUI 完成 50 次“打开面板 → 捕获一次 → 收起”。每次均检查预览就绪，再检查收起后图片和在途请求为 0。累计请求与完成数为 51 / 51，含一次预热。

| 阶段 | 观察时长 | 单核 CPU 均值 | physical footprint 范围 |
| --- | --- | --- | --- |
| 冷启动、尚未打开样本 | 10.01 秒 | 0.077% | 25.39–25.44 MiB |
| 一张预览保留 | 10.00 秒 | 0.103% | 30.19–30.25 MiB |
| 重复截图期间观察窗 A | 180.01 秒 | 6.711% | 29.49–32.52 MiB |
| 重复截图期间观察窗 B | 60.00 秒 | 4.994% | 29.61–32.19 MiB |
| 预览面板收起，稳定 60 秒后 | 60.00 秒 | 0.000%（计数未变） | 29.70–29.70 MiB |

两个重复截图观察窗包含 GUI 点击等待及部分静止时间，分别报告，不能当作每次截图的 CPU 成本或截图延迟。数值只覆盖原型进程，不包含 WindowServer 或其他系统捕获服务。空闲条件为预览面板收起、其余自建测试窗口静止；没有把整个应用隐藏作为本轮必要条件。

| 已完成的真实开关次数（不含预热） | 收起后 footprint | 图片缓存 / 在途 |
| --- | --- | --- |
| 10 | 29.49 MiB | 0 字节 / 0 |
| 20 | 29.59 MiB | 0 字节 / 0 |
| 30 | 29.75 MiB | 0 字节 / 0 |
| 40 | 29.75 MiB | 0 字节 / 0 |
| 50 | 29.70 MiB | 0 字节 / 0 |

在该有限样本中，后 40 次开关的收起后 footprint 变化约 +0.22 MiB，没有持续线性增加；这不能证明长期无泄漏。收起后仍高于冷启动，差值归属没有通过堆分析定位，不将图片缓存清零等同于进程所有内存回到冷启动值。

稳定空闲段的 61 个样本均为 31,147,112 字节，CPU 增量在系统计数精度内为 0；采样前后请求/完成仍为 51/51，没有后台新增捕获。仅该原型在本轮达到 <1% 的单核空闲 CPU 参考线，不能替代组合应用的 NFR-02 验收。退出后报告为 `stopped`、0 缓存、0 在途、图片宽高均为 0，进程检查无残留。

## 复现与证据

使用当前本地构建，在 GUI 中建立对应阶段；以下变量仅接受唯一运行中的原型 PID，脚本会再次核对路径。

```sh
PREVIEW_PROBE_PID="$(pgrep -x PreviewExperiment)"
python3 scripts/preview_budget.py --pid "$PREVIEW_PROBE_PID" --phase baseline --duration 10
python3 scripts/preview_budget.py --pid "$PREVIEW_PROBE_PID" --phase preview --duration 10
python3 scripts/preview_budget.py --pid "$PREVIEW_PROBE_PID" --phase cycles --duration 180
python3 scripts/preview_budget.py --pid "$PREVIEW_PROBE_PID" --phase idle --settle 60 --duration 60
python3 -m unittest discover -s Tests -p 'test_preview_budget.py' -v
```

阶段名称由操作人根据 GUI 状态选择，采样器不自动建立这些阶段。每份报告写入带时间戳的 `.local-data/p0/preview-resources-*.json`，只保存本地；里程碑状态为 `preview-budget-after-{10,20,30,40,50}.json`。无截图保存或上传。

验证脚本 9 项测试通过，覆盖错误程序、PID 复用、CPU/footprint 计算、计数回退、非法时长及 macOS 原生时间单位；包含已有上游保护测试的 Python 全套为 17 项。Ubuntu CI 跳过其中 1 项原生测试，macOS CI 实际执行。

## 尚未验收

组合应用的 150 MiB 预算、Launch/Switch P95 交互延迟、GPU 呈现、长时泄漏、多个真实应用窗口和完整 T0.5 架构复核均未完成。本轮也不补齐权限撤销、睡眠、Space/全屏、多屏及 macOS 13–25 的兼容矩阵。继续保留隔离原型，不进入大规模 AltTab 源码抽离。
