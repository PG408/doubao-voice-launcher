public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let control = ShortcutModifiers(rawValue: 1 << 0)
  public static let option = ShortcutModifiers(rawValue: 1 << 1)
  public static let shift = ShortcutModifiers(rawValue: 1 << 2)
  public static let command = ShortcutModifiers(rawValue: 1 << 3)
}

extension ShortcutModifiers {
  public var displayText: String {
    var text = ""
    if contains(.control) { text += "⌃" }
    if contains(.option) { text += "⌥" }
    if contains(.shift) { text += "⇧" }
    if contains(.command) { text += "⌘" }
    return text
  }
}
