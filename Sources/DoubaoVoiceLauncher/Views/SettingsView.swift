import DoubaoVoiceLauncherCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  @AppStorage("doubaoShortcutKeys") private var doubaoShortcutKeys = DoubaoShortcut(keys: DoubaoShortcut.defaultKeys).storageValue
  @AppStorage(LongPressThresholdPreference.storageKey) private var longPressThresholdMilliseconds = LongPressThresholdPreference.defaultMilliseconds
  @AppStorage("launchAtLogin") private var launchAtLogin = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      statusSection
      shortcutSection
      launchSection
      diagnosticSection
      logSection
    }
    .padding(22)
    .frame(width: 580)
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

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: model.statusSystemImage)
        .font(.system(size: 24))
        .foregroundStyle(model.status.tint)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 2) {
        Text("豆包语音启动器")
          .font(.title3.weight(.semibold))
        Text(model.statusTitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if model.status == .paused {
        Button("继续") { model.resume() }
      } else {
        Button("暂停") { model.pause() }
      }
    }
  }

  private var statusSection: some View {
    SettingsSection(title: "状态") {
      VStack(spacing: 10) {
        ForEach(model.prerequisites) { item in
          HStack(spacing: 10) {
            Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
              .foregroundStyle(item.isReady ? .green : .secondary)
              .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
              Text(item.title)
              Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if item.id == "accessibility", !item.isReady {
              Button("手动授权") { model.openAccessibilitySettings() }
            }
          }
        }
      }
    }
  }

  private var shortcutSection: some View {
    SettingsSection(title: "快捷键") {
      VStack(alignment: .leading, spacing: 10) {
        Text("请将本软件快捷键设置为与豆包输入法的语音快捷键一致。本软件只负责切换输入法；点按、长按和语音结束由豆包输入法处理。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Text("语音输入快捷键")
          Spacer()
          DoubaoShortcutPickerView(storageValue: $doubaoShortcutKeys)
        }

        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("长按判定时间")
            Text("时间越短，长按响应越快；时间越长，越不容易把慢速单击识别成长按。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

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
      }
    }
  }

  private func normalizeLongPressThreshold() {
    let clampedMilliseconds = LongPressThresholdPreference.clamped(longPressThresholdMilliseconds)
    if clampedMilliseconds != longPressThresholdMilliseconds {
      longPressThresholdMilliseconds = clampedMilliseconds
    }
    model.updateLongPressThresholdMilliseconds(clampedMilliseconds)
  }

  private var launchSection: some View {
    SettingsSection(title: "启动") {
      Toggle("开机自启动", isOn: $launchAtLogin)
    }
  }

  private var diagnosticSection: some View {
    SettingsSection(title: "诊断") {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.diagnosticSummary)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Spacer()
          Button("复制摘要") { model.copyDiagnosticSummary() }
          Button("重新检测") { model.refreshReadiness() }
        }
      }
    }
  }

  private var logSection: some View {
    SettingsSection(title: "日志") {
      HStack {
        Text("本地日志按天滚动，保留 7 天。")
          .foregroundStyle(.secondary)
        Spacer()
        Button("打开文件夹") { model.openLogFolder() }
        Button("清空") { model.clearLogs() }
      }
    }
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

private struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .padding(13)
      .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
