# 豆包语音输入切换

豆包语音输入切换是一个 macOS 辅助工具，用于在语音输入场景中临时切换到豆包输入法，并在结束后恢复原输入法。该项目是非官方工具，不代表豆包或 ByteDance 官方发布。

本项目是纯 Codex Vibe Coding 项目：需求定义、实现、打包脚本和文档均由用户通过 Codex 交互式生成和迭代。

## 功能

- 支持长按和单击两种触发模式。
- 启动语音输入时临时切换到豆包输入法，结束后恢复原输入法。
- 支持在应用内选择各模式的快捷键；未选择快捷键的模式不会触发。
- 支持配置转发延迟和长按触发时长。
- 支持检查豆包输入法安装状态、当前输入源和后台监听状态。
- 提供辅助功能和豆包设置的快捷入口。
- 提供本地调试日志，便于排查快捷键、输入法切换和语音启动确认问题。

## 系统要求

- macOS 13 或更高版本。
- 已安装豆包输入法。
- 首次使用需要授予“辅助功能”权限。

当前发布包通常由本机 SwiftPM 构建产生，因此架构取决于构建机器。Apple Silicon 机器上构建出的默认产物是 arm64；如需同时支持 Intel Mac，需要额外制作 universal binary。

## 安装

1. 在 GitHub Releases 下载 `DoubaoVoiceLauncher.zip`。
2. 解压后，将 `豆包语音输入切换.app` 拖入“应用程序”目录。
3. 首次打开时，如果 macOS 提示“无法验证开发者”，可右键点击应用并选择“打开”，或在“系统设置 - 隐私与安全性”中允许打开。
4. 按应用界面提示开启“辅助功能”权限；若授权后仍未生效，退出并重新打开应用。

## 使用

使用方式
- 在豆包输入法中设置语音输入快捷键。
- 打开应用并授权辅助功能。
- 重启应用，在应用内按需把“长按模式”或“单击模式”的快捷键设置为与豆包语音输入快捷键一致。
- 按需调整时间设置：
  - 转发延迟：切换为豆包输入法后，触发快捷键延迟。
  - 长按触发时长：按住快捷键多久后识别为长按。
- 开始使用：
  - 长按模式用于“按住说话，松手结束”。应用会在按住期间临时切换到豆包输入法，并在松开后恢复原输入法。
  - 单击模式用于“单击开始，再次单击结束”。第一次单击快捷键后，应用会临时切换到豆包输入法，并代为保持豆包语音快捷键按下；再次单击同一快捷键后，应用会释放该快捷键并恢复原输入法。

应用仅监听用户选择的快捷键组合，并通过 macOS 本地输入源 API 切换输入法。

## 免按模式启动确认机制

单击模式属于免按模式：应用会代替用户保持豆包语音快捷键按下，直到用户再次触发结束。由于 macOS 输入法切换完成不等于豆包输入法内部语音链路已经准备完成，应用在免按模式中使用以下启动流程：

1. 切换到豆包输入法，并确认当前输入源已经变成豆包。
2. 立即向豆包发送一次同快捷键的 `keyUp`，用于清理可能残留的修饰键状态。
3. 等待用户在 App 内配置的转发延迟。
4. 发送第一次 `keyDown`，开始尝试启动豆包语音输入。
5. 在 `350ms`、`600ms`、`750ms` 三个累计时间点检测豆包输入法是否正在运行音频输入流。
6. 任一检测点确认成功后，应用进入语音输入保持状态。
7. 三次检测都失败时，应用会发送 `keyUp`，等待 `100ms`，再发送第二次 `keyDown` 重试一次。
8. 第二次仍未确认成功时，应用会释放快捷键并恢复原输入法，方便用户再次触发。

该机制只用于单击免按模式，不改变长按模式的“按住说话，松手结束”语义。

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

默认构建配置为 debug，用于保持快捷键合成事件的运行时行为与当前可用包一致。如需临时使用 release 构建，可执行：

`BUILD_CONFIGURATION=release ./script/build_and_run.sh --no-run`

## 调试日志

应用会把关键调试信息自动保存到：

`~/Library/Logs/DoubaoVoiceLauncher/DoubaoVoiceLauncher.log`

同时，应用仍使用 `com.local.doubao.voice-launcher` 作为 macOS unified logging subsystem，并按 `App`、`UI`、`Permissions`、`Automation`、`Shortcut`、`InputSource` 分类记录关键运行事件。

排查免按模式启动问题时，优先查看以下日志片段：

- `No-hold activation preflight reset keyUp sent`：表示输入法确认后已经前置发送一次 `keyUp` reset。
- `No-hold activation pending after forwarded keyDown`：表示某次启动尝试已经发送 `keyDown`。
- `No-hold activation probe 1/3`、`2/3`、`3/3`：表示 `350ms / 600ms / 750ms` 的启动确认检测。
- `No-hold activation attempt 1 failed`：表示第一次三段检测均未确认成功，应用将释放快捷键并重试一次。
- `No-hold activation confirmed`：表示已经检测到豆包输入法正在运行音频输入流。

启动应用并查看自动保存的文件日志：

`./script/build_and_run.sh --tail-file-log`

启动应用并查看本应用的 telemetry：

`./script/build_and_run.sh --telemetry`

如果需要按进程查看更宽泛的运行日志，可执行：

`./script/build_and_run.sh --logs`

## 签名与安全提示

当前脚本使用 ad-hoc 签名，适合个人或小范围试用。公开分发时，macOS 可能提示应用无法验证开发者。若面向更广泛用户发布，建议使用 Apple Developer ID 证书签名，并完成 Apple notarization。

当前源码未包含网络请求逻辑。该工具的核心能力是本地监听快捷键与切换输入法；用户可通过源码审计确认其行为。

## 免责声明

本项目是个人辅助工具。使用者应自行确认其符合所在组织的软件安装、安全与隐私规范。
