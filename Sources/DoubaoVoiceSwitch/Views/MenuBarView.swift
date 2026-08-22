import AppKit
import DoubaoVoiceSwitchCore
import SwiftUI

struct MenuBarView: View {
  @ObservedObject var model: AppModel

  @AppStorage("recognitionWindowSeconds") private var recognitionWindowSeconds =
    VoiceSessionRecognitionPolicy.defaultWindowSeconds
  @AppStorage("launchAtLogin") private var launchAtLogin = false

  private let recognitionWindowPresets = [1.0, 1.5, 2.0, 3.0, 5.0]

  var body: some View {
    Text("状态：\(model.statusTitle)")

    if let failure = model.lastFailureMessage {
      Text(shortMenuText(failure))
    }

    if !model.isDoubaoInputSourceAvailable {
      Text("未检测到豆包输入法")
    }

    Divider()

    Button(model.status == .paused ? "继续观察" : "暂停观察") {
      if model.status == .paused {
        model.resume()
      } else {
        model.pause()
      }
    }

    Menu("识别窗口：\(formattedWindowSeconds) 秒") {
      ForEach(recognitionWindowPresets, id: \.self) { seconds in
        Button {
          recognitionWindowSeconds = seconds
        } label: {
          if isSelected(seconds) {
            Label(formatSeconds(seconds), systemImage: "checkmark")
          } else {
            Text(formatSeconds(seconds))
          }
        }
      }

      Divider()

      Button("自定义…") {
        presentRecognitionWindowEditor()
      }
    }

    Toggle("开机启动", isOn: $launchAtLogin)

    Divider()

    Button("打开日志文件夹") {
      model.openLogFolder()
    }

    Button("清空日志", role: .destructive) {
      model.clearLogs()
    }

    Divider()

    Button("退出豆包语音切换器") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
    .onChange(of: launchAtLogin) {
      model.setLaunchAtLogin(launchAtLogin)
    }
    .onAppear {
      launchAtLogin = model.isLaunchAtLoginEnabled()
    }
  }

  private var formattedWindowSeconds: String {
    formatSeconds(recognitionWindowSeconds)
  }

  private func formatSeconds(_ seconds: Double) -> String {
    String(format: "%.1f", seconds)
  }

  private func isSelected(_ seconds: Double) -> Bool {
    abs(recognitionWindowSeconds - seconds) < 0.05
  }

  private func shortMenuText(_ text: String) -> String {
    guard text.count > 30 else {
      return text
    }
    return String(text.prefix(27)) + "…"
  }

  private func presentRecognitionWindowEditor() {
    let alert = NSAlert()
    alert.messageText = "设置识别窗口"
    alert.informativeText = "请输入 0.0 到 10.0 秒，最多保留一位小数。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "设置")
    alert.addButton(withTitle: "取消")

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximum = 10
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    formatter.allowsFloats = true

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    input.alignment = .right
    input.formatter = formatter
    input.doubleValue = recognitionWindowSeconds
    alert.accessoryView = input

    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    recognitionWindowSeconds = VoiceSessionRecognitionPolicy.normalizedWindowSeconds(
      input.doubleValue
    )
  }
}
