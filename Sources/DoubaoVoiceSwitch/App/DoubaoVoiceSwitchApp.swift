import AppKit
import DoubaoVoiceSwitchCore
import SwiftUI

@main
struct DoubaoVoiceSwitchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      MenuBarStatusIcon(status: model.status)
        .accessibilityLabel("豆包语音切换器，\(model.statusTitle)")
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MenuBarStatusIcon: View {
  let status: AppStatus

  var body: some View {
    switch status {
    case .running:
      Image(nsImage: VoiceLauncherGlyphImage.make(size: 18, color: .labelColor))
    case .paused:
      Image(systemName: "pause.circle")
    case .preparing:
      Image(systemName: "exclamationmark.triangle")
    }
  }
}
