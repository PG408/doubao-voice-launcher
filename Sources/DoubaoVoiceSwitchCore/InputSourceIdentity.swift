public enum InputSourceIdentity: Equatable, Sendable, CustomStringConvertible {
  case doubao
  case other(String)

  public var restorationID: String? {
    switch self {
    case .doubao:
      return nil
    case let .other(id):
      return id
    }
  }

  public var description: String {
    switch self {
    case .doubao:
      return "doubao"
    case let .other(id):
      return "other(\(id))"
    }
  }
}
