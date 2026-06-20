import SwiftUI

@main
struct DoubaoVoiceLauncherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    MenuBarExtra(model.statusTitle, systemImage: model.statusSystemImage) {
      MenuBarView(model: model)
    }

    Settings {
      SettingsView(model: model)
    }
  }
}
