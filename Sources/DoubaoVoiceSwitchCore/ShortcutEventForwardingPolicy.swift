public enum ShortcutKeyDownForwarding: Equatable, Sendable {
  case passThrough
  case captureForSyntheticForwarding
  case suppress
}

public enum ShortcutKeyUpForwarding: Equatable, Sendable {
  case passThrough
  case suppress
  case startSyntheticHold
  case releaseSyntheticHold
  case forwardSyntheticKeyUp
}

public struct ShortcutEventForwardingPolicy: Equatable, Sendable {
  public init() {}

  public func keyDownForwarding(
    startedFromInputSourceHandoff: Bool,
    releasePressKind: InputSourcePressKind?,
    isSuppressionWindowActive: Bool
  ) -> ShortcutKeyDownForwarding {
    if isSuppressionWindowActive {
      return .suppress
    }

    if releasePressKind == .syntheticHoldRelease {
      return .suppress
    }

    guard startedFromInputSourceHandoff else {
      return .passThrough
    }

    return .captureForSyntheticForwarding
  }

  public func keyUpForwarding(
    startedFromInputSourceHandoff: Bool,
    releasePressKind: InputSourcePressKind?,
    pressDurationMilliseconds: Int,
    isSuppressionWindowActive: Bool
  ) -> ShortcutKeyUpForwarding {
    if isSuppressionWindowActive, releasePressKind != .long {
      return .suppress
    }

    if releasePressKind == .syntheticHoldRelease {
      return .releaseSyntheticHold
    }

    guard startedFromInputSourceHandoff else {
      return .passThrough
    }

    switch releasePressKind {
    case .short:
      return .startSyntheticHold
    case .long:
      return .forwardSyntheticKeyUp
    case .syntheticHoldRelease:
      return .releaseSyntheticHold
    case nil:
      return .passThrough
    }
  }
}
