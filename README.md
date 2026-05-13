# 豆包语音输入切换

豆包语音输入切换是一个 macOS 辅助工具，用于在语音输入场景中临时切换到豆包输入法，并在结束后恢复原输入法。该项目是非官方工具，不代表豆包或 ByteDance 官方发布。

本项目是纯 Codex Vibe Coding 项目：需求定义、实现、打包脚本和文档均由用户通过 Codex 交互式生成和迭代。

## 功能

- 支持长按模式：按住指定修饰键时切换到豆包输入法，松开后恢复原输入法。
- 支持免按模式：双击指定修饰键开始，再次按键结束并恢复原输入法。
- 支持在应用内选择快捷键。
- 支持检查豆包输入法安装状态、当前输入源、监听状态。
- 提供跳转到辅助功能、输入监控和豆包设置的入口。
- 使用项目自制中性图标，避免与官方应用图标混淆。

## 系统要求

- macOS 13 或更高版本。
- 已安装豆包输入法。
- 首次使用需要授予“辅助功能”和“输入监控”权限。

当前发布包通常由本机 SwiftPM 构建产生，因此架构取决于构建机器。Apple Silicon 机器上构建出的默认产物是 arm64；如需同时支持 Intel Mac，需要额外制作 universal binary。

## 安装

1. 在 GitHub Releases 下载 `DoubaoVoiceLauncher.zip`。
2. 解压后，将 `豆包语音输入切换.app` 拖入“应用程序”目录。
3. 首次打开时，如果 macOS 提示“无法验证开发者”，可右键点击应用并选择“打开”，或在“系统设置 - 隐私与安全性”中允许打开。
4. 按应用界面提示开启“辅助功能”和“输入监控”权限；若授权后仍未生效，退出并重新打开应用。

## 使用

使用方式
- 设置豆包的快捷键。
- 打开应用授权辅助功能和输入监控。
- 重启 APP，设置 APP 的快捷健和豆包一样。
- 开始使用
  - 长按模式用于“按住说话，松手结束”的输入方式。
  - 免按模式用于“双击开始，再次按键结束”的输入方式。

应用仅监听用户选择的快捷键组合，并通过 macOS 本地输入源 API 切换输入法。

## 本地构建

本项目使用 Swift Package Manager 构建：

`./script/build_and_run.sh --no-run`

该命令会生成：

- `dist/豆包语音输入切换.app`

生成 GitHub Release 可上传的压缩包：

`./script/build_and_run.sh --package`

该命令会生成：

- `dist/豆包语音输入切换.app`
- `dist/DoubaoVoiceLauncher.zip`

默认构建配置为 release。如需临时使用 debug 构建，可执行：

`BUILD_CONFIGURATION=debug ./script/build_and_run.sh --no-run`

## 发布到 GitHub

建议采用以下发布方式：

1. 将源码提交到 GitHub 仓库。
2. 本地执行 `./script/build_and_run.sh --package`。
3. 在 GitHub Releases 创建新版本。
4. 上传 `dist/DoubaoVoiceLauncher.zip`。
5. 在 Release notes 中说明系统要求、权限要求、未公证状态和架构限制。

不建议将 `.app`、`.zip` 或 `.build` 目录直接提交到仓库。

## 签名与安全提示

当前脚本使用 ad-hoc 签名，适合个人或小范围试用。公开分发时，macOS 可能提示应用无法验证开发者。若面向更广泛用户发布，建议使用 Apple Developer ID 证书签名，并完成 Apple notarization。

当前源码未包含网络请求逻辑。该工具的核心能力是本地监听快捷键与切换输入法；用户可通过源码审计确认其行为。

## 免责声明

本项目是个人辅助工具。使用者应自行确认其符合所在组织的软件安装、安全与隐私规范。
