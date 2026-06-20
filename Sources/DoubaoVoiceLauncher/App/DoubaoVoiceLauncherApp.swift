import AppKit
import SwiftUI

@main
struct DoubaoVoiceLauncherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      Image(nsImage: VoiceLauncherGlyphImage.make(size: 22, color: model.status.nsColor))
        .accessibilityLabel("豆包语音启动器，\(model.statusTitle)")
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
  }
}
