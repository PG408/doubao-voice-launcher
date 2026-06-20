public enum DoubaoShortcutKey: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case leftControl
  case rightControl
  case leftOption
  case rightOption
  case leftCommand
  case rightCommand
  case function

  public var displayText: String {
    switch self {
    case .leftControl:
      return "L⌃"
    case .rightControl:
      return "R⌃"
    case .leftOption:
      return "L⌥"
    case .rightOption:
      return "R⌥"
    case .leftCommand:
      return "L⌘"
    case .rightCommand:
      return "R⌘"
    case .function:
      return "Fn"
    }
  }

  public var keyCode: UInt16 {
    switch self {
    case .leftControl:
      return 59
    case .rightControl:
      return 62
    case .leftOption:
      return 58
    case .rightOption:
      return 61
    case .leftCommand:
      return 55
    case .rightCommand:
      return 54
    case .function:
      return 63
    }
  }

  public var modifier: ShortcutModifiers? {
    switch self {
    case .leftControl, .rightControl:
      return .control
    case .leftOption, .rightOption:
      return .option
    case .leftCommand, .rightCommand:
      return .command
    case .function:
      return nil
    }
  }

  public static func key(forKeyCode keyCode: UInt16) -> DoubaoShortcutKey? {
    switch keyCode {
    case 59:
      return .leftControl
    case 62:
      return .rightControl
    case 58:
      return .leftOption
    case 61:
      return .rightOption
    case 55:
      return .leftCommand
    case 54:
      return .rightCommand
    case 63:
      return .function
    default:
      return nil
    }
  }
}

public struct DoubaoShortcut: Codable, Equatable, Sendable {
  public static let defaultKeys: [DoubaoShortcutKey] = [.rightCommand]

  public let keys: [DoubaoShortcutKey]

  public init(keys: [DoubaoShortcutKey]) {
    let selectedKeys = Self.orderedUniqueKeys(keys)
    self.keys = selectedKeys.isEmpty ? Self.defaultKeys : selectedKeys
  }

  public init(storageValue: String?) {
    let keys = storageValue?
      .split(separator: ",")
      .compactMap { DoubaoShortcutKey(rawValue: String($0)) } ?? []
    self.init(keys: keys)
  }

  public var storageValue: String {
    keys.map(\.rawValue).joined(separator: ",")
  }

  public var displayText: String {
    keys.map(\.displayText).joined(separator: " + ")
  }

  public func matches(activeKeys: Set<DoubaoShortcutKey>) -> Bool {
    Set(keys) == activeKeys
  }

  private static func orderedUniqueKeys(_ keys: [DoubaoShortcutKey]) -> [DoubaoShortcutKey] {
    DoubaoShortcutKey.allCases.filter { keys.contains($0) }
  }
}
