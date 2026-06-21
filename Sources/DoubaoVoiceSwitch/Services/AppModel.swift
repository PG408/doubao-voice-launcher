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
  private let launchAtLoginService = LaunchAtLoginService()
  private let shortcutSuppressionMilliseconds = 300
  private let shortClickFirstWatchdogMilliseconds = 500
  private let shortClickRetryWatchdogMilliseconds = 1000
  private let shortClickRetryResetMilliseconds = 100

  private var readinessTimer: Timer?
  private var registeredShortcut: DoubaoShortcut?
  private var pendingRestoreWorkItem: DispatchWorkItem?
  private var pendingLongPressWorkItem: DispatchWorkItem?
  private var pendingShortClickActivationWatchdogWorkItem: DispatchWorkItem?
  private var shortcutDownDate: Date?
  private var shortcutSuppressionUntil: Date?
  private var pendingSuppressedShortcutKeyUps = 0
  private var shortcutStartedFromInputSourceHandoff = false
  private var lastRestorableInputSourceID: String?
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
    pendingShortClickActivationWatchdogWorkItem?.cancel()
    pendingShortClickActivationWatchdogWorkItem = nil
    if hotKeyService.releaseSyntheticHoldIfNeeded() {
      record(.shortcut, "released synthetic hold, releaseReason=\(reason)")
    }
    applyHandoffActions(handoffController.cancelHandoff(), reason: reason)
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
    pendingShortClickActivationWatchdogWorkItem?.cancel()
    pendingShortClickActivationWatchdogWorkItem = nil
    shortcutDownDate = now
    let stateBefore = handoffController.stateDescription
    let currentInputSource = inputSourceService.currentInputSource()
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
    case .captureForSyntheticForwarding:
      return .captureForSyntheticForwarding
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
    switch keyUpForwarding {
    case .passThrough:
      return .passThrough
    case .suppress:
      return .suppress
    case .startSyntheticHold:
      startShortcutSuppressionWindow(reason: "startSyntheticHold", now: now)
      scheduleShortClickActivationWatchdog(
        attempt: 1,
        delayMilliseconds: shortClickFirstWatchdogMilliseconds
      )
      return .startSyntheticHold
    case .releaseSyntheticHold:
      return .releaseSyntheticHold
    case .forwardSyntheticKeyUp:
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
        let didForwardKeyDown = didTrigger && self.shortcutStartedFromInputSourceHandoff
          ? self.hotKeyService.forwardCapturedKeyDown()
          : false
        if didForwardKeyDown {
          self.startShortcutSuppressionWindow(reason: "longPressSyntheticKeyDown", now: Date())
        }
        self.record(
          .shortcut,
          "longPressThresholdReached thresholdMs=\(thresholdMilliseconds), triggered=\(didTrigger), syntheticKeyDownForwarded=\(didForwardKeyDown), handoffStateBefore=\(stateBefore), handoffStateAfter=\(self.handoffController.stateDescription)"
        )
      }
    }
    pendingLongPressWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(thresholdMilliseconds),
      execute: workItem
    )
  }

  private func scheduleShortClickActivationWatchdog(attempt: Int, delayMilliseconds: Int) {
    pendingShortClickActivationWatchdogWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.runShortClickActivationWatchdog(attempt: attempt)
      }
    }
    pendingShortClickActivationWatchdogWorkItem = workItem
    record(
      .voiceReadiness,
      "scheduled short click activation watchdog attempt=\(attempt), delayMs=\(delayMilliseconds), handoffState=\(handoffController.stateDescription)"
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func runShortClickActivationWatchdog(attempt: Int) {
    pendingShortClickActivationWatchdogWorkItem = nil

    guard status == .running else {
      record(.voiceReadiness, "short click activation watchdog skipped because status=\(status.title)")
      return
    }

    let stateBefore = handoffController.stateDescription
    guard inputSourceService.currentInputSource() == .doubao else {
      record(
        .voiceReadiness,
        "short click activation watchdog cancelled because currentInputSource=\(inputSourceService.currentInputSource()), attempt=\(attempt), handoffState=\(stateBefore)"
      )
      restoreInputSourceIfNeeded(reason: "shortClickActivationInputSourceChanged")
      return
    }

    if audioInputProbe.isRunningInput() {
      record(
        .voiceReadiness,
        "short click activation confirmed attempt=\(attempt), handoffState=\(stateBefore)"
      )
      return
    }

    if attempt == 1,
       let retryAction = handoffController.retryShortClickActivationIfNeeded() {
      let didRelease = hotKeyService.releaseSyntheticHoldIfNeeded()
      record(
        .voiceReadiness,
        "short click activation missed; retrying with captured synthetic hold template, attempt=\(attempt), retryAction=\(retryAction), releasedPreviousHold=\(didRelease), handoffStateBefore=\(stateBefore), handoffStateAfter=\(handoffController.stateDescription)"
      )
      scheduleShortClickActivationRetryKeyDown(action: retryAction)
      return
    }

    let didRelease = hotKeyService.releaseSyntheticHoldIfNeeded()
    record(
      .voiceReadiness,
      "short click activation failed; restoring input source, attempt=\(attempt), releasedSyntheticHold=\(didRelease), handoffState=\(handoffController.stateDescription)"
    )
    applyHandoffActions(handoffController.cancelHandoff(), reason: "short click activation watchdog")
  }

  private func scheduleShortClickActivationRetryKeyDown(action: InputSourceShortcutRetryAction) {
    pendingShortClickActivationWatchdogWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.sendShortClickActivationRetryKeyDown(action: action)
      }
    }
    pendingShortClickActivationWatchdogWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(shortClickRetryResetMilliseconds),
      execute: workItem
    )
  }

  private func sendShortClickActivationRetryKeyDown(action: InputSourceShortcutRetryAction) {
    pendingShortClickActivationWatchdogWorkItem = nil
    guard status == .running, inputSourceService.currentInputSource() == .doubao else {
      record(
        .voiceReadiness,
        "short click activation retry stopped before keyDown, currentInputSource=\(inputSourceService.currentInputSource()), handoffState=\(handoffController.stateDescription)"
      )
      restoreInputSourceIfNeeded(reason: "shortClickActivationRetryStopped")
      return
    }

    let didStart: Bool
    switch action {
    case .restartSyntheticHoldFromCapturedTemplate:
      didStart = hotKeyService.restartSyntheticHoldFromCapturedTemplate()
    }
    startShortcutSuppressionWindow(reason: "shortClickRetrySyntheticKeyDown", now: Date())
    record(
      .voiceReadiness,
      "short click activation retry keyDown sent, retryAction=\(action), didStart=\(didStart), handoffState=\(handoffController.stateDescription)"
    )
    scheduleShortClickActivationWatchdog(
      attempt: 2,
      delayMilliseconds: shortClickRetryWatchdogMilliseconds
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
