import AppKit
import DoubaoVoiceSwitchCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  @Published private(set) var readinessState = AppReadinessState()
  @Published private(set) var lastFailureMessage: String?

  private let probe: PlatformReadinessProbe
  private let logger: DiagnosticLogger
  private let inputSourceService = InputSourceService()
  private let audioInputProbe = DoubaoAudioInputProbe()
  private let restoreController = VoiceInputRestoreController()
  private let launchAtLoginService = LaunchAtLoginService()

  private var readinessTimer: Timer?
  private var inputSourceObservationTimer: Timer?
  private var pendingDeadlineWorkItem: DispatchWorkItem?
  private var chainStartedAt: Date?
  private var lastObservedInputSource: InputSourceIdentity?
  private var lastLoggedStatus: AppStatus?
  private var lastLoggedDoubaoAvailability: Bool?
  private var doubaoInputSourceAvailable = false

  private init(
    probe: PlatformReadinessProbe = PlatformReadinessProbe(),
    logger: DiagnosticLogger? = nil
  ) {
    self.probe = probe
    self.logger = logger ?? DiagnosticLogger(logDirectory: defaultLogDirectory(), retentionDays: 7)

    let currentInputSource = inputSourceService.currentInputSource()
    lastObservedInputSource = currentInputSource
    restoreController.synchronizeCurrentInputSource(currentInputSource)

    configureAudioInputCallbacks()
    recordLaunchSource()
    refreshReadiness()
    startReadinessPolling()
    startInputSourceObservationPolling()
    pruneLogs()
  }

  var status: AppStatus {
    readinessState.status
  }

  var statusTitle: String {
    status.title
  }

  var isDoubaoInputSourceAvailable: Bool {
    doubaoInputSourceAvailable
  }

  var logDirectory: URL {
    logger.logDirectory
  }

  func refreshReadiness() {
    doubaoInputSourceAvailable = probe.isDoubaoInputSourceAvailable()
    readinessState.setDoubaoInputSourceAvailable(doubaoInputSourceAvailable)

    if status == .preparing, !restoreController.isIdle {
      resetObservation(reason: "preparing")
    }

    recordReadinessIfChanged()
  }

  func pause() {
    resetObservation(reason: "pause")
    readinessState.pause()
    record(.app, "paused by user")
  }

  func resume() {
    readinessState.resume()
    refreshReadiness()
    resetObservation(reason: "resume")
    record(.app, "resumed by user")
  }

  func openLogFolder() {
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(logDirectory)
    activateOpenedApplication(bundleIdentifier: "com.apple.finder")
  }

  func clearLogs() {
    try? FileManager.default.removeItem(at: logDirectory)
  }

  func setLaunchAtLogin(_ isEnabled: Bool) {
    do {
      try launchAtLoginService.setEnabled(isEnabled)
      record(.app, "launch at login \(isEnabled ? "enabled" : "disabled")")
    } catch {
      lastFailureMessage = String(describing: error)
      record(.app, "launch at login failed: \(error)")
    }
  }

  func isLaunchAtLoginEnabled() -> Bool {
    launchAtLoginService.isEnabled()
  }

  private func configureAudioInputCallbacks() {
    audioInputProbe.onRunningInputChanged = { [weak self] runningInput in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.handleRunningInputChanged(runningInput)
        }
      }
    }
  }

  private func recordLaunchSource() {
    let source = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] == nil
      ? "manual or script launch"
      : "bundle launch"
    record(.app, "application launched: \(source)")
  }

  private func recordReadinessIfChanged() {
    guard lastLoggedStatus != status
      || lastLoggedDoubaoAvailability != doubaoInputSourceAvailable else {
      return
    }

    lastLoggedStatus = status
    lastLoggedDoubaoAvailability = doubaoInputSourceAvailable
    record(
      .app,
      "readiness status \(status.title), doubaoInputSource=\(doubaoInputSourceAvailable)"
    )
  }

  private func startReadinessPolling() {
    readinessTimer?.invalidate()
    readinessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshReadiness() }
    }
  }

  private func startInputSourceObservationPolling() {
    inputSourceObservationTimer?.invalidate()
    inputSourceObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.observeInputSource() }
    }
  }

  private func observeInputSource() {
    guard status == .running else {
      return
    }

    _ = observeCurrentInputSource()
    updateRunningInputObservation()
  }

  @discardableResult
  private func observeCurrentInputSource() -> InputSourceIdentity {
    let currentInputSource = inputSourceService.currentInputSource()
    guard lastObservedInputSource != currentInputSource else {
      return currentInputSource
    }

    lastObservedInputSource = currentInputSource
    let stateBefore = restoreController.stateDescription
    let actions = restoreController.currentInputSourceChanged(
      to: currentInputSource,
      recognitionWindowMilliseconds: recognitionWindowMilliseconds
    )
    record(
      .inputSource,
      "currentInputSource=\(currentInputSource), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    applyRestoreActions(actions, reason: "currentInputSourceChanged")
    return currentInputSource
  }

  private func handleRunningInputChanged(_ runningInput: Bool) {
    guard status == .running else {
      return
    }

    let currentInputSource = observeCurrentInputSource()
    guard restoreController.shouldObserveRunningInput else {
      return
    }

    let stateBefore = restoreController.stateDescription
    let actions = restoreController.runningInputChanged(isRunningInput: runningInput)
    record(
      .voiceReadiness,
      "runningInput transition runningInput=\(runningInput), currentInputSource=\(currentInputSource), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    applyRestoreActions(actions, reason: "runningInputChanged")
  }

  private func scheduleDeadline(
    _ deadline: VoiceInputRestoreDeadline,
    delayMilliseconds: Int
  ) {
    cancelPendingDeadline()

    if deadline == .recognitionWindow {
      chainStartedAt = Date()
    }

    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runDeadline(deadline)
      }
    }
    pendingDeadlineWorkItem = workItem

    record(
      deadline == .recognitionWindow ? .recognition : .restoration,
      "deadlineScheduled type=\(deadline.logValue), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), delayMs=\(delayMilliseconds), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )

    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runDeadline(_ deadline: VoiceInputRestoreDeadline) {
    pendingDeadlineWorkItem = nil
    _ = observeCurrentInputSource()

    let originalInputSourceID = restoreController.originalInputSourceID
    let originalAvailable = originalInputSourceID.map {
      inputSourceService.isInputSourceAvailable(id: $0)
    } ?? false
    let stateBefore = restoreController.stateDescription
    let actions = restoreController.deadlineElapsed(
      deadline,
      isOriginalInputSourceAvailable: originalAvailable
    )
    guard !actions.isEmpty else {
      return
    }

    record(
      deadline == .recognitionWindow ? .recognition : .restoration,
      "deadlineElapsed type=\(deadline.logValue), originalInputSourceID=\(originalInputSourceID ?? "none"), originalAvailable=\(originalAvailable), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    applyRestoreActions(actions, reason: "deadlineElapsed")
  }

  private func applyRestoreActions(_ actions: [VoiceInputRestoreAction], reason: String) {
    for action in actions {
      switch action {
      case let .scheduleDeadline(deadline, delayMilliseconds):
        scheduleDeadline(deadline, delayMilliseconds: delayMilliseconds)
      case .cancelDeadline:
        cancelPendingDeadline()
      case let .restoreInputSource(originalInputSourceID):
        restoreInputSource(originalInputSourceID, reason: reason)
      case let .skipRestore(skippedReason, originalInputSourceID):
        cancelPendingDeadline()
        record(
          .restoration,
          "restoreSkippedReason=\(skippedReason.logValue), currentInputSource=\(inputSourceService.currentInputSource()), originalInputSourceID=\(originalInputSourceID ?? "none"), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
        )
        clearCompletedObservation()
      }
    }
    updateRunningInputObservation()
  }

  private func updateRunningInputObservation() {
    guard status == .running, restoreController.shouldObserveRunningInput else {
      audioInputProbe.stopObserving()
      return
    }
    audioInputProbe.startObserving()
  }

  private func restoreInputSource(_ inputSourceID: String, reason: String) {
    do {
      try inputSourceService.restoreInputSource(id: inputSourceID)
      let currentInputSource = inputSourceService.currentInputSource()
      lastObservedInputSource = currentInputSource
      restoreController.synchronizeCurrentInputSource(currentInputSource)
      lastFailureMessage = nil
      record(
        .restoration,
        "restoreCompleted originalInputSourceID=\(inputSourceID), currentInputSource=\(currentInputSource), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
      )
    } catch {
      let currentInputSource = inputSourceService.currentInputSource()
      lastObservedInputSource = currentInputSource
      restoreController.synchronizeCurrentInputSource(currentInputSource)
      lastFailureMessage = String(describing: error)
      record(
        .restoration,
        "restoreSkippedReason=restoreFailed, originalInputSourceID=\(inputSourceID), error=\(error), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
      )
    }
    clearCompletedObservation()
  }

  private func resetObservation(reason: String) {
    cancelPendingDeadline()
    audioInputProbe.stopObserving()
    chainStartedAt = nil

    let currentInputSource = inputSourceService.currentInputSource()
    lastObservedInputSource = currentInputSource
    restoreController.synchronizeCurrentInputSource(currentInputSource)
    record(.restoration, "restoreSkippedReason=reset, reason=\(reason)")
  }

  private func cancelPendingDeadline() {
    pendingDeadlineWorkItem?.cancel()
    pendingDeadlineWorkItem = nil
  }

  private func clearCompletedObservation() {
    audioInputProbe.stopObserving()
    chainStartedAt = nil
  }

  private var recognitionWindowMilliseconds: Int {
    let defaults = UserDefaults.standard
    let seconds = defaults.object(forKey: "recognitionWindowSeconds") == nil
      ? VoiceSessionRecognitionPolicy.defaultWindowSeconds
      : defaults.double(forKey: "recognitionWindowSeconds")
    return VoiceSessionRecognitionPolicy.windowMilliseconds(for: seconds)
  }

  private func elapsedMilliseconds() -> Int {
    guard let chainStartedAt else {
      return 0
    }
    return max(0, Int(Date().timeIntervalSince(chainStartedAt) * 1_000))
  }

  private func pruneLogs() {
    try? logger.pruneLogs()
  }

  private func record(_ category: DiagnosticLogCategory, _ message: String) {
    try? logger.record(
      DiagnosticLogEntry(
        timestamp: Date(),
        category: category,
        message: "status=\(status.title), \(message)"
      )
    )
  }

  private func activateOpenedApplication(bundleIdentifier: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
      guard let application = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first else {
        return
      }
      application.activate(options: [.activateAllWindows])
    }
  }
}

private func defaultLogDirectory() -> URL {
  let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? FileManager.default.temporaryDirectory
  return base
    .appendingPathComponent("DoubaoVoiceSwitch", isDirectory: true)
    .appendingPathComponent("Logs", isDirectory: true)
}

private extension VoiceInputRestoreDeadline {
  var logValue: String {
    switch self {
    case .recognitionWindow:
      return "recognitionWindow"
    case .restoreWindow:
      return "restoreWindow"
    }
  }
}

private extension VoiceInputRestoreSkippedReason {
  var logValue: String {
    switch self {
    case .returnedToOriginalBeforeVoice:
      return "returnedToOriginalBeforeVoice"
    case .recognitionWindowExpired:
      return "recognitionWindowExpired"
    case .originalInputSourceUnavailable:
      return "originalInputSourceUnavailable"
    case .alreadyAtOriginalInputSource:
      return "alreadyAtOriginalInputSource"
    }
  }
}
