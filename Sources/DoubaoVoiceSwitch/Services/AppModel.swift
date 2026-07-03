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
  private let handoffController = InputSourceHandoffController()
  private let forwardingPolicy = ShortcutEventForwardingPolicy()
  private let voiceActivationRetryPolicy = VoiceActivationRetryPolicy()
  private let voiceEndRestorePolicy = VoiceEndRestorePolicy()
  private let launchAtLoginService = LaunchAtLoginService()
  private let toastPresenter = ToastPresenter()
  private let shortcutSuppressionMilliseconds = 300
  private let voiceActivationFailureToastMilliseconds = 1_500
  private let nearThresholdLongPressToastMilliseconds = 3_000
  private let nearThresholdLongPressToastCooldownMilliseconds = 3_000

  private var readinessTimer: Timer?
  private var registeredShortcut: DoubaoShortcut?
  private var pendingRestoreWorkItem: DispatchWorkItem?
  private var pendingLongPressWorkItem: DispatchWorkItem?
  private var pendingVoiceActivationProbeWorkItem: DispatchWorkItem?
  private var pendingVoiceActivationRetryKeyDownWorkItem: DispatchWorkItem?
  private var shortcutDownDate: Date?
  private var shortcutSuppressionUntil: Date?
  private var pendingSuppressedShortcutKeyUps = 0
  private var shortcutStartedFromInputSourceHandoff = false
  private var lastNearThresholdLongPressToastDate: Date?
  private var lastRestorableInputSourceID: String?
  private var lastLoggedStatus: AppStatus?
  private var lastLoggedPrerequisites: [Bool]?
  private var voiceActivationAttemptStartedAt: Date?
  private var firstSyntheticReplaySentAt: Date?
  private var retrySyntheticReplaySentAt: Date?

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
    self.hotKeyService.syntheticHoldKeyDownDelayMilliseconds =
      voiceActivationRetryPolicy.firstReplayDelayMilliseconds
    loadLongPressThresholdPreference()
    configureHotKeyCallbacks()
    recordLaunchSource()
    refreshReadiness()
    startReadinessPolling()
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
        detail: accessibilityTrusted ? "已开启" : "需要手动授权后才能转发豆包快捷键",
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
      lastMessage = "前置条件已满足"
    case .paused:
      lastMessage = "已暂停响应快捷键"
    case .preparing:
      lastMessage = "仍有前置条件未完成"
    }

    if status == .preparing {
      restoreInputSourceIfNeeded(reason: "preparing")
    }

    recordReadinessIfChanged()
    updateGlobalShortcutRegistration()
  }

  func pause() {
    restoreInputSourceIfNeeded(reason: "pause")
    readinessState.pause()
    lastMessage = status == .paused ? "已暂停响应快捷键" : "仍有前置条件未完成"
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

  func updateLongPressThresholdMilliseconds(_ milliseconds: Int) {
    let clampedMilliseconds = LongPressThresholdPreference.clamped(milliseconds)
    guard handoffController.longPressThresholdMilliseconds != clampedMilliseconds else {
      return
    }

    UserDefaults.standard.set(clampedMilliseconds, forKey: LongPressThresholdPreference.storageKey)
    handoffController.updateLongPressThresholdMilliseconds(clampedMilliseconds)
    record(.shortcut, "updated longPress threshold thresholdMs=\(clampedMilliseconds)")
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
    cancelVoiceActivationProbe()
    if hotKeyService.releaseSyntheticHoldIfNeeded() {
      record(.shortcut, "released synthetic hold, releaseReason=\(reason)")
    }
    applyHandoffActions(handoffController.cancelHandoff(), reason: reason)
    clearVoiceActivationTracking()
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
    hotKeyService.onSyntheticHoldKeyDownReplay = { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.status == .running else {
          return
        }
        self.handleSyntheticHoldKeyDownReplay(event)
      }
    }
    hotKeyService.onKeyDown = { [weak self] shortcut in
      MainActor.assumeIsolated {
        self?.handleGlobalShortcutKeyDown(shortcut: shortcut) ?? .passThrough
      }
    }
    hotKeyService.onKeyUp = { [weak self] in
      MainActor.assumeIsolated {
        self?.handleGlobalShortcutKeyUp() ?? .passThrough
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

  private func handleGlobalShortcutKeyDown(shortcut: DoubaoShortcut) -> GlobalHotKeyEventDisposition {
    guard status == .running else {
      record(.shortcut, "shortcut ignored while \(status.title)")
      return .passThrough
    }

    let now = Date()
    if isShortcutSuppressionActive(at: now) {
      pendingSuppressedShortcutKeyUps += 1
      record(
        .shortcut,
        "shortcut ignored by suppression window event=keyDown, shortcut=\(shortcut.displayText), pendingSuppressedKeyUps=\(pendingSuppressedShortcutKeyUps), handoffState=\(handoffController.stateDescription)"
      )
      return .suppress
    }

    pendingRestoreWorkItem?.cancel()
    pendingRestoreWorkItem = nil
    pendingLongPressWorkItem?.cancel()
    pendingLongPressWorkItem = nil
    cancelVoiceActivationProbe()
    clearVoiceActivationTracking()
    shortcutDownDate = now
    let stateBefore = handoffController.stateDescription
    let currentInputSource = inputSourceService.currentInputSource()
    if handoffController.shouldPassThroughShortcut(currentInputSource: currentInputSource) {
      record(
        .shortcut,
        "shortcut passed through because current input source is already Doubao, shortcut=\(shortcut.displayText), handoffState=\(handoffController.stateDescription)"
      )
      return .passThrough
    }

    rememberRestorableInputSource(currentInputSource)
    let actions = handoffController.shortcutBecameActive(
      currentInputSource: currentInputSource,
      fallbackOriginalInputSourceID: lastRestorableInputSourceID
    )
    shortcutStartedFromInputSourceHandoff = actions.contains { action in
      if case .selectDoubaoInputSource = action {
        return true
      }
      return false
    }
    let releasePressKind = handoffController.releasePressKind
    let keyDownForwarding = forwardingPolicy.keyDownForwarding(
      startedFromInputSourceHandoff: shortcutStartedFromInputSourceHandoff,
      releasePressKind: releasePressKind,
      isSuppressionWindowActive: false
    )
    record(
      .shortcut,
      "keyDown \(shortcut.displayText), keys=\(shortcut.storageValue), currentInputSource=\(currentInputSource), fallbackOriginalInputSourceID=\(lastRestorableInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffStateAfter=\(handoffController.stateDescription), startedFromInputSourceHandoff=\(shortcutStartedFromInputSourceHandoff), keyDownForwarding=\(keyDownForwarding)"
    )
    scheduleLongPressThresholdIfNeeded()
    applyHandoffActions(actions, reason: "shortcut keyDown")
    switch keyDownForwarding {
    case .passThrough:
      return .passThrough
    case .startSyntheticHoldKeyDown:
      voiceActivationAttemptStartedAt = now
      record(
        .voiceReadiness,
        "first synthetic keyDown replay scheduled, firstReplayDelayMs=\(voiceActivationRetryPolicy.firstReplayDelayMilliseconds), firstProbeAfterReplayMs=\(voiceActivationRetryPolicy.probeDelayMilliseconds), elapsedSinceAttemptMs=0, handoffState=\(handoffController.stateDescription)"
      )
      return .startSyntheticHoldKeyDown
    case .suppress:
      return .suppress
    }
  }

  private func handleGlobalShortcutKeyUp() -> GlobalHotKeyEventDisposition {
    guard status == .running else {
      return .passThrough
    }

    let now = Date()
    let releasePressKind = handoffController.releasePressKind
    let startedFromInputSourceHandoffBeforeRelease = shortcutStartedFromInputSourceHandoff
    let isSuppressionActive = isShortcutSuppressionActive(at: now)
    let isPairedWithSuppressedKeyDown = pendingSuppressedShortcutKeyUps > 0
    if isPairedWithSuppressedKeyDown {
      pendingSuppressedShortcutKeyUps -= 1
    }
    let pressDurationMilliseconds = shortcutDownDate.map {
      max(0, Int(now.timeIntervalSince($0) * 1000))
    } ?? 0
    let keyUpForwarding = forwardingPolicy.keyUpForwarding(
      startedFromInputSourceHandoff: shortcutStartedFromInputSourceHandoff,
      releasePressKind: releasePressKind,
      pressDurationMilliseconds: pressDurationMilliseconds,
      isSuppressionWindowActive: isSuppressionActive,
      isPairedWithSuppressedKeyDown: isPairedWithSuppressedKeyDown
    )
    if keyUpForwarding == .suppress {
      record(
        .shortcut,
        "shortcut ignored by suppression window event=keyUp, durationMs=\(pressDurationMilliseconds), releasePressKind=\(releasePressKind?.rawValue ?? "none"), pairedWithSuppressedKeyDown=\(isPairedWithSuppressedKeyDown), pendingSuppressedKeyUps=\(pendingSuppressedShortcutKeyUps), handoffState=\(handoffController.stateDescription)"
      )
      return .suppress
    }

    shortcutDownDate = nil
    pendingLongPressWorkItem?.cancel()
    pendingLongPressWorkItem = nil

    let pressKind = releasePressKind?.rawValue ?? "none"
    let stateBefore = handoffController.stateDescription
    let actions = handoffController.shortcutBecameInactive()
    shortcutStartedFromInputSourceHandoff = false
    record(
      .shortcut,
      "keyUp \(storedShortcut.displayText), keys=\(storedShortcut.storageValue), durationMs=\(pressDurationMilliseconds), releasePressKind=\(pressKind), handoffStateBefore=\(stateBefore), handoffStateAfter=\(handoffController.stateDescription), keyUpForwarding=\(keyUpForwarding)"
    )
    applyHandoffActions(actions, reason: "shortcut keyUp")
    showNearThresholdLongPressToastIfNeeded(
      pressDurationMilliseconds: pressDurationMilliseconds,
      releasePressKind: releasePressKind,
      startedFromInputSourceHandoff: startedFromInputSourceHandoffBeforeRelease,
      now: now
    )
    switch keyUpForwarding {
    case .passThrough:
      return .passThrough
    case .suppress:
      return .suppress
    case .storeSyntheticHoldKeyUp:
      startShortcutSuppressionWindow(reason: "storeSyntheticHoldKeyUp", now: now)
      return .storeSyntheticHoldKeyUp
    case .releaseSyntheticHold:
      cancelVoiceActivationProbe()
      return .releaseSyntheticHold
    case .forwardSyntheticKeyUp:
      cancelVoiceActivationProbe()
      return .forwardSyntheticKeyUp
    }
  }

  private func scheduleLongPressThresholdIfNeeded() {
    guard handoffController.isAwaitingLongPressThreshold else {
      return
    }

    let thresholdMilliseconds = handoffController.longPressThresholdMilliseconds
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else {
          return
        }
        self.pendingLongPressWorkItem = nil
        let stateBefore = self.handoffController.stateDescription
        let didTrigger = self.handoffController.shortcutLongPressThresholdReached()
        self.record(
          .shortcut,
          "longPressThresholdReached thresholdMs=\(thresholdMilliseconds), triggered=\(didTrigger), syntheticKeyDownAlreadyForwarded=\(self.shortcutStartedFromInputSourceHandoff), handoffStateBefore=\(stateBefore), handoffStateAfter=\(self.handoffController.stateDescription)"
        )
      }
    }
    pendingLongPressWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(thresholdMilliseconds),
      execute: workItem
    )
  }

  private func handleSyntheticHoldKeyDownReplay(_ event: GlobalHotKeySyntheticReplayLog) {
    let now = Date()
    switch event.reason {
    case .initial:
      firstSyntheticReplaySentAt = now
    case .retry:
      retrySyntheticReplaySentAt = now
    }

    record(
      .voiceReadiness,
      "\(event.message), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), elapsedSinceRetryReplayMs=\(elapsedMilliseconds(since: retrySyntheticReplaySentAt)), handoffState=\(handoffController.stateDescription)"
    )

    guard event.reason == .initial else {
      return
    }

    scheduleVoiceActivationProbe(
      completedRetryCount: 0,
      delayMilliseconds: voiceActivationRetryPolicy.probeDelayMilliseconds
    )
  }

  private func scheduleVoiceActivationProbe(completedRetryCount: Int, delayMilliseconds: Int) {
    pendingVoiceActivationProbeWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runVoiceActivationProbe(completedRetryCount: completedRetryCount)
      }
    }
    pendingVoiceActivationProbeWorkItem = workItem
    record(
      .voiceReadiness,
      "scheduled voice activation probe completedRetryCount=\(completedRetryCount), delayMs=\(delayMilliseconds), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), elapsedSinceRetryReplayMs=\(elapsedMilliseconds(since: retrySyntheticReplaySentAt)), handoffState=\(handoffController.stateDescription)"
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runVoiceActivationProbe(completedRetryCount: Int) {
    pendingVoiceActivationProbeWorkItem = nil

    guard status == .running else {
      record(.voiceReadiness, "voice activation probe skipped because status=\(status.title)")
      return
    }

    let stateBefore = handoffController.stateDescription
    guard inputSourceService.currentInputSource() == .doubao else {
      record(
        .voiceReadiness,
        "voice activation probe cancelled because currentInputSource=\(inputSourceService.currentInputSource()), completedRetryCount=\(completedRetryCount), handoffState=\(stateBefore)"
      )
      restoreInputSourceIfNeeded(reason: "shortClickActivationInputSourceChanged")
      return
    }

    guard handoffController.shouldContinueVoiceActivationProbe else {
      record(
        .voiceReadiness,
        "voice activation probe skipped because handoffState=\(stateBefore), completedRetryCount=\(completedRetryCount)"
      )
      return
    }

    let isRunningInput = audioInputProbe.isRunningInput()
    record(
      .voiceReadiness,
      "voice activation probe result isRunningInput=\(isRunningInput), completedRetryCount=\(completedRetryCount), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), elapsedSinceRetryReplayMs=\(elapsedMilliseconds(since: retrySyntheticReplaySentAt)), handoffState=\(stateBefore)"
    )
    switch voiceActivationRetryPolicy.decision(
      isRunningInput: isRunningInput,
      completedRetryCount: completedRetryCount
    ) {
    case .confirmed:
      record(
        .voiceReadiness,
        "voice activation confirmed completedRetryCount=\(completedRetryCount), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), elapsedSinceRetryReplayMs=\(elapsedMilliseconds(since: retrySyntheticReplaySentAt)), handoffState=\(stateBefore)"
      )
      clearVoiceActivationTracking()
    case let .retry(retryNumber, retryKeyDownDelayMilliseconds, nextProbeDelayMilliseconds):
      retryVoiceActivation(
        retryNumber: retryNumber,
        retryKeyDownDelayMilliseconds: retryKeyDownDelayMilliseconds,
        nextProbeDelayMilliseconds: nextProbeDelayMilliseconds
      )
    case .failed:
      failVoiceActivation(
        reason: "voiceActivationProbeFailed",
        completedRetryCount: completedRetryCount
      )
    }
  }

  private func retryVoiceActivation(
    retryNumber: Int,
    retryKeyDownDelayMilliseconds: Int,
    nextProbeDelayMilliseconds: Int
  ) {
    let resetResult = hotKeyService.resetSyntheticHoldForRetry()
    record(
      .voiceReadiness,
      "voice activation retry reset started retryNumber=\(retryNumber), \(resetResult.message), retryKeyDownDelayMs=\(retryKeyDownDelayMilliseconds), nextProbeDelayMs=\(nextProbeDelayMilliseconds), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), handoffState=\(handoffController.stateDescription)"
    )
    guard resetResult.hadKeyDownTemplate else {
      failVoiceActivation(reason: "voiceActivationRetryKeyDownTemplateMissing", completedRetryCount: retryNumber - 1)
      return
    }

    pendingVoiceActivationRetryKeyDownWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.sendVoiceActivationRetryKeyDown(
          retryNumber: retryNumber,
          nextProbeDelayMilliseconds: nextProbeDelayMilliseconds
        )
      }
    }
    pendingVoiceActivationRetryKeyDownWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(retryKeyDownDelayMilliseconds),
      execute: workItem
    )
  }

  private func sendVoiceActivationRetryKeyDown(
    retryNumber: Int,
    nextProbeDelayMilliseconds: Int
  ) {
    pendingVoiceActivationRetryKeyDownWorkItem = nil
    guard status == .running,
          inputSourceService.currentInputSource() == .doubao,
          handoffController.shouldContinueVoiceActivationProbe else {
      record(
        .voiceReadiness,
        "voice activation retry keyDown cancelled retryNumber=\(retryNumber), currentInputSource=\(inputSourceService.currentInputSource()), handoffState=\(handoffController.stateDescription)"
      )
      return
    }

    let didSendKeyDown = hotKeyService.retrySyntheticHoldKeyDown()
    record(
      .voiceReadiness,
      "voice activation retry rebuilt keyDown sent retryNumber=\(retryNumber), didSend=\(didSendKeyDown), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), handoffState=\(handoffController.stateDescription)"
    )
    guard didSendKeyDown else {
      failVoiceActivation(reason: "voiceActivationRetryKeyDownMissing", completedRetryCount: retryNumber)
      return
    }

    scheduleVoiceActivationProbe(
      completedRetryCount: retryNumber,
      delayMilliseconds: nextProbeDelayMilliseconds
    )
  }

  private func failVoiceActivation(reason: String, completedRetryCount: Int) {
    cancelVoiceActivationProbe()
    let didRelease = hotKeyService.releaseSyntheticHoldIfNeeded()
    record(
      .voiceReadiness,
      "voice activation failed; restoring input source and asking user to retry, reason=\(reason), completedRetryCount=\(completedRetryCount), releasedSyntheticHold=\(didRelease), elapsedSinceAttemptMs=\(elapsedMilliseconds(since: voiceActivationAttemptStartedAt)), elapsedSinceFirstReplayMs=\(elapsedMilliseconds(since: firstSyntheticReplaySentAt)), elapsedSinceRetryReplayMs=\(elapsedMilliseconds(since: retrySyntheticReplaySentAt)), handoffState=\(handoffController.stateDescription)"
    )
    lastMessage = "豆包未启动，请再按一次"
    shortcutStartedFromInputSourceHandoff = false
    shortcutDownDate = nil
    applyHandoffActions(handoffController.cancelHandoff(), reason: reason)
    clearVoiceActivationTracking()
    toastPresenter.show(
      message: "豆包未启动，请再按一次",
      durationMilliseconds: voiceActivationFailureToastMilliseconds
    )
  }

  private func cancelVoiceActivationProbe() {
    pendingVoiceActivationProbeWorkItem?.cancel()
    pendingVoiceActivationProbeWorkItem = nil
    pendingVoiceActivationRetryKeyDownWorkItem?.cancel()
    pendingVoiceActivationRetryKeyDownWorkItem = nil
  }

  private func clearVoiceActivationTracking() {
    voiceActivationAttemptStartedAt = nil
    firstSyntheticReplaySentAt = nil
    retrySyntheticReplaySentAt = nil
  }

  private func elapsedMilliseconds(since date: Date?) -> Int {
    guard let date else {
      return -1
    }

    return max(0, Int(Date().timeIntervalSince(date) * 1000))
  }

  private func showNearThresholdLongPressToastIfNeeded(
    pressDurationMilliseconds: Int,
    releasePressKind: InputSourcePressKind?,
    startedFromInputSourceHandoff: Bool,
    now: Date
  ) {
    let thresholdMilliseconds = handoffController.longPressThresholdMilliseconds
    guard releasePressKind == .long,
          startedFromInputSourceHandoff,
          LongPressThresholdPreference.isNearThresholdLongPress(
            pressDurationMilliseconds: pressDurationMilliseconds,
            thresholdMilliseconds: thresholdMilliseconds
          )
    else {
      return
    }

    let cooldownSeconds = Double(nearThresholdLongPressToastCooldownMilliseconds) / 1000
    if let lastDate = lastNearThresholdLongPressToastDate,
       now.timeIntervalSince(lastDate) < cooldownSeconds {
      record(
        .shortcut,
        "near-threshold long press hint suppressed by cooldown, durationMs=\(pressDurationMilliseconds), thresholdMs=\(thresholdMilliseconds), toleranceMs=\(LongPressThresholdPreference.nearThresholdHintToleranceMilliseconds)"
      )
      return
    }

    lastNearThresholdLongPressToastDate = now
    toastPresenter.show(
      message: "本次识别为长按，可以在设置增大长按判断时长",
      durationMilliseconds: nearThresholdLongPressToastMilliseconds
    )
    record(
      .shortcut,
      "near-threshold long press hint shown, durationMs=\(pressDurationMilliseconds), thresholdMs=\(thresholdMilliseconds), toleranceMs=\(LongPressThresholdPreference.nearThresholdHintToleranceMilliseconds)"
    )
  }

  private func isShortcutSuppressionActive(at now: Date) -> Bool {
    guard let shortcutSuppressionUntil else {
      return false
    }

    if now < shortcutSuppressionUntil {
      return true
    }

    self.shortcutSuppressionUntil = nil
    return false
  }

  private func startShortcutSuppressionWindow(reason: String, now: Date) {
    shortcutSuppressionUntil = now.addingTimeInterval(Double(shortcutSuppressionMilliseconds) / 1000)
    record(
      .shortcut,
      "started shortcut suppression window durationMs=\(shortcutSuppressionMilliseconds), reason=\(reason)"
    )
  }

  private func applyHandoffActions(_ actions: [InputSourceHandoffAction], reason: String) {
    for action in actions {
      switch action {
      case .selectDoubaoInputSource:
        do {
          try inputSourceService.selectDoubaoInputSource()
          isInputSourceHandoffActive = true
          lastFailureMessage = nil
          lastMessage = "已切换到豆包输入法"
          record(
            .inputSource,
            "handoff selected Doubao input source, currentInputSourceAfterSelect=\(inputSourceService.currentInputSource()), reason=\(reason)"
          )
        } catch {
          lastFailureMessage = String(describing: error)
          lastMessage = "切换豆包输入法失败"
          record(.inputSource, "handoff select Doubao failed: \(error), reason=\(reason)")
        }
      case let .scheduleRestoreInputSource(inputSourceID, delayMilliseconds, restoreReason):
        scheduleRestoreInputSource(
          inputSourceID,
          delayMilliseconds: delayMilliseconds,
          reason: reason,
          restoreReason: restoreReason
        )
      }
    }
  }

  private func scheduleRestoreInputSource(
    _ inputSourceID: String,
    delayMilliseconds: Int,
    reason: String,
    restoreReason: InputSourceRestoreReason
  ) {
    pendingRestoreWorkItem?.cancel()
    if shouldMonitorVoiceEndRestore(restoreReason) {
      scheduleVoiceEndRestoreInputSource(
        inputSourceID,
        initialDelayMilliseconds: delayMilliseconds,
        reason: reason,
        restoreReason: restoreReason
      )
      return
    }

    scheduleFixedRestoreInputSource(
      inputSourceID,
      delayMilliseconds: delayMilliseconds,
      reason: reason,
      restoreReason: restoreReason
    )
  }

  private func scheduleFixedRestoreInputSource(
    _ inputSourceID: String,
    delayMilliseconds: Int,
    reason: String,
    restoreReason: InputSourceRestoreReason
  ) {
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.restoreInputSource(inputSourceID, reason: reason)
      }
    }
    pendingRestoreWorkItem = workItem
    record(
      .inputSource,
      "scheduled restore input source \(inputSourceID), delayMs=\(delayMilliseconds), restoreReason=\(restoreReason.rawValue), reason=\(reason)"
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func shouldMonitorVoiceEndRestore(_ restoreReason: InputSourceRestoreReason) -> Bool {
    switch restoreReason {
    case .longPressRelease, .secondShortClickRelease:
      return true
    case .cancelHandoff:
      return false
    }
  }

  private func scheduleVoiceEndRestoreInputSource(
    _ inputSourceID: String,
    initialDelayMilliseconds: Int,
    reason: String,
    restoreReason: InputSourceRestoreReason
  ) {
    let startedAt = Date()
    record(
      .restoration,
      "voice end restore monitor scheduled, targetInputSourceID=\(inputSourceID), initialDelayMs=\(initialDelayMilliseconds), minimumDelayMs=\(voiceEndRestorePolicy.minimumDelayMilliseconds), maximumDelayMs=\(voiceEndRestorePolicy.maximumDelayMilliseconds), probeElapsedMs=\(voiceEndRestorePolicy.probeElapsedMilliseconds.map(String.init).joined(separator: "/")), restoreReason=\(restoreReason.rawValue), reason=\(reason)"
    )
    scheduleVoiceEndRestoreProbe(
      inputSourceID,
      reason: reason,
      restoreReason: restoreReason,
      startedAt: startedAt,
      expectedElapsedMilliseconds: 0,
      delayMilliseconds: 0
    )
  }

  private func scheduleVoiceEndRestoreProbe(
    _ inputSourceID: String,
    reason: String,
    restoreReason: InputSourceRestoreReason,
    startedAt: Date,
    expectedElapsedMilliseconds: Int,
    delayMilliseconds: Int
  ) {
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runVoiceEndRestoreProbe(
          inputSourceID,
          reason: reason,
          restoreReason: restoreReason,
          startedAt: startedAt,
          expectedElapsedMilliseconds: expectedElapsedMilliseconds
        )
      }
    }
    pendingRestoreWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runVoiceEndRestoreProbe(
    _ inputSourceID: String,
    reason: String,
    restoreReason: InputSourceRestoreReason,
    startedAt: Date,
    expectedElapsedMilliseconds: Int
  ) {
    pendingRestoreWorkItem = nil
    let actualElapsedMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    let decisionElapsedMilliseconds = max(expectedElapsedMilliseconds, actualElapsedMilliseconds)
    let isRunningInput = audioInputProbe.isRunningInput()
    let currentInputSource = inputSourceService.currentInputSource()
    let decision = voiceEndRestorePolicy.decision(
      elapsedMilliseconds: decisionElapsedMilliseconds,
      isRunningInput: isRunningInput
    )
    record(
      .restoration,
      "voice end restore probe, targetInputSourceID=\(inputSourceID), restoreReason=\(restoreReason.rawValue), expectedElapsedMs=\(expectedElapsedMilliseconds), actualElapsedMs=\(actualElapsedMilliseconds), decisionElapsedMs=\(decisionElapsedMilliseconds), runningInput=\(isRunningInput), currentInputSource=\(currentInputSource), decision=\(decision.logDescription), minimumDelayMs=\(voiceEndRestorePolicy.minimumDelayMilliseconds), maximumDelayMs=\(voiceEndRestorePolicy.maximumDelayMilliseconds), reason=\(reason)"
    )

    switch decision {
    case let .restore(restoreTrigger):
      record(
        .restoration,
        "voice end restore proceeding, targetInputSourceID=\(inputSourceID), restoreReason=\(restoreReason.rawValue), restoreTrigger=\(restoreTrigger.rawValue), elapsedMs=\(decisionElapsedMilliseconds), runningInput=\(isRunningInput), reason=\(reason)"
      )
      restoreInputSource(inputSourceID, reason: reason)
    case let .continueProbing(nextProbeElapsedMilliseconds):
      scheduleVoiceEndRestoreProbe(
        inputSourceID,
        reason: reason,
        restoreReason: restoreReason,
        startedAt: startedAt,
        expectedElapsedMilliseconds: nextProbeElapsedMilliseconds,
        delayMilliseconds: max(0, nextProbeElapsedMilliseconds - decisionElapsedMilliseconds)
      )
    }
  }

  private func restoreInputSource(_ inputSourceID: String, reason: String) {
    pendingRestoreWorkItem = nil
    do {
      try inputSourceService.restoreInputSource(id: inputSourceID)
      lastRestorableInputSourceID = inputSourceID
      isInputSourceHandoffActive = false
      lastFailureMessage = nil
      lastMessage = "已恢复原输入法"
      record(.inputSource, "restored input source \(inputSourceID), reason=\(reason)")
    } catch {
      isInputSourceHandoffActive = false
      lastFailureMessage = String(describing: error)
      lastMessage = "恢复原输入法失败"
      record(.inputSource, "restore input source failed: \(error), id=\(inputSourceID), reason=\(reason)")
    }
  }

  private var storedShortcut: DoubaoShortcut {
    DoubaoShortcut(storageValue: UserDefaults.standard.string(forKey: "doubaoShortcutKeys"))
  }

  private func loadLongPressThresholdPreference() {
    let storedMilliseconds = UserDefaults.standard.object(forKey: LongPressThresholdPreference.storageKey) as? Int
      ?? LongPressThresholdPreference.defaultMilliseconds
    let clampedMilliseconds = LongPressThresholdPreference.clamped(storedMilliseconds)
    UserDefaults.standard.set(clampedMilliseconds, forKey: LongPressThresholdPreference.storageKey)
    handoffController.updateLongPressThresholdMilliseconds(clampedMilliseconds)
  }

  private func rememberRestorableInputSource(_ inputSource: InputSourceIdentity) {
    guard let inputSourceID = inputSource.restorationID, !inputSourceID.isEmpty else {
      return
    }
    lastRestorableInputSourceID = inputSourceID
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

private extension VoiceEndRestoreDecision {
  var logDescription: String {
    switch self {
    case let .continueProbing(nextProbeElapsedMilliseconds):
      return "continueProbing(nextProbeElapsedMs=\(nextProbeElapsedMilliseconds))"
    case let .restore(reason):
      return "restore(reason=\(reason.rawValue))"
    }
  }
}
