# Loomex Flow 开发约定

## 项目现状

- 产品名 Loomex Flow，仓库名 loomex-mac，整套按 GPL-3.0 路线开源。
- 当前只有 ClassicLaunchpad 1.0.6 基线；窗口切换、Dock 增强和统一应用层尚未实现。
- 先读 README.md、docs/loomex-mac-plan.md 和相关源码，再修改。
- 当前真实目录是 Sources/、Tests/，不要把规划中的模块路径或服务当作已存在的实现。

## 实现边界

- Swift / AppKit 为主，遵循现有风格，避免无关重构。
- 保留已有启动台交互、排序、文件夹和隐藏时的资源释放行为。
- 布局迁移先备份并校验；不得让新旧程序同时写同一布局文件。
- GUI 测试和试运行使用隔离目录；不得上传个人应用列表、布局、截图日志或凭据。
- 引入上游代码时锁定版本，保留版权与许可证，在 THIRD_PARTY_NOTICES.md 记录来源和修改。
- 按规划统一生命周期和窗口服务，避免两个入口、重复事件拦截或重复窗口缓存。

## 验证

```sh
python3 build.py --test --output dist
```

- 当前 59 项 Swift 测试需要 Apple Silicon Mac 和可用的图形会话；GitHub Actions 的 macOS 任务执行构建，Ubuntu 任务验证固定上游源码和 Python 验证脚本测试。
- GUI 行为改变时进行真实交互验证，编译通过不能代替交互通过。
- 报告实际执行的命令和结果；未测的系统版本、多屏及权限行为明确标注。

## Git 与交付

- 功能开发使用短生命周期分支，例如 feat/launcher-shell、fix/dock-click。
- 提交聚焦单一目的，说明改动及验证，避免提交生成物和临时调试代码。
- 不擅自重置、覆盖或丢弃用户改动。
- 默认用中文沟通，明确区分已实现、规划和未经验证的内容。
