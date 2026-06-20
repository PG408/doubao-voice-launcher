import AppKit
import DoubaoVoiceLauncherCore
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
  private let handoffController = InputSourceHandoffController()
  private let forwardingPolicy = ShortcutEventForwardingPolicy()
  private let launchAtLoginService = LaunchAtLoginService()

  private var readinessTimer: Timer?
  private var registeredShortcut: DoubaoShortcut?
  private var pendingRestoreWorkItem: DispatchWorkItem?
  private var pendingLongPressWorkItem: DispatchWorkItem?
  private var shortcutDownDate: Date?
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

  var diagnosticSummary: String {
    [
      "DoubaoVoiceLauncher Diagnostic Summary",
      "Status: \(status.title)",
      "Accessibility: \(accessibilityTrusted)",
      "Doubao input source: \(doubaoInputSourceAvailable)",
      "Shortcut: \(storedShortcut.displayText)",
      "Long press threshold: \(handoffController.longPressThresholdMilliseconds) ms",
      "Input source handoff active: \(isInputSourceHandoffActive)",
      "Last message: \(lastMessage)",
      "Last failure: \(lastFailureMessage ?? "none")",
      "Log directory: \(logDirectory.path)",
      "Next action: \(nextDiagnosticAction)"
    ].joined(separator: "\n")
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

  func copyDiagnosticSummary() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(diagnosticSummary, forType: .string)
    lastMessage = "诊断摘要已复制"
    record(.app, "diagnostic summary copied")
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
    applyHandoffActions(handoffController.cancelHandoff(), reason: reason)
  }

  private func configureHotKeyCallbacks() {
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

  private var nextDiagnosticAction: String {
    if !accessibilityTrusted {
      return "Manually grant Accessibility permission to DoubaoVoiceLauncher."
    }
    if !doubaoInputSourceAvailable {
      return "Install and enable the Doubao input source."
    }
    if status == .paused {
      return "Resume the app before testing the shortcut."
    }
    return "Test the configured shortcut and let Doubao handle voice input."
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

    pendingRestoreWorkItem?.cancel()
    pendingRestoreWorkItem = nil
    pendingLongPressWorkItem?.cancel()
    pendingLongPressWorkItem = nil
    shortcutDownDate = Date()
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
    record(
      .shortcut,
      "keyDown \(shortcut.displayText), keys=\(shortcut.storageValue), currentInputSource=\(currentInputSource), fallbackOriginalInputSourceID=\(lastRestorableInputSourceID ?? "none"), handoffStateBefore=\(stateBefore), handoffStateAfter=\(handoffController.stateDescription), startedFromInputSourceHandoff=\(shortcutStartedFromInputSourceHandoff), keyDownForwarding=\(forwardingPolicy.keyDownForwarding(startedFromInputSourceHandoff: shortcutStartedFromInputSourceHandoff))"
    )
    scheduleLongPressThresholdIfNeeded()
    applyHandoffActions(actions, reason: "shortcut keyDown")
    switch forwardingPolicy.keyDownForwarding(startedFromInputSourceHandoff: shortcutStartedFromInputSourceHandoff) {
    case .passThrough:
      return .passThrough
    case .captureForSyntheticForwarding:
      return .captureForSyntheticForwarding
    }
  }

  private func handleGlobalShortcutKeyUp() -> GlobalHotKeyEventDisposition {
    guard status == .running else {
      return .passThrough
    }

    let now = Date()
    let pressDurationMilliseconds = shortcutDownDate.map {
      max(0, Int(now.timeIntervalSince($0) * 1000))
    } ?? 0
    shortcutDownDate = nil
    pendingLongPressWorkItem?.cancel()
    pendingLongPressWorkItem = nil

    let releasePressKind = handoffController.releasePressKind
    let keyUpForwarding = forwardingPolicy.keyUpForwarding(
      startedFromInputSourceHandoff: shortcutStartedFromInputSourceHandoff,
      releasePressKind: releasePressKind,
      pressDurationMilliseconds: pressDurationMilliseconds
    )
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
    case let .replayTap(preflightKeyUpDelayMilliseconds, keyUpGapMilliseconds):
      return .replaySyntheticTap(
        preflightKeyUpDelayMilliseconds: preflightKeyUpDelayMilliseconds,
        keyUpGapMilliseconds: keyUpGapMilliseconds
      )
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
    .appendingPathComponent("DoubaoVoiceLauncher", isDirectory: true)
    .appendingPathComponent("Logs", isDirectory: true)
}
