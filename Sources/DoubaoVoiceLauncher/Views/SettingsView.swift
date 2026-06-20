import DoubaoVoiceLauncherCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  @AppStorage("doubaoShortcutKeys") private var doubaoShortcutKeys = DoubaoShortcut(keys: DoubaoShortcut.defaultKeys).storageValue
  @AppStorage(LongPressThresholdPreference.storageKey) private var longPressThresholdMilliseconds = LongPressThresholdPreference.defaultMilliseconds
  @AppStorage("launchAtLogin") private var launchAtLogin = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      commandHeader
      readinessSummary
      settingsSurface
      logFooter
    }
    .padding(22)
    .frame(width: 540)
    .onChange(of: doubaoShortcutKeys) {
      model.updateGlobalShortcutRegistration()
    }
    .onChange(of: longPressThresholdMilliseconds) {
      normalizeLongPressThreshold()
    }
    .onChange(of: launchAtLogin) {
      model.setLaunchAtLogin(launchAtLogin)
    }
    .onAppear {
      launchAtLogin = model.isLaunchAtLoginEnabled()
      normalizeLongPressThreshold()
    }
  }

  private var commandHeader: some View {
    HStack(alignment: .center, spacing: 14) {
      VoiceLauncherGlyph(size: 46, color: .secondary)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text("豆包语音启动器")
            .font(.title2.weight(.semibold))

          StatusChip(status: model.status)
        }

        Text(commandHeaderMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
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

      HStack(spacing: 10) {
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
          detail: "与豆包输入法保持一致"
        ) {
          DoubaoShortcutPickerView(storageValue: $doubaoShortcutKeys)
        }

        Divider()

        ControlRow(
          systemImage: "timer",
          title: "长按判定",
          detail: "时间越短响应越快；时间越长越不容易误判"
        ) {
          Stepper(
            value: $longPressThresholdMilliseconds,
            in: LongPressThresholdPreference.minimumMilliseconds...LongPressThresholdPreference.maximumMilliseconds,
            step: 10
          ) {
            Text("\(longPressThresholdMilliseconds) ms")
              .monospacedDigit()
              .frame(width: 64, alignment: .trailing)
          }
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
    .padding(14)
    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
  }

  private var needsAccessibilityAuthorization: Bool {
    model.prerequisites.contains { $0.id == "accessibility" && !$0.isReady }
  }

  private var commandHeaderMessage: String {
    if needsAccessibilityAuthorization {
      return "需要辅助功能权限后才能转发快捷键"
    }
    if model.status == .paused {
      return "已暂停响应豆包语音快捷键"
    }
    return "长按或点按快捷键即可使用豆包语音输入"
  }

  private func normalizeLongPressThreshold() {
    let clampedMilliseconds = LongPressThresholdPreference.clamped(longPressThresholdMilliseconds)
    if clampedMilliseconds != longPressThresholdMilliseconds {
      longPressThresholdMilliseconds = clampedMilliseconds
    }
    model.updateLongPressThresholdMilliseconds(clampedMilliseconds)
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
      VStack(alignment: .leading, spacing: 12) {
        Text("豆包快捷键")
          .font(.headline)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
          ForEach(DoubaoShortcutKey.allCases, id: \.self) { key in
            Toggle(key.displayText, isOn: binding(for: key))
              .toggleStyle(.button)
          }
        }

        Text("仅支持左右 Command、左右 Option、左右 Control 和 Fn。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(width: 330)
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
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
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
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }
}
