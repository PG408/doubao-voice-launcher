public enum ShortcutKeyDownForwarding: Equatable, Sendable {
  case passThrough
  case `defer`(milliseconds: Int)
}

public enum ShortcutKeyUpForwarding: Equatable, Sendable {
  case passThrough
  case replayTap(keyDownDelayMilliseconds: Int, keyUpGapMilliseconds: Int)
}

public struct ShortcutEventForwardingPolicy: Equatable, Sendable {
  public let deferredKeyDownForwardingMilliseconds: Int
  public let shortTapReplayKeyDownDelayMilliseconds: Int
  public let shortTapReplayKeyUpGapMilliseconds: Int

  public init(
    deferredKeyDownForwardingMilliseconds: Int = 500,
    shortTapReplayKeyDownDelayMilliseconds: Int = 180,
    shortTapReplayKeyUpGapMilliseconds: Int = 80
  ) {
    self.deferredKeyDownForwardingMilliseconds = deferredKeyDownForwardingMilliseconds
    self.shortTapReplayKeyDownDelayMilliseconds = shortTapReplayKeyDownDelayMilliseconds
    self.shortTapReplayKeyUpGapMilliseconds = shortTapReplayKeyUpGapMilliseconds
  }

  public func keyDownForwarding(
    startedFromInputSourceHandoff: Bool
  ) -> ShortcutKeyDownForwarding {
    guard startedFromInputSourceHandoff else {
      return .passThrough
    }

    return .defer(milliseconds: deferredKeyDownForwardingMilliseconds)
  }

  public func keyUpForwarding(
    startedFromInputSourceHandoff: Bool,
    releasePressKind: InputSourcePressKind?,
    pressDurationMilliseconds: Int
  ) -> ShortcutKeyUpForwarding {
    guard startedFromInputSourceHandoff,
          releasePressKind == .short else {
      return .passThrough
    }

    return .replayTap(
      keyDownDelayMilliseconds: shortTapReplayKeyDownDelayMilliseconds,
      keyUpGapMilliseconds: shortTapReplayKeyUpGapMilliseconds
    )
  }
}
