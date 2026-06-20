public enum LongPressThresholdPreference {
  public static let storageKey = "longPressThresholdMilliseconds"
  public static let minimumMilliseconds = 50
  public static let maximumMilliseconds = 500
  public static let defaultMilliseconds = 100

  public static func clamped(_ milliseconds: Int) -> Int {
    min(max(milliseconds, minimumMilliseconds), maximumMilliseconds)
  }
}
