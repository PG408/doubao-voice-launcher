import DoubaoVoiceSwitchCore
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openSettings) private var openSettings
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .center, spacing: 10) {
        VoiceLauncherGlyph(size: 34, color: model.status.tint)
          .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text("豆包语音启动器")
              .font(.headline)
              .lineLimit(1)
            StatusDot(status: model.status)
          }

          Text(menuSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let failure = model.lastFailureMessage {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      Divider()
        .padding(.top, 1)

      if !missingPrerequisites.isEmpty {
        VStack(spacing: 8) {
          ForEach(missingPrerequisites) { item in
            MenuReadinessRow(item: item) {
              if item.id == "accessibility" {
                Button("授权") { model.openAccessibilitySettings() }
                  .controlSize(.small)
              }
            }
          }
        }

        Divider()
      }

      MenuActionButton(
        systemImage: model.status == .paused ? "play.circle" : "pause.circle",
        title: model.status == .paused ? "继续" : "暂停"
      ) {
        if model.status == .paused {
          model.resume()
        } else {
          model.pause()
        }
      }

      MenuActionButton(systemImage: "gearshape", title: "设置") {
        openAppSettings()
      }

      Divider()

      MenuActionButton(systemImage: "power", title: "退出") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(10)
    .frame(width: 240, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .id(menuLayoutID)
  }

  private var menuSubtitle: String {
    switch model.status {
    case .preparing:
      return "仍有前置条件未完成"
    case .paused:
      return "已暂停响应快捷键"
    case .running:
      return "监听快捷键中"
    }
  }

  private var missingPrerequisites: [PrerequisiteItem] {
    model.prerequisites.filter { !$0.isReady }
  }

  private var menuLayoutID: String {
    "\(model.statusTitle)-\(missingPrerequisites.map(\.id).joined(separator: ","))-\(model.lastFailureMessage ?? "")"
  }

  private func openAppSettings() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openSettings()
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
      NSApplication.shared.activate(ignoringOtherApps: true)
      NSApplication.shared.windows
        .filter(\.isVisible)
        .forEach { window in
          window.makeKeyAndOrderFront(nil)
          window.orderFrontRegardless()
        }
    }
  }
}

private struct StatusDot: View {
  let status: AppStatus

  var body: some View {
    Text(status.title)
      .font(.caption.weight(.medium))
    .foregroundStyle(status.tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(status.tint.opacity(0.12), in: Capsule())
  }
}

private struct MenuReadinessRow<Action: View>: View {
  let item: PrerequisiteItem
  @ViewBuilder let action: Action

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(item.isReady ? .green : .orange)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.subheadline.weight(.medium))
        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 10)

      action
    }
  }
}

private struct MenuActionButton: View {
  let systemImage: String
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(title)
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
