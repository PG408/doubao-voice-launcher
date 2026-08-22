public enum AppStatus: Equatable {
  case running
  case paused
  case preparing
}

public struct AppReadinessState: Equatable {
  private var doubaoInputSourceAvailable: Bool
  private var userPaused: Bool

  public init(
    doubaoInputSourceAvailable: Bool = false,
    userPaused: Bool = false
  ) {
    self.doubaoInputSourceAvailable = doubaoInputSourceAvailable
    self.userPaused = userPaused
  }

  public var status: AppStatus {
    guard doubaoInputSourceAvailable else {
      return .preparing
    }
    return userPaused ? .paused : .running
  }

  public mutating func setDoubaoInputSourceAvailable(_ isAvailable: Bool) {
    doubaoInputSourceAvailable = isAvailable
  }

  public mutating func pause() {
    userPaused = true
  }

  public mutating func resume() {
    userPaused = false
  }
}
