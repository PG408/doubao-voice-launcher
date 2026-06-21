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
  case syntheticHoldRelease
}

public enum InputSourceShortcutRetryAction: Equatable, Sendable {
  case restartSyntheticHoldFromCapturedTemplate
}

public final class InputSourceHandoffController {
  public private(set) var longPressThresholdMilliseconds: Int
  private let longPressRestoreDelayMilliseconds: Int
  private var state: State = .idle

  public init(
    longPressThresholdMilliseconds: Int = LongPressThresholdPreference.defaultMilliseconds,
    longPressRestoreDelayMilliseconds: Int = 180
  ) {
    self.longPressThresholdMilliseconds = LongPressThresholdPreference.clamped(longPressThresholdMilliseconds)
    self.longPressRestoreDelayMilliseconds = longPressRestoreDelayMilliseconds
  }

  public var stateDescription: String {
    state.description
  }

  public var releasePressKind: InputSourcePressKind? {
    switch state {
    case .longPressActive:
      return .long
    case .handoffKeyDown:
      return .short
    case .shortClickSyntheticHoldStopKeyDown:
      return .syntheticHoldRelease
    case .idle, .shortClickSyntheticHoldActive, .shortClickSyntheticHoldRetryActive:
      return nil
    }
  }

  public var isAwaitingLongPressThreshold: Bool {
    if case .handoffKeyDown = state {
      return true
    }
    return false
  }

  public func updateLongPressThresholdMilliseconds(_ milliseconds: Int) {
    longPressThresholdMilliseconds = LongPressThresholdPreference.clamped(milliseconds)
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
    case let .shortClickSyntheticHoldActive(originalInputSourceID),
         let .shortClickSyntheticHoldRetryActive(originalInputSourceID):
      state = .shortClickSyntheticHoldStopKeyDown(originalInputSourceID: originalInputSourceID)
      return []
    case .handoffKeyDown, .longPressActive, .shortClickSyntheticHoldStopKeyDown:
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
      state = .shortClickSyntheticHoldActive(originalInputSourceID: originalInputSourceID)
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
    case let .shortClickSyntheticHoldStopKeyDown(originalInputSourceID):
      state = .idle
      return [
        .scheduleRestoreInputSource(
          originalInputSourceID,
          delayMilliseconds: longPressRestoreDelayMilliseconds,
          reason: .secondShortClickRelease
        )
      ]
    case .idle, .shortClickSyntheticHoldActive, .shortClickSyntheticHoldRetryActive:
      return []
    }
  }

  public func retryShortClickActivationIfNeeded() -> InputSourceShortcutRetryAction? {
    guard case let .shortClickSyntheticHoldActive(originalInputSourceID) = state else {
      return nil
    }

    state = .shortClickSyntheticHoldRetryActive(originalInputSourceID: originalInputSourceID)
    return .restartSyntheticHoldFromCapturedTemplate
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
  case shortClickSyntheticHoldActive(originalInputSourceID: String)
  case shortClickSyntheticHoldRetryActive(originalInputSourceID: String)
  case shortClickSyntheticHoldStopKeyDown(originalInputSourceID: String)

  var originalInputSourceID: String? {
    switch self {
    case .idle:
      return nil
    case let .handoffKeyDown(originalInputSourceID),
         let .longPressActive(originalInputSourceID),
         let .shortClickSyntheticHoldActive(originalInputSourceID),
         let .shortClickSyntheticHoldRetryActive(originalInputSourceID),
         let .shortClickSyntheticHoldStopKeyDown(originalInputSourceID):
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
    case .shortClickSyntheticHoldActive:
      return "shortClickSyntheticHoldActive"
    case .shortClickSyntheticHoldRetryActive:
      return "shortClickSyntheticHoldRetryActive"
    case .shortClickSyntheticHoldStopKeyDown:
      return "shortClickSyntheticHoldStopKeyDown"
    }
  }
}
