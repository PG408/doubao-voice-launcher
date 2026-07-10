public struct VoiceInputRestoreConfiguration: Equatable, Sendable {
  public let doubaoInputSourceTimeoutMilliseconds: Int
  public let runningInputStartTimeoutMilliseconds: Int
  public let restoreStabilityDelayMilliseconds: Int
  public let restoreMaximumDelayMilliseconds: Int

  public init(
    doubaoInputSourceTimeoutMilliseconds: Int = 1_000,
    runningInputStartTimeoutMilliseconds: Int = 1_500,
    restoreStabilityDelayMilliseconds: Int = 500,
    restoreMaximumDelayMilliseconds: Int = 1_000
  ) {
    self.doubaoInputSourceTimeoutMilliseconds = max(0, doubaoInputSourceTimeoutMilliseconds)
    self.runningInputStartTimeoutMilliseconds = max(0, runningInputStartTimeoutMilliseconds)
    self.restoreStabilityDelayMilliseconds = max(0, restoreStabilityDelayMilliseconds)
    self.restoreMaximumDelayMilliseconds = max(
      self.restoreStabilityDelayMilliseconds,
      restoreMaximumDelayMilliseconds
    )
  }
}

public enum VoiceInputRestoreTimeoutReason: Equatable, Sendable {
  case doubaoInputSource
  case runningInputStart
}

public enum VoiceInputRestoreSkippedReason: Equatable, Sendable {
  case shortcutStartedFromDoubao
  case originalInputSourceUnavailable
  case currentInputSourceChangedBeforeRestore
  case doubaoInputSourceTimedOut
  case runningInputStartTimedOut
}

public enum VoiceInputRestoreAction: Equatable, Sendable {
  case scheduleInputSourceChangeTimeout(delayMilliseconds: Int)
  case scheduleRunningInputStartTimeout(delayMilliseconds: Int)
  case scheduleRestore(
    originalInputSourceID: String,
    delayMilliseconds: Int,
    maximumDelayMilliseconds: Int
  )
  case cancelRunningInputStartTimeout
  case restoreInputSource(originalInputSourceID: String)
  case skipRestore(reason: VoiceInputRestoreSkippedReason)
}

public final class VoiceInputRestoreController {
  public let configuration: VoiceInputRestoreConfiguration
  private var state: State = .idle

  public init(configuration: VoiceInputRestoreConfiguration = VoiceInputRestoreConfiguration()) {
    self.configuration = configuration
  }

  public var stateDescription: String {
    state.description
  }

  public var isIdle: Bool {
    if case .idle = state {
      return true
    }
    return false
  }

  public var shouldObserveRunningInput: Bool {
    switch state {
    case .waitingForRunningInput, .voiceActive, .restoring:
      return true
    case .idle, .waitingForDoubao:
      return false
    }
  }

  public var originalInputSourceID: String? {
    state.originalInputSourceID
  }

  public func reset() {
    state = .idle
  }

  public func shortcutObserved(
    currentInputSource: InputSourceIdentity,
    elapsedMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    guard case .idle = state else {
      return []
    }

    guard currentInputSource != .doubao else {
      return [.skipRestore(reason: .shortcutStartedFromDoubao)]
    }

    guard let originalInputSourceID = currentInputSource.restorationID,
          !originalInputSourceID.isEmpty else {
      return [.skipRestore(reason: .originalInputSourceUnavailable)]
    }

    state = .waitingForDoubao(
      originalInputSourceID: originalInputSourceID,
      observedElapsedMilliseconds: max(0, elapsedMilliseconds)
    )
    return [
      .scheduleInputSourceChangeTimeout(
        delayMilliseconds: configuration.doubaoInputSourceTimeoutMilliseconds
      )
    ]
  }

  public func currentInputSourceChanged(
    to currentInputSource: InputSourceIdentity,
    elapsedMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    switch state {
    case .idle:
      return []
    case let .waitingForDoubao(originalInputSourceID, observedElapsedMilliseconds):
      guard currentInputSource == .doubao else {
        return []
      }
      state = .waitingForRunningInput(
        originalInputSourceID: originalInputSourceID,
        observedElapsedMilliseconds: observedElapsedMilliseconds,
        doubaoSelectedElapsedMilliseconds: max(0, elapsedMilliseconds)
      )
      return [
        .scheduleRunningInputStartTimeout(
          delayMilliseconds: configuration.runningInputStartTimeoutMilliseconds
        )
      ]
    case .waitingForRunningInput:
      return []
    case .voiceActive, .restoring:
      guard currentInputSource != .doubao else {
        return []
      }
      state = .idle
      return [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)]
    }
  }

  public func runningInputChanged(
    isRunningInput: Bool,
    currentInputSource: InputSourceIdentity,
    elapsedMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    switch state {
    case let .waitingForRunningInput(
      originalInputSourceID,
      observedElapsedMilliseconds,
      doubaoSelectedElapsedMilliseconds
    ):
      guard currentInputSource == .doubao else {
        return []
      }
      guard isRunningInput else {
        return []
      }
      state = .voiceActive(
        originalInputSourceID: originalInputSourceID,
        observedElapsedMilliseconds: observedElapsedMilliseconds,
        doubaoSelectedElapsedMilliseconds: doubaoSelectedElapsedMilliseconds,
        runningInputStartedElapsedMilliseconds: max(0, elapsedMilliseconds)
      )
      return [.cancelRunningInputStartTimeout]
    case let .voiceActive(
      originalInputSourceID,
      observedElapsedMilliseconds,
      doubaoSelectedElapsedMilliseconds,
      runningInputStartedElapsedMilliseconds
    ):
      guard currentInputSource == .doubao else {
        state = .idle
        return [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)]
      }
      guard !isRunningInput else {
        return []
      }
      state = .restoring(
        originalInputSourceID: originalInputSourceID,
        observedElapsedMilliseconds: observedElapsedMilliseconds,
        doubaoSelectedElapsedMilliseconds: doubaoSelectedElapsedMilliseconds,
        runningInputStartedElapsedMilliseconds: runningInputStartedElapsedMilliseconds,
        runningInputStoppedElapsedMilliseconds: max(0, elapsedMilliseconds)
      )
      return [
        .scheduleRestore(
          originalInputSourceID: originalInputSourceID,
          delayMilliseconds: configuration.restoreStabilityDelayMilliseconds,
          maximumDelayMilliseconds: configuration.restoreMaximumDelayMilliseconds
        )
      ]
    case let .restoring(
      originalInputSourceID,
      observedElapsedMilliseconds,
      doubaoSelectedElapsedMilliseconds,
      runningInputStartedElapsedMilliseconds,
      _
    ):
      guard currentInputSource == .doubao else {
        state = .idle
        return [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)]
      }
      guard isRunningInput else {
        return []
      }
      state = .voiceActive(
        originalInputSourceID: originalInputSourceID,
        observedElapsedMilliseconds: observedElapsedMilliseconds,
        doubaoSelectedElapsedMilliseconds: doubaoSelectedElapsedMilliseconds,
        runningInputStartedElapsedMilliseconds: runningInputStartedElapsedMilliseconds
      )
      return []
    case .idle, .waitingForDoubao:
      return []
    }
  }

  public func timeoutElapsed(
    reason: VoiceInputRestoreTimeoutReason,
    elapsedMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    switch (state, reason) {
    case (.waitingForDoubao, .doubaoInputSource):
      state = .idle
      return [.skipRestore(reason: .doubaoInputSourceTimedOut)]
    case (.waitingForRunningInput, .runningInputStart):
      state = .idle
      return [.skipRestore(reason: .runningInputStartTimedOut)]
    default:
      return []
    }
  }

  public func restoreWindowElapsed(
    currentInputSource: InputSourceIdentity,
    isOriginalInputSourceAvailable: Bool,
    elapsedMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    guard case let .restoring(
      originalInputSourceID,
      _,
      _,
      _,
      runningInputStoppedElapsedMilliseconds
    ) = state else {
      return []
    }

    guard currentInputSource == .doubao else {
      state = .idle
      return [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)]
    }

    guard isOriginalInputSourceAvailable else {
      state = .idle
      return [.skipRestore(reason: .originalInputSourceUnavailable)]
    }

    let restoreElapsedMilliseconds = max(
      0,
      elapsedMilliseconds - runningInputStoppedElapsedMilliseconds
    )
    guard restoreElapsedMilliseconds >= configuration.restoreStabilityDelayMilliseconds
      || restoreElapsedMilliseconds >= configuration.restoreMaximumDelayMilliseconds else {
      return []
    }

    state = .idle
    return [.restoreInputSource(originalInputSourceID: originalInputSourceID)]
  }
}

private enum State {
  case idle
  case waitingForDoubao(
    originalInputSourceID: String,
    observedElapsedMilliseconds: Int
  )
  case waitingForRunningInput(
    originalInputSourceID: String,
    observedElapsedMilliseconds: Int,
    doubaoSelectedElapsedMilliseconds: Int
  )
  case voiceActive(
    originalInputSourceID: String,
    observedElapsedMilliseconds: Int,
    doubaoSelectedElapsedMilliseconds: Int,
    runningInputStartedElapsedMilliseconds: Int
  )
  case restoring(
    originalInputSourceID: String,
    observedElapsedMilliseconds: Int,
    doubaoSelectedElapsedMilliseconds: Int,
    runningInputStartedElapsedMilliseconds: Int,
    runningInputStoppedElapsedMilliseconds: Int
  )

  var originalInputSourceID: String? {
    switch self {
    case .idle:
      return nil
    case let .waitingForDoubao(originalInputSourceID, _),
         let .waitingForRunningInput(originalInputSourceID, _, _),
         let .voiceActive(originalInputSourceID, _, _, _),
         let .restoring(originalInputSourceID, _, _, _, _):
      return originalInputSourceID
    }
  }

  var description: String {
    switch self {
    case .idle:
      return "idle"
    case .waitingForDoubao:
      return "waitingForDoubao"
    case .waitingForRunningInput:
      return "waitingForRunningInput"
    case .voiceActive:
      return "voiceActive"
    case .restoring:
      return "restoring"
    }
  }
}
