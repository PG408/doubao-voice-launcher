public enum VoiceSessionRecognitionPolicy {
  public static let defaultWindowSeconds = 3.0
  public static let minimumWindowSeconds = 0.0
  public static let maximumWindowSeconds = 10.0
  public static let windowStepSeconds = 0.1
  public static let restoreStabilityDelayMilliseconds = 500

  public static func normalizedWindowSeconds(_ seconds: Double) -> Double {
    min(max(seconds, minimumWindowSeconds), maximumWindowSeconds)
  }

  public static func windowMilliseconds(for seconds: Double) -> Int {
    Int((normalizedWindowSeconds(seconds) * 1_000).rounded())
  }
}

public enum VoiceInputRestoreDeadline: Equatable, Sendable {
  case recognitionWindow
  case restoreWindow
}

public enum VoiceInputRestoreSkippedReason: Equatable, Sendable {
  case returnedToOriginalBeforeVoice
  case recognitionWindowExpired
  case originalInputSourceUnavailable
  case alreadyAtOriginalInputSource
}

public enum VoiceInputRestoreAction: Equatable, Sendable {
  case scheduleDeadline(
    VoiceInputRestoreDeadline,
    delayMilliseconds: Int
  )
  case cancelDeadline
  case restoreInputSource(originalInputSourceID: String)
  case skipRestore(
    reason: VoiceInputRestoreSkippedReason,
    originalInputSourceID: String?
  )
}

public final class VoiceInputRestoreController {
  private var currentInputSource: InputSourceIdentity?
  private var session: Session?

  public init() {}

  public var stateDescription: String {
    session?.phase.description ?? "idle"
  }

  public var isIdle: Bool {
    session == nil
  }

  public var shouldObserveRunningInput: Bool {
    session != nil
  }

  public var originalInputSourceID: String? {
    session?.originalInputSourceID
  }

  public func synchronizeCurrentInputSource(_ inputSource: InputSourceIdentity) {
    currentInputSource = inputSource
    session = nil
  }

  public func currentInputSourceChanged(
    to inputSource: InputSourceIdentity,
    recognitionWindowMilliseconds: Int
  ) -> [VoiceInputRestoreAction] {
    let previousInputSource = currentInputSource
    currentInputSource = inputSource

    guard previousInputSource != inputSource else {
      return []
    }

    if var session {
      guard session.phase == .candidate else {
        return []
      }

      if inputSource.restorationID == session.originalInputSourceID {
        self.session = nil
        return [
          .skipRestore(
            reason: .returnedToOriginalBeforeVoice,
            originalInputSourceID: session.originalInputSourceID
          )
        ]
      }

      if inputSource == .doubao {
        session.reachedDoubao = true
        self.session = session
      }
      return []
    }

    guard let originalInputSourceID = previousInputSource?.restorationID,
          !originalInputSourceID.isEmpty else {
      return []
    }

    session = Session(
      originalInputSourceID: originalInputSourceID,
      phase: .candidate,
      reachedDoubao: inputSource == .doubao
    )
    return [
      .scheduleDeadline(
        .recognitionWindow,
        delayMilliseconds: max(0, recognitionWindowMilliseconds)
      )
    ]
  }

  public func runningInputChanged(
    isRunningInput: Bool
  ) -> [VoiceInputRestoreAction] {
    guard var session else {
      return []
    }

    switch session.phase {
    case .candidate:
      guard isRunningInput, session.reachedDoubao else {
        return []
      }
      session.phase = .voiceActive
      self.session = session
      return [.cancelDeadline]
    case .voiceActive:
      guard !isRunningInput else {
        return []
      }
      session.phase = .restoring
      self.session = session
      return [
        .scheduleDeadline(
          .restoreWindow,
          delayMilliseconds: VoiceSessionRecognitionPolicy.restoreStabilityDelayMilliseconds
        )
      ]
    case .restoring:
      guard isRunningInput else {
        return []
      }
      session.phase = .voiceActive
      self.session = session
      return [.cancelDeadline]
    }
  }

  public func deadlineElapsed(
    _ deadline: VoiceInputRestoreDeadline,
    isOriginalInputSourceAvailable: Bool = true
  ) -> [VoiceInputRestoreAction] {
    guard let session else {
      return []
    }

    switch (session.phase, deadline) {
    case (.candidate, .recognitionWindow):
      self.session = nil
      return [
        .skipRestore(
          reason: .recognitionWindowExpired,
          originalInputSourceID: session.originalInputSourceID
        )
      ]
    case (.restoring, .restoreWindow):
      self.session = nil

      guard isOriginalInputSourceAvailable else {
        return [
          .skipRestore(
            reason: .originalInputSourceUnavailable,
            originalInputSourceID: session.originalInputSourceID
          )
        ]
      }

      if currentInputSource?.restorationID == session.originalInputSourceID {
        return [
          .skipRestore(
            reason: .alreadyAtOriginalInputSource,
            originalInputSourceID: session.originalInputSourceID
          )
        ]
      }

      return [.restoreInputSource(originalInputSourceID: session.originalInputSourceID)]
    default:
      return []
    }
  }
}

private struct Session {
  let originalInputSourceID: String
  var phase: Phase
  var reachedDoubao: Bool
}

private enum Phase: Equatable {
  case candidate
  case voiceActive
  case restoring

  var description: String {
    switch self {
    case .candidate:
      return "candidate"
    case .voiceActive:
      return "voiceActive"
    case .restoring:
      return "restoring"
    }
  }
}
