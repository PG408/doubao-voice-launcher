import Foundation

public enum DiagnosticLogCategory: String, Equatable {
  case app
  case shortcut
  case inputSource
  case voiceReadiness
  case restoration
}

public struct DiagnosticLogEntry: Equatable {
  public let timestamp: Date
  public let category: DiagnosticLogCategory
  public let message: String

  public init(timestamp: Date, category: DiagnosticLogCategory, message: String) {
    self.timestamp = timestamp
    self.category = category
    self.message = message
  }
}

public struct DiagnosticLogger {
  public let logDirectory: URL
  public let retentionDays: Int

  private let fileManager: FileManager
  private let calendar: Calendar

  public init(logDirectory: URL, retentionDays: Int, fileManager: FileManager = .default) {
    self.logDirectory = logDirectory
    self.retentionDays = retentionDays
    self.fileManager = fileManager

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    self.calendar = calendar
  }

  public func record(_ entry: DiagnosticLogEntry) throws {
    try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

    let line = "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.category.rawValue)] \(entry.message)\n"
    let data = Data(line.utf8)
    let fileURL = logDirectory.appendingPathComponent("\(dayString(for: entry.timestamp)).log")

    if fileManager.fileExists(atPath: fileURL.path) {
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: fileURL, options: .atomic)
    }
  }

  public func pruneLogs(now: Date = Date()) throws {
    guard fileManager.fileExists(atPath: logDirectory.path) else {
      return
    }

    let cutoff = calendar.date(
      byAdding: .day,
      value: -retentionDays,
      to: calendar.startOfDay(for: now)
    ) ?? now

    let files = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
    for file in files where file.pathExtension == "log" {
      let day = file.deletingPathExtension().lastPathComponent
      guard let date = Self.dayFormatter.date(from: day), date < cutoff else {
        continue
      }
      try fileManager.removeItem(at: file)
    }
  }

  private func dayString(for date: Date) -> String {
    Self.dayFormatter.string(from: calendar.startOfDay(for: date))
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}
