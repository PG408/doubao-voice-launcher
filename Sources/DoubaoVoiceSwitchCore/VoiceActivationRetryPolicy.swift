public enum VoiceActivationProbeDecision: Equatable, Sendable {
  case confirmed
  case retry(
    retryNumber: Int,
    retryKeyDownDelayMilliseconds: Int,
    nextProbeDelayMilliseconds: Int
  )
  case failed
}

public struct VoiceActivationRetryPolicy: Equatable, Sendable {
  public let maxRetryCount: Int
  public let firstReplayDelayMilliseconds: Int
  public let probeDelayMilliseconds: Int
  public let retryKeyDownDelayMilliseconds: Int
  public let retryProbeDelayMilliseconds: Int

  public init(
    maxRetryCount: Int = 1,
    firstReplayDelayMilliseconds: Int = 80,
    probeDelayMilliseconds: Int = 300,
    retryKeyDownDelayMilliseconds: Int = 80,
    retryProbeDelayMilliseconds: Int = 600
  ) {
    self.maxRetryCount = max(0, maxRetryCount)
    self.firstReplayDelayMilliseconds = max(0, firstReplayDelayMilliseconds)
    self.probeDelayMilliseconds = max(0, probeDelayMilliseconds)
    self.retryKeyDownDelayMilliseconds = max(0, retryKeyDownDelayMilliseconds)
    self.retryProbeDelayMilliseconds = max(0, retryProbeDelayMilliseconds)
  }

  public func decision(
    isRunningInput: Bool,
    completedRetryCount: Int
  ) -> VoiceActivationProbeDecision {
    if isRunningInput {
      return .confirmed
    }

    guard completedRetryCount < maxRetryCount else {
      return .failed
    }

    return .retry(
      retryNumber: completedRetryCount + 1,
      retryKeyDownDelayMilliseconds: retryKeyDownDelayMilliseconds,
      nextProbeDelayMilliseconds: retryProbeDelayMilliseconds
    )
  }
}
