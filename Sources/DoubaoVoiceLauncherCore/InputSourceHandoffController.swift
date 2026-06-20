public enum InputSourceHandoffAction: Equatable, Sendable {
  case selectDoubaoInputSource
  case scheduleRestoreInputSource(String, delayMilliseconds: Int, reason: InputSourceRestoreReason)
}

public enum InputSourceRestoreReason: String, Equatable, Sendable {
  case longPressRelease
  case secondShortClickRelease
  case cancelHandoff
}

public enum InputSourcePressKind: String, Equatable, Sendable {
  case short
  case long
}

public final class InputSourceHandoffController {
  public let longPressThresholdMilliseconds: Int
  private let longPressRestoreDelayMilliseconds: Int
  private var state: State = .idle

  public init(
    longPressThresholdMilliseconds: Int = 500,
    longPressRestoreDelayMilliseconds: Int = 180
  ) {
    self.longPressThresholdMilliseconds = longPressThresholdMilliseconds
    self.longPressRestoreDelayMilliseconds = longPressRestoreDelayMilliseconds
  }

  public var stateDescription: String {
    state.description
  }

  public var releasePressKind: InputSourcePressKind? {
    switch state {
    case .longPressActive:
      return .long
    case .handoffKeyDown, .shortClickStopKeyDown:
      return .short
    case .idle, .shortClickVoiceActive:
      return nil
    }
  }

  public var isAwaitingLongPressThreshold: Bool {
    if case .handoffKeyDown = state {
      return true
    }
    return false
  }

  public func shortcutBecameActive(
    currentInputSource: InputSourceIdentity,
    fallbackOriginalInputSourceID: String? = nil
  ) -> [InputSourceHandoffAction] {
    switch state {
    case .idle:
      guard let restorationID = currentInputSource.restorationID ?? fallbackOriginalInputSourceID,
            !restorationID.isEmpty else {
        return []
      }

      state = .handoffKeyDown(originalInputSourceID: restorationID)
      return currentInputSource.restorationID == nil ? [] : [.selectDoubaoInputSource]
    case let .shortClickVoiceActive(originalInputSourceID):
      state = .shortClickStopKeyDown(originalInputSourceID: originalInputSourceID)
      return []
    case .handoffKeyDown, .longPressActive, .shortClickStopKeyDown:
      return []
    }
  }

  public func shortcutLongPressThresholdReached() -> Bool {
    guard case let .handoffKeyDown(originalInputSourceID) = state else {
      return false
    }

    state = .longPressActive(originalInputSourceID: originalInputSourceID)
    return true
  }

  public func shortcutBecameInactive() -> [InputSourceHandoffAction] {
    switch state {
    case let .handoffKeyDown(originalInputSourceID):
      state = .shortClickVoiceActive(originalInputSourceID: originalInputSourceID)
      return []
    case let .longPressActive(originalInputSourceID):
      state = .idle
      return [
        .scheduleRestoreInputSource(
          originalInputSourceID,
          delayMilliseconds: longPressRestoreDelayMilliseconds,
          reason: .longPressRelease
        )
      ]
    case let .shortClickStopKeyDown(originalInputSourceID):
      state = .idle
      return [
        .scheduleRestoreInputSource(
          originalInputSourceID,
          delayMilliseconds: longPressRestoreDelayMilliseconds,
          reason: .secondShortClickRelease
        )
      ]
    case .idle, .shortClickVoiceActive:
      return []
    }
  }

  public func cancelHandoff() -> [InputSourceHandoffAction] {
    guard let originalInputSourceID = state.originalInputSourceID else {
      return []
    }

    state = .idle
    return [
      .scheduleRestoreInputSource(
        originalInputSourceID,
        delayMilliseconds: longPressRestoreDelayMilliseconds,
        reason: .cancelHandoff
      )
    ]
  }
}

private enum State {
  case idle
  case handoffKeyDown(originalInputSourceID: String)
  case longPressActive(originalInputSourceID: String)
  case shortClickVoiceActive(originalInputSourceID: String)
  case shortClickStopKeyDown(originalInputSourceID: String)

  var originalInputSourceID: String? {
    switch self {
    case .idle:
      return nil
    case let .handoffKeyDown(originalInputSourceID),
         let .longPressActive(originalInputSourceID),
         let .shortClickVoiceActive(originalInputSourceID),
         let .shortClickStopKeyDown(originalInputSourceID):
      return originalInputSourceID
    }
  }

  var description: String {
    switch self {
    case .idle:
      return "idle"
    case .handoffKeyDown:
      return "handoffKeyDown"
    case .longPressActive:
      return "longPressActive"
    case .shortClickVoiceActive:
      return "shortClickVoiceActive"
    case .shortClickStopKeyDown:
      return "shortClickStopKeyDown"
    }
  }
}
