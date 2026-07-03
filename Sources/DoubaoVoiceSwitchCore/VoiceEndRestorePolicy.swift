public enum VoiceEndRestoreReason: String, Equatable, Sendable {
  case detectedInputStopped
  case deadlineReached
}

public enum VoiceEndRestoreDecision: Equatable, Sendable {
  case continueProbing(nextProbeElapsedMilliseconds: Int)
  case restore(reason: VoiceEndRestoreReason)
}

public struct VoiceEndRestorePolicy: Equatable, Sendable {
  public let minimumDelayMilliseconds: Int
  public let maximumDelayMilliseconds: Int
  public let probeElapsedMilliseconds: [Int]

  public init(
    minimumDelayMilliseconds: Int = 180,
    maximumDelayMilliseconds: Int = 1_000,
    probeElapsedMilliseconds: [Int] = [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1_000]
  ) {
    self.minimumDelayMilliseconds = max(0, minimumDelayMilliseconds)
    self.maximumDelayMilliseconds = max(self.minimumDelayMilliseconds, maximumDelayMilliseconds)
    self.probeElapsedMilliseconds = Self.normalizedProbeElapsedMilliseconds(
      probeElapsedMilliseconds,
      maximumDelayMilliseconds: self.maximumDelayMilliseconds
    )
  }

  public func decision(
    elapsedMilliseconds: Int,
    isRunningInput: Bool
  ) -> VoiceEndRestoreDecision {
    let elapsedMilliseconds = max(0, elapsedMilliseconds)
    if elapsedMilliseconds >= maximumDelayMilliseconds {
      return .restore(reason: .deadlineReached)
    }

    if elapsedMilliseconds >= minimumDelayMilliseconds && !isRunningInput {
      return .restore(reason: .detectedInputStopped)
    }

    return .continueProbing(
      nextProbeElapsedMilliseconds: nextProbeElapsedMilliseconds(after: elapsedMilliseconds)
    )
  }

  private func nextProbeElapsedMilliseconds(after elapsedMilliseconds: Int) -> Int {
    probeElapsedMilliseconds.first { $0 > elapsedMilliseconds } ?? maximumDelayMilliseconds
  }

  private static func normalizedProbeElapsedMilliseconds(
    _ probeElapsedMilliseconds: [Int],
    maximumDelayMilliseconds: Int
  ) -> [Int] {
    let normalized = Set(probeElapsedMilliseconds.map { max(0, min($0, maximumDelayMilliseconds)) })
      .union([0, maximumDelayMilliseconds])
      .sorted()
    return normalized
  }
}
