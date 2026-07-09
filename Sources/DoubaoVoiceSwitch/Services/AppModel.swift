import AppKit
import DoubaoVoiceSwitchCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  @Published private(set) var readinessState = AppReadinessState()
  @Published private(set) var lastMessage = "正在检查前置条件"
  @Published private(set) var isInputSourceHandoffActive = false
  @Published private(set) var lastFailureMessage: String?

  private let probe: PlatformReadinessProbe
  private let logger: DiagnosticLogger
  private let hotKeyService: GlobalHotKeyService
  private let inputSourceService = InputSourceService()
  private let audioInputProbe = DoubaoAudioInputProbe()
  private let restoreController = VoiceInputRestoreController()
  private let forwardingPolicy = ShortcutEventForwardingPolicy()
  private let launchAtLoginService = LaunchAtLoginService()

  private var readinessTimer: Timer?
  private var observationTimer: Timer?
  private var registeredShortcut: DoubaoShortcut?
  private var pendingInputSourceTimeoutWorkItem: DispatchWorkItem?
  private var pendingRunningInputTimeoutWorkItem: DispatchWorkItem?
  private var pendingRestoreWorkItem: DispatchWorkItem?
  private var chainStartedAt: Date?
  private var lastObservedInputSource: InputSourceIdentity?
  private var lastObservedRunningInput: Bool?
  private var lastObservedOriginalInputSourceID: String?
  private var lastLoggedStatus: AppStatus?
  private var lastLoggedPrerequisites: [Bool]?

  private var accessibilityTrusted = false
  private var doubaoInputSourceAvailable = false

  private init(
    probe: PlatformReadinessProbe = PlatformReadinessProbe(),
    hotKeyService: GlobalHotKeyService = GlobalHotKeyService(),
    logger: DiagnosticLogger? = nil
  ) {
    self.probe = probe
    self.hotKeyService = hotKeyService
    self.logger = logger ?? DiagnosticLogger(logDirectory: defaultLogDirectory(), retentionDays: 7)
    configureHotKeyCallbacks()
    recordLaunchSource()
    refreshReadiness()
    startReadinessPolling()
    startObservationPolling()
    pruneLogs()
  }

  var status: AppStatus {
    readinessState.status
  }

  var statusTitle: String {
    status.title
  }

  var statusSystemImage: String {
    status.systemImage
  }

  var prerequisites: [PrerequisiteItem] {
    [
      PrerequisiteItem(
        id: "accessibility",
        title: "辅助功能权限",
        detail: accessibilityTrusted ? "已开启" : "需要手动授权后才能观察豆包语音快捷键",
        isReady: accessibilityTrusted,
        actionTitle: accessibilityTrusted ? nil : "请求授权"
      ),
      PrerequisiteItem(
        id: "doubao",
        title: "豆包输入法",
        detail: doubaoInputSourceAvailable ? "已检测到" : "未检测到豆包输入法",
        isReady: doubaoInputSourceAvailable,
        actionTitle: nil
      ),
    ]
  }

  var logDirectory: URL {
    logger.logDirectory
  }

  func refreshReadiness() {
    accessibilityTrusted = probe.isAccessibilityTrusted()
    doubaoInputSourceAvailable = probe.isDoubaoInputSourceAvailable()

    readinessState.setAccessibilityTrusted(accessibilityTrusted)
    readinessState.setDoubaoInputSourceAvailable(doubaoInputSourceAvailable)

    switch status {
    case .running:
      lastMessage = "正在监听豆包语音快捷键"
    case .paused:
      lastMessage = "已暂停监听快捷键"
    case .preparing:
      lastMessage = "仍有前置条件未完成"
    }

    if status == .preparing {
      resetObservation(reason: "preparing")
    }

    recordReadinessIfChanged()
    updateGlobalShortcutRegistration()
  }

  func pause() {
    resetObservation(reason: "pause")
    readinessState.pause()
    lastMessage = status == .paused ? "已暂停监听快捷键" : "仍有前置条件未完成"
    record(.app, "paused by user")
    updateGlobalShortcutRegistration()
  }

  func resume() {
    readinessState.resume()
    refreshReadiness()
    record(.app, "resumed by user")
  }

  func updateGlobalShortcutRegistration() {
    if status == .running || status == .paused {
      guard registeredShortcut != storedShortcut else {
        return
      }
      do {
        try hotKeyService.register(shortcut: storedShortcut)
        registeredShortcut = storedShortcut
        lastFailureMessage = nil
        record(.shortcut, "registered shortcut \(storedShortcut.displayText)")
      } catch {
        registeredShortcut = nil
        lastFailureMessage = String(describing: error)
        record(.shortcut, "shortcut registration failed: \(error)")
      }
    } else {
      hotKeyService.unregister()
      registeredShortcut = nil
    }
  }

  func openAccessibilitySettings() {
    probe.requestAccessibilityTrustPrompt()
    record(.app, "requested accessibility trust prompt")

    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
      activateOpenedApplication(bundleIdentifier: "com.apple.systempreferences")
    }
  }

  func openLogFolder() {
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(logDirectory)
    activateOpenedApplication(bundleIdentifier: "com.apple.finder")
  }

  func clearLogs() {
    try? FileManager.default.removeItem(at: logDirectory)
    lastMessage = "日志已清空"
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

  func restoreInputSourceIfNeeded(reason: String) {
    resetObservation(reason: reason)
  }

  private func configureHotKeyCallbacks() {
    hotKeyService.onShortcutEventObserved = { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.status == .running else {
          return
        }
        self.record(.shortcut, event.message)
      }
    }
    hotKeyService.onKeyDown = { [weak self] shortcut in
      MainActor.assumeIsolated {
        self?.handleGlobalShortcutKeyDown(shortcut: shortcut)
      }
    }
    hotKeyService.onKeyUp = { [weak self] in
      MainActor.assumeIsolated {
        self?.handleGlobalShortcutKeyUp()
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
    let currentPrerequisites = [
      accessibilityTrusted,
      doubaoInputSourceAvailable
    ]

    guard lastLoggedStatus != status || lastLoggedPrerequisites != currentPrerequisites else {
      return
    }

    lastLoggedStatus = status
    lastLoggedPrerequisites = currentPrerequisites
    record(
      .app,
      "readiness status \(status.title), accessibility=\(accessibilityTrusted), doubaoInputSource=\(doubaoInputSourceAvailable)"
    )
  }

  private func startReadinessPolling() {
    readinessTimer?.invalidate()
    readinessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshReadiness() }
    }
  }

  private func startObservationPolling() {
    observationTimer?.invalidate()
    observationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.observeHandoffSignals() }
    }
  }

  private func handleGlobalShortcutKeyDown(shortcut: DoubaoShortcut) {
    guard status == .running else {
      record(.shortcut, "shortcut observed while \(status.title), eventDisposition=\(forwardingPolicy.keyDownForwarding())")
      return
    }

    if restoreController.isIdle {
      cancelPendingWork()
      chainStartedAt = Date()
      lastObservedOriginalInputSourceID = nil
    }
    let currentInputSource = inputSourceService.currentInputSource()
    lastObservedInputSource = currentInputSource
    let runningInput = audioInputProbe.isRunningInput()
    lastObservedRunningInput = runningInput
    let stateBefore = restoreController.stateDescription
    let actions = restoreController.shortcutObserved(
      currentInputSource: currentInputSource,
      elapsedMilliseconds: 0
    )
    lastObservedOriginalInputSourceID = restoreController.originalInputSourceID
    isInputSourceHandoffActive = !restoreController.isIdle
    record(
      .shortcut,
      "shortcutObserved shortcut=\(shortcut.displayText), eventDisposition=\(forwardingPolicy.keyDownForwarding()), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), currentInputSource=\(currentInputSource), runningInput=\(runningInput), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=0"
    )
    applyRestoreActions(actions, reason: "shortcutObserved")
  }

  private func handleGlobalShortcutKeyUp() {
    record(
      .shortcut,
      "shortcut keyUp observed, eventDisposition=\(forwardingPolicy.keyUpForwarding()), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
  }

  private func observeHandoffSignals() {
    guard status == .running else {
      return
    }

    let currentInputSource = inputSourceService.currentInputSource()
    if lastObservedInputSource != currentInputSource {
      lastObservedInputSource = currentInputSource
      let stateBefore = restoreController.stateDescription
      let actions = restoreController.currentInputSourceChanged(
        to: currentInputSource,
        elapsedMilliseconds: elapsedMilliseconds()
      )
      record(
        .inputSource,
        "currentInputSource=\(currentInputSource), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
      )
      applyRestoreActions(actions, reason: "currentInputSourceChanged")
    }

    let runningInput = audioInputProbe.isRunningInput()
    if lastObservedRunningInput != runningInput {
      lastObservedRunningInput = runningInput
      let stateBefore = restoreController.stateDescription
      let actions = restoreController.runningInputChanged(
        isRunningInput: runningInput,
        currentInputSource: currentInputSource,
        elapsedMilliseconds: elapsedMilliseconds()
      )
      record(
        .voiceReadiness,
        "runningInput transition runningInput=\(runningInput), currentInputSource=\(currentInputSource), originalInputSourceID=\(restoreController.originalInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
      )
      applyRestoreActions(actions, reason: "runningInputChanged")
    }
  }

  private func scheduleTimeout(
    reason: VoiceInputRestoreTimeoutReason,
    delayMilliseconds: Int
  ) {
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runTimeout(reason: reason)
      }
    }

    switch reason {
    case .doubaoInputSource:
      pendingInputSourceTimeoutWorkItem?.cancel()
      pendingInputSourceTimeoutWorkItem = workItem
    case .runningInputStart:
      pendingRunningInputTimeoutWorkItem?.cancel()
      pendingRunningInputTimeoutWorkItem = workItem
    }

    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runTimeout(reason: VoiceInputRestoreTimeoutReason) {
    switch reason {
    case .doubaoInputSource:
      pendingInputSourceTimeoutWorkItem = nil
    case .runningInputStart:
      pendingRunningInputTimeoutWorkItem = nil
    }

    let stateBefore = restoreController.stateDescription
    let actions = restoreController.timeoutElapsed(
      reason: reason,
      elapsedMilliseconds: elapsedMilliseconds()
    )
    record(
      .restoration,
      "timeoutReason=\(reason.logValue), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    applyRestoreActions(actions, reason: "timeoutElapsed")
  }

  private func scheduleRestore(
    originalInputSourceID: String,
    delayMilliseconds: Int,
    maximumDelayMilliseconds: Int
  ) {
    pendingRestoreWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runRestoreWindow(originalInputSourceID: originalInputSourceID)
      }
    }
    pendingRestoreWorkItem = workItem
    record(
      .restoration,
      "restoreScheduled originalInputSourceID=\(originalInputSourceID), delayMs=\(delayMilliseconds), maximumDelayMs=\(maximumDelayMilliseconds), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runRestoreWindow(originalInputSourceID: String) {
    pendingRestoreWorkItem = nil
    let currentInputSource = inputSourceService.currentInputSource()
    let isOriginalAvailable = inputSourceService.isInputSourceAvailable(id: originalInputSourceID)
    let stateBefore = restoreController.stateDescription
    let actions = restoreController.restoreWindowElapsed(
      currentInputSource: currentInputSource,
      isOriginalInputSourceAvailable: isOriginalAvailable,
      elapsedMilliseconds: elapsedMilliseconds()
    )
    record(
      .restoration,
      "restoreWindowElapsed originalInputSourceID=\(originalInputSourceID), originalAvailable=\(isOriginalAvailable), currentInputSource=\(currentInputSource), handoffStateBefore=\(stateBefore), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds())"
    )
    applyRestoreActions(actions, reason: "restoreWindowElapsed")
  }

  private func applyRestoreActions(_ actions: [VoiceInputRestoreAction], reason: String) {
    for action in actions {
      switch action {
      case let .scheduleInputSourceChangeTimeout(delayMilliseconds):
        scheduleTimeout(reason: .doubaoInputSource, delayMilliseconds: delayMilliseconds)
      case let .scheduleRunningInputStartTimeout(delayMilliseconds):
        pendingInputSourceTimeoutWorkItem?.cancel()
        pendingInputSourceTimeoutWorkItem = nil
        scheduleTimeout(reason: .runningInputStart, delayMilliseconds: delayMilliseconds)
      case let .scheduleRestore(originalInputSourceID, delayMilliseconds, maximumDelayMilliseconds):
        pendingRunningInputTimeoutWorkItem?.cancel()
        pendingRunningInputTimeoutWorkItem = nil
        scheduleRestore(
          originalInputSourceID: originalInputSourceID,
          delayMilliseconds: delayMilliseconds,
          maximumDelayMilliseconds: maximumDelayMilliseconds
        )
      case let .restoreInputSource(originalInputSourceID):
        restoreInputSource(originalInputSourceID, reason: reason)
      case let .skipRestore(skippedReason):
        let originalInputSourceID = lastObservedOriginalInputSourceID ?? restoreController.originalInputSourceID ?? "none"
        record(
          .restoration,
          "restoreSkippedReason=\(skippedReason.logValue), currentInputSource=\(inputSourceService.currentInputSource()), originalInputSourceID=\(originalInputSourceID), handoffState=\(restoreController.stateDescription), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
        )
        clearCompletedObservation()
      }
    }
    isInputSourceHandoffActive = !restoreController.isIdle
  }

  private func restoreInputSource(_ inputSourceID: String, reason: String) {
    do {
      try inputSourceService.restoreInputSource(id: inputSourceID)
      isInputSourceHandoffActive = false
      lastFailureMessage = nil
      lastMessage = "已恢复原输入法"
      record(
        .restoration,
        "restoreCompleted originalInputSourceID=\(inputSourceID), currentInputSource=\(inputSourceService.currentInputSource()), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
      )
      clearCompletedObservation()
    } catch {
      isInputSourceHandoffActive = false
      lastFailureMessage = String(describing: error)
      lastMessage = "恢复原输入法失败"
      record(
        .restoration,
        "restoreSkippedReason=restoreFailed, originalInputSourceID=\(inputSourceID), error=\(error), elapsedMs=\(elapsedMilliseconds()), reason=\(reason)"
      )
      clearCompletedObservation()
    }
  }

  private func resetObservation(reason: String) {
    cancelPendingWork()
    restoreController.reset()
    clearCompletedObservation()
    isInputSourceHandoffActive = false
    record(.restoration, "restoreSkippedReason=reset, reason=\(reason), elapsedMs=\(elapsedMilliseconds())")
  }

  private func cancelPendingWork() {
    pendingInputSourceTimeoutWorkItem?.cancel()
    pendingInputSourceTimeoutWorkItem = nil
    pendingRunningInputTimeoutWorkItem?.cancel()
    pendingRunningInputTimeoutWorkItem = nil
    pendingRestoreWorkItem?.cancel()
    pendingRestoreWorkItem = nil
  }

  private func clearCompletedObservation() {
    chainStartedAt = nil
    lastObservedRunningInput = nil
    lastObservedOriginalInputSourceID = nil
  }

  private var storedShortcut: DoubaoShortcut {
    DoubaoShortcut(storageValue: UserDefaults.standard.string(forKey: "doubaoShortcutKeys"))
  }

  private func elapsedMilliseconds() -> Int {
    guard let chainStartedAt else {
      return 0
    }
    return max(0, Int(Date().timeIntervalSince(chainStartedAt) * 1000))
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

      if #available(macOS 14.0, *) {
        application.activate(options: [.activateAllWindows])
      } else {
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
      }
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

private extension VoiceInputRestoreTimeoutReason {
  var logValue: String {
    switch self {
    case .doubaoInputSource:
      return "doubaoInputSource"
    case .runningInputStart:
      return "runningInputStart"
    }
  }
}

private extension VoiceInputRestoreSkippedReason {
  var logValue: String {
    switch self {
    case .shortcutStartedFromDoubao:
      return "shortcutStartedFromDoubao"
    case .originalInputSourceUnavailable:
      return "originalInputSourceUnavailable"
    case .currentInputSourceChangedBeforeRestore:
      return "currentInputSourceChangedBeforeRestore"
    case .doubaoInputSourceTimedOut:
      return "doubaoInputSourceTimedOut"
    case .runningInputStartTimedOut:
      return "runningInputStartTimedOut"
    }
  }
}
