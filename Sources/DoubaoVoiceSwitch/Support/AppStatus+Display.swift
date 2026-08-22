import DoubaoVoiceSwitchCore

extension AppStatus {
  var title: String {
    switch self {
    case .running: return "运行中"
    case .paused: return "暂停中"
    case .preparing: return "准备中"
    }
  }
}
