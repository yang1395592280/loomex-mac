# 参与开发

## 从任务到代码

1. 阅读 README.md 和产品规划，确认当前真实实现及本次范围。
2. 同步 main，并从它创建功能或修复分支。
3. 完成小步改动与相关验证，通过 Pull Request 合并。

```sh
git switch main
git pull --ff-only
git switch -c feat/launcher-shell
```

分支名按实际任务命名。示例分支用于未来的统一应用层开发，并不表示该功能已经存在。

## 构建和测试

```sh
python3 build.py --test --output dist
```

需要 Apple Silicon Mac、Python 3、Xcode Command Line Tools 和可用的 macOS 图形会话。仅构建使用 `python3 build.py --output dist`。

试运行通过 `CLASSIC_LAUNCHPAD_SUPPORT_DIR` 指向独立目录，例如仓库内的 `.local-data/launch`。不要对个人正式布局执行测试，不要把本机应用列表和运行日志加入提交。

提交前执行 `git diff --check`，并在 PR 中说明问题、行为变化、已执行的验证及未覆盖场景。界面、拖拽、快捷键、权限等改动需要对应的实际交互检查。

## 引入第三方代码

先检查许可证与版本兼容性，固定提交或发布标签，保留原有版权说明，在 THIRD_PARTY_NOTICES.md 中记录复用范围。当前计划中的 AltTab 和 Dock 项目尚未导入，不能将其功能表述为已经完成。

## 生成物和配置

构建产物、个人配置、签名证书、Token、布局及临时日志不进入版本管理。GitHub Actions 当前只验证构建；有图形会话要求的测试在本机运行并报告结果。
