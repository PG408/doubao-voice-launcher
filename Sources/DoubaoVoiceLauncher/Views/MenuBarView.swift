import SwiftUI

struct MenuBarView: View {
  @Environment(\.openSettings) private var openSettings
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: model.statusSystemImage)
          .foregroundStyle(model.status.tint)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.statusTitle)
            .font(.headline)
          Text(model.lastMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let failure = model.lastFailureMessage {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      if model.status == .preparing {
        Divider()
        Text("缺失前置条件")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(model.prerequisites.filter { !$0.isReady }) { item in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
              .foregroundStyle(.secondary)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title)
              Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
        Button("打开设置处理缺失项") { openAppSettings() }
      }

      Divider()

      if model.status == .paused {
        Button("继续") { model.resume() }
      } else {
        Button("暂停") { model.pause() }
      }

      Button("重新检测") { model.refreshReadiness() }

      Button("打开设置") { openAppSettings() }

      Button("打开日志文件夹") { model.openLogFolder() }
      Button("复制诊断摘要") { model.copyDiagnosticSummary() }

      Divider()

      Button("退出") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(10)
    .frame(width: 280, alignment: .leading)
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
