import DoubaoVoiceLauncherCore
import SwiftUI

extension AppStatus {
  var title: String {
    switch self {
    case .running: return "运行中"
    case .paused: return "暂停中"
    case .preparing: return "准备中"
    }
  }

  var systemImage: String {
    switch self {
    case .running: return "mic.circle"
    case .paused: return "pause.circle"
    case .preparing: return "exclamationmark.circle"
    }
  }

  var tint: Color {
    switch self {
    case .running: return .green
    case .paused: return .orange
    case .preparing: return .secondary
    }
  }
}
