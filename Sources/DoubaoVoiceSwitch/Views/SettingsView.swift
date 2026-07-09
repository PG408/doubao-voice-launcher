import DoubaoVoiceSwitchCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  @AppStorage("doubaoShortcutKeys") private var doubaoShortcutKeys = DoubaoShortcut(keys: DoubaoShortcut.defaultKeys).storageValue
  @AppStorage("launchAtLogin") private var launchAtLogin = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      commandHeader
      readinessSummary
      settingsSurface
      logFooter
    }
    .padding(20)
    .frame(width: 440)
    .onChange(of: doubaoShortcutKeys) {
      model.updateGlobalShortcutRegistration()
    }
    .onChange(of: launchAtLogin) {
      model.setLaunchAtLogin(launchAtLogin)
    }
    .onAppear {
      launchAtLogin = model.isLaunchAtLoginEnabled()
    }
  }

  private var commandHeader: some View {
    HStack(alignment: .center, spacing: 14) {
      VoiceLauncherGlyph(size: 46, color: model.status.tint)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text("豆包语音切换器")
            .font(.title2.weight(.semibold))

          StatusChip(status: model.status)
        }

        Text(commandHeaderMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      if needsAccessibilityAuthorization {
        Button("授权") { model.openAccessibilitySettings() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
      } else {
        Button(model.status == .paused ? "继续" : "暂停") {
          if model.status == .paused {
            model.resume()
          } else {
            model.pause()
          }
        }
        .controlSize(.large)
      }
    }
  }

  private var readinessSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("状态")
        .font(.headline)

      HStack(spacing: 8) {
        ForEach(model.prerequisites) { item in
          ReadinessCard(item: item)
        }
      }
    }
  }

  private var settingsSurface: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("设置")
        .font(.headline)

      VStack(spacing: 0) {
        ControlRow(
          systemImage: "keyboard",
          title: "快捷键",
          detail: "与豆包输入法的语音快捷键保持一致"
        ) {
          DoubaoShortcutPickerView(storageValue: $doubaoShortcutKeys)
        }

        Divider()

        ControlRow(
          systemImage: "power",
          title: "开机自启动",
          detail: "登录 macOS 后自动在菜单栏运行"
        ) {
          Toggle("", isOn: $launchAtLogin)
            .labelsHidden()
        }
      }
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private var logFooter: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("日志")
          .font(.headline)
        Text("本地按天滚动，保留 7 天。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 8) {
        Button("打开") { model.openLogFolder() }
        Button("清空") { model.clearLogs() }
      }
    }
    .padding(13)
    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
  }

  private var needsAccessibilityAuthorization: Bool {
    model.prerequisites.contains { $0.id == "accessibility" && !$0.isReady }
  }

  private var commandHeaderMessage: String {
    if needsAccessibilityAuthorization {
      return "需要辅助功能权限后才能观察豆包语音快捷键"
    }
    if model.status == .paused {
      return "已暂停监听豆包语音快捷键"
    }
    return "监听豆包语音快捷键，语音结束后恢复原输入法。"
  }
}

private struct DoubaoShortcutPickerView: View {
  @Binding var storageValue: String
  @State private var isShowingPanel = false

  private var shortcut: DoubaoShortcut {
    DoubaoShortcut(storageValue: storageValue)
  }

  var body: some View {
    Button(shortcut.displayText) {
      isShowingPanel.toggle()
    }
    .popover(isPresented: $isShowingPanel, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text("豆包快捷键")
          .font(.headline)

        VStack(alignment: .leading, spacing: 6) {
          shortcutRow(left: .leftControl, right: .rightControl)
          shortcutRow(left: .leftOption, right: .rightOption)
          shortcutRow(left: .leftCommand, right: .rightCommand)
          ShortcutKeyButton(key: .function, isOn: binding(for: .function))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(width: 144, alignment: .leading)
    }
  }

  private func shortcutRow(left: DoubaoShortcutKey, right: DoubaoShortcutKey) -> some View {
    HStack(spacing: 6) {
      ShortcutKeyButton(key: left, isOn: binding(for: left))
      ShortcutKeyButton(key: right, isOn: binding(for: right))
    }
  }

  private func binding(for key: DoubaoShortcutKey) -> Binding<Bool> {
    Binding(
      get: {
        shortcut.keys.contains(key)
      },
      set: { isSelected in
        var keys = shortcut.keys
        if isSelected {
          keys.append(key)
        } else if keys.count > 1 {
          keys.removeAll { $0 == key }
        }
        storageValue = DoubaoShortcut(keys: keys).storageValue
      }
    )
  }
}

private struct ShortcutKeyButton: View {
  let key: DoubaoShortcutKey
  let isOn: Binding<Bool>

  var body: some View {
    Toggle(key.displayText, isOn: isOn)
      .toggleStyle(.button)
      .controlSize(.small)
      .font(.body.weight(.medium))
      .frame(width: 52, height: 28)
  }
}

private struct StatusChip: View {
  let status: AppStatus

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(status.tint)
        .frame(width: 6, height: 6)
      Text(status.title)
        .font(.caption.weight(.medium))
    }
    .foregroundStyle(status.tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background(status.tint.opacity(0.12), in: Capsule())
  }
}

private struct ReadinessCard: View {
  let item: PrerequisiteItem

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(item.isReady ? .green : .orange)
        .font(.system(size: 22))
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.subheadline.weight(.semibold))
        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct ControlRow<Control: View>: View {
  let systemImage: String
  let title: String
  let detail: String
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .center, spacing: 13) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .font(.system(size: 17, weight: .medium))
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 16)

      control
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 11)
  }
}
