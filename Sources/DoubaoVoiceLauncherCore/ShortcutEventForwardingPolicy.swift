public enum ShortcutKeyDownForwarding: Equatable, Sendable {
  case passThrough
  case captureForSyntheticForwarding
}

public enum ShortcutKeyUpForwarding: Equatable, Sendable {
  case passThrough
  case replayTap(preflightKeyUpDelayMilliseconds: Int, keyUpGapMilliseconds: Int)
  case forwardSyntheticKeyUp
}

public struct ShortcutEventForwardingPolicy: Equatable, Sendable {
  public let shortTapPreflightKeyUpDelayMilliseconds: Int
  public let shortTapReplayKeyUpGapMilliseconds: Int

  public init(
    shortTapPreflightKeyUpDelayMilliseconds: Int = 50,
    shortTapReplayKeyUpGapMilliseconds: Int = 80
  ) {
    self.shortTapPreflightKeyUpDelayMilliseconds = shortTapPreflightKeyUpDelayMilliseconds
    self.shortTapReplayKeyUpGapMilliseconds = shortTapReplayKeyUpGapMilliseconds
  }

  public func keyDownForwarding(
    startedFromInputSourceHandoff: Bool
  ) -> ShortcutKeyDownForwarding {
    guard startedFromInputSourceHandoff else {
      return .passThrough
    }

    return .captureForSyntheticForwarding
  }

  public func keyUpForwarding(
    startedFromInputSourceHandoff: Bool,
    releasePressKind: InputSourcePressKind?,
    pressDurationMilliseconds: Int
  ) -> ShortcutKeyUpForwarding {
    guard startedFromInputSourceHandoff else {
      return .passThrough
    }

    switch releasePressKind {
    case .short:
      return .replayTap(
        preflightKeyUpDelayMilliseconds: shortTapPreflightKeyUpDelayMilliseconds,
        keyUpGapMilliseconds: shortTapReplayKeyUpGapMilliseconds
      )
    case .long:
      return .forwardSyntheticKeyUp
    case nil:
      return .passThrough
    }
  }
}
