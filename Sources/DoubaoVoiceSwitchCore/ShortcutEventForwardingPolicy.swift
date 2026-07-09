public enum ShortcutKeyDownForwarding: Equatable, Sendable {
  case passThrough
}

public enum ShortcutKeyUpForwarding: Equatable, Sendable {
  case passThrough
}

public struct ShortcutEventForwardingPolicy: Equatable, Sendable {
  public init() {}

  public func keyDownForwarding() -> ShortcutKeyDownForwarding {
    .passThrough
  }

  public func keyUpForwarding() -> ShortcutKeyUpForwarding {
    .passThrough
  }
}
