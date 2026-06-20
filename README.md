# Doubao Voice Switch

豆包语音切换器是一个 macOS 菜单栏小工具。使用其他输入法时，如果想要进行语音输入，它会自动切换到豆包输入法并交给豆包处理；语音输入结束后，再切换回原来的输入法。

## 关于

这是一个使用 Codex 协作开发的纯 vibe coding 项目。需求、调试、UI 调整和实现都通过自然语言迭代完成。

## 截图

![菜单栏](docs/images/menu-bar.png)

![设置页](docs/images/settings.png)

## 功能

- 菜单栏常驻运行
- 支持点按或长按豆包语音快捷键
- 自动切换到豆包输入法
- 语音结束后切回原输入法
- 支持开机自启动
- 本地日志按天滚动，保留 7 天

## 使用

1. 安装并启用豆包输入法。
2. 打开 Doubao Voice Switch。
3. 在系统设置中授予辅助功能权限。
4. 在设置页把快捷键设置为与豆包输入法一致。
5. 使用快捷键启动豆包语音输入。

## 开发

构建：

```bash
swift build
```

运行并打包本地 app：

```bash
./script/build_and_run.sh --verify
```

运行核心行为测试：

```bash
swift run DoubaoVoiceSwitchCoreBehaviorTests
```
