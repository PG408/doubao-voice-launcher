import ApplicationServices
import DoubaoVoiceSwitchCore
import Foundation

final class GlobalHotKeyService {
  var onKeyDown: ((DoubaoShortcut) -> GlobalHotKeyEventDisposition)?
  var onKeyUp: (() -> GlobalHotKeyEventDisposition)?
  var onShortcutEventObserved: ((GlobalHotKeyEventLog) -> Void)?
  var onSyntheticHoldKeyDownReplay: ((GlobalHotKeySyntheticReplayLog) -> Void)?
  var syntheticHoldKeyDownDelayMilliseconds = 0
  // Gap between the synthetic release and the following keyDown. Posting them
  // back-to-back lets Doubao coalesce them into a no-op, so the fresh press edge
  // is dropped intermittently. A short gap makes the up -> down edge reliable.
  var syntheticHoldEdgeGapMilliseconds = 25

  fileprivate static let delayedReplayUserData: Int64 = 0x4442_564c_4b55_5001
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: DoubaoShortcut?
  private var isShortcutDown = false
  private var activeKeys: Set<DoubaoShortcutKey> = []
  private var syntheticHoldKeyDownTemplate: CGEvent?
  private var syntheticHoldKeyUpTemplate: CGEvent?
  private var syntheticHoldKeyUpEvents: [CGEvent] = []
  private var pendingSyntheticHoldKeyDownWorkItem: DispatchWorkItem?
  private var pendingSyntheticHoldKeyDownEvent: CGEvent?
  private var syntheticHoldKeyDownWasSent = false

  deinit {
    unregister()
  }

  func register(shortcut: DoubaoShortcut) throws {
    unregister()
    self.shortcut = shortcut

    let mask =
      (1 << CGEventType.flagsChanged.rawValue)

    guard let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: { _, type, event, userData in
        guard let userData else {
          return Unmanaged.passUnretained(event)
        }

        let service = Unmanaged<GlobalHotKeyService>
          .fromOpaque(userData)
          .takeUnretainedValue()

        return service.handle(type: type, event: event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      throw GlobalHotKeyError.eventTapInstallFailed
    }

    self.eventTap = eventTap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.runLoopSource = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  func unregister() {
    releaseSyntheticHoldIfNeeded()
    cancelPendingSyntheticHoldKeyDownReplay()
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }

    if let eventTap {
      CFMachPortInvalidate(eventTap)
      self.eventTap = nil
    }

    shortcut = nil
    isShortcutDown = false
    activeKeys = []
    syntheticHoldKeyDownTemplate = nil
    syntheticHoldKeyUpTemplate = nil
    syntheticHoldKeyUpEvents = []
    syntheticHoldKeyDownWasSent = false
  }

  @discardableResult
  func releaseSyntheticHoldIfNeeded() -> Bool {
    releaseSyntheticHold().sentSyntheticKeyUp
  }

  private func releaseSyntheticHold() -> GlobalHotKeySyntheticResetResult {
    let hadKeyDownTemplate = syntheticHoldKeyDownTemplate != nil
    let hadPendingReplay = pendingSyntheticHoldKeyDownWorkItem != nil
      || pendingSyntheticHoldKeyDownEvent != nil
    let keyDownWasSent = syntheticHoldKeyDownWasSent

    cancelPendingSyntheticHoldKeyDownReplay()

    guard !syntheticHoldKeyUpEvents.isEmpty, keyDownWasSent else {
      syntheticHoldKeyUpEvents = []
      syntheticHoldKeyUpTemplate = nil
      syntheticHoldKeyDownTemplate = nil
      syntheticHoldKeyDownWasSent = false
      return GlobalHotKeySyntheticResetResult(
        hadKeyDownTemplate: hadKeyDownTemplate,
        hadPendingReplay: hadPendingReplay,
        keyDownWasSent: keyDownWasSent,
        sentSyntheticKeyUp: false,
        clearedTracking: true
      )
    }

    let keyUpEvents = syntheticHoldKeyUpEvents
    syntheticHoldKeyUpEvents = []
    syntheticHoldKeyUpTemplate = nil
    syntheticHoldKeyDownTemplate = nil
    syntheticHoldKeyDownWasSent = false
    for event in keyUpEvents {
      event.post(tap: .cghidEventTap)
    }
    return GlobalHotKeySyntheticResetResult(
      hadKeyDownTemplate: hadKeyDownTemplate,
      hadPendingReplay: hadPendingReplay,
      keyDownWasSent: keyDownWasSent,
      sentSyntheticKeyUp: true,
      clearedTracking: true
    )
  }

  private func cancelPendingSyntheticHoldKeyDownReplay() {
    pendingSyntheticHoldKeyDownWorkItem?.cancel()
    pendingSyntheticHoldKeyDownWorkItem = nil
    pendingSyntheticHoldKeyDownEvent = nil
  }

  @discardableResult
  private func postSyntheticHoldKeyDown(
    _ event: CGEvent,
    delayMilliseconds: Int
  ) -> Bool {
    guard let replayKeyDownEvent = event.copy() else {
      return false
    }

    // The physical modifier is already held from before the input-source switch,
    // so Doubao never sees a fresh "press" edge. Post a synthetic release first to
    // clear the held state, then the keyDown re-asserts it — giving Doubao a clean
    // up -> down edge that actually triggers its voice hotkey. The two events must
    // be separated by a short gap, otherwise Doubao coalesces them and the edge is
    // lost (the "sometimes works" symptom).
    let gapMilliseconds = max(0, syntheticHoldEdgeGapMilliseconds)
    if let releaseEvent = makeSyntheticReleaseEvent(from: replayKeyDownEvent) {
      releaseEvent.post(tap: .cghidEventTap)
      guard gapMilliseconds > 0 else {
        return postSyntheticHoldKeyDownEvent(replayKeyDownEvent, delayMilliseconds: delayMilliseconds)
      }

      // Mark as sent up-front so a release/reset arriving during the gap still
      // knows a keyDown is in flight.
      syntheticHoldKeyDownWasSent = true
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(gapMilliseconds)) { [weak self] in
        guard let self else { return }
        _ = self.postSyntheticHoldKeyDownEvent(replayKeyDownEvent, delayMilliseconds: delayMilliseconds)
      }
      return true
    }

    return postSyntheticHoldKeyDownEvent(replayKeyDownEvent, delayMilliseconds: delayMilliseconds)
  }

  @discardableResult
  private func postSyntheticHoldKeyDownEvent(
    _ replayKeyDownEvent: CGEvent,
    delayMilliseconds: Int
  ) -> Bool {
    replayKeyDownEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    syntheticHoldKeyDownWasSent = true
    replayKeyDownEvent.post(tap: .cghidEventTap)
    onSyntheticHoldKeyDownReplay?(replayKeyDownEvent.syntheticReplayLog(
      delayMilliseconds: delayMilliseconds,
      sent: true
    ))
    return true
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged else {
      return Unmanaged.passUnretained(event)
    }

    guard let shortcut else {
      return Unmanaged.passUnretained(event)
    }

    guard DoubaoShortcutKey.key(forKeyCode: event.keyCode) != nil else {
      return Unmanaged.passUnretained(event)
    }

    if event.isDelayedReplayEvent {
      onShortcutEventObserved?(event.logEvent(
        type: type,
        activeKeys: activeKeys,
        isActiveShortcut: shortcut.matches(activeKeys: activeKeys),
        isShortcutDown: isShortcutDown,
        note: "ignoredDelayedReplay"
      ))
      return Unmanaged.passUnretained(event)
    }

    updateActiveKeys(event: event)
    let isActiveShortcut = shortcut.matches(activeKeys: activeKeys)
    onShortcutEventObserved?(event.logEvent(
      type: type,
      activeKeys: activeKeys,
      isActiveShortcut: isActiveShortcut,
      isShortcutDown: isShortcutDown,
      note: nil
    ))

    if isActiveShortcut, !isShortcutDown {
      isShortcutDown = true
      return event.handle(disposition: onKeyDown?(shortcut) ?? .passThrough, service: self)
    }

    if isShortcutDown, !isActiveShortcut {
      isShortcutDown = false
      return event.handle(disposition: onKeyUp?() ?? .passThrough, service: self)
    }

    return Unmanaged.passUnretained(event)
  }

  private func updateActiveKeys(event: CGEvent) {
    guard let key = DoubaoShortcutKey.key(forKeyCode: event.keyCode) else {
      return
    }

    if key == .function {
      updateActiveKey(key, isActive: event.flags.contains(.maskSecondaryFn))
      return
    }

    if activeKeys.contains(key) {
      activeKeys.remove(key)
    } else if let modifier = key.modifier, ShortcutModifiers(event.flags).contains(modifier) {
      activeKeys.insert(key)
    }
  }

  private func updateActiveKey(_ key: DoubaoShortcutKey, isActive: Bool) {
    if isActive {
      activeKeys.insert(key)
    } else {
      activeKeys.remove(key)
    }
  }

  fileprivate func handle(disposition: GlobalHotKeyEventDisposition, event: CGEvent) -> Unmanaged<CGEvent>? {
    switch disposition {
    case .passThrough:
      return Unmanaged.passUnretained(event)
    case .startSyntheticHoldKeyDown:
      startSyntheticHoldKeyDown(event)
      return nil
    case .suppress:
      return nil
    case .storeSyntheticHoldKeyUp:
      storeSyntheticHoldKeyUp(event)
      return nil
    case .releaseSyntheticHold:
      releaseSyntheticHold(fallbackKeyUpEvent: event)
      return nil
    case .forwardSyntheticKeyUp:
      forwardSyntheticKeyUp(event)
      return nil
    }
  }

  private func startSyntheticHoldKeyDown(_ event: CGEvent) {
    guard let replayKeyDownEvent = event.copy() else {
      return
    }

    replayKeyDownEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    syntheticHoldKeyDownTemplate = replayKeyDownEvent.copy()
    syntheticHoldKeyUpTemplate = makeSyntheticReleaseEvent(from: event)
    if let keyUpEvent = syntheticHoldKeyUpTemplate?.copy() {
      syntheticHoldKeyUpEvents = [keyUpEvent]
    }
    syntheticHoldKeyDownWasSent = false

    let delayMilliseconds = syntheticHoldKeyDownDelayMilliseconds
    guard delayMilliseconds > 0 else {
      _ = postSyntheticHoldKeyDown(
        replayKeyDownEvent,
        delayMilliseconds: 0
      )
      return
    }

    cancelPendingSyntheticHoldKeyDownReplay()
    pendingSyntheticHoldKeyDownEvent = replayKeyDownEvent
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, let event = self.pendingSyntheticHoldKeyDownEvent else {
        return
      }
      self.pendingSyntheticHoldKeyDownWorkItem = nil
      self.pendingSyntheticHoldKeyDownEvent = nil
      _ = self.postSyntheticHoldKeyDown(
        event,
        delayMilliseconds: delayMilliseconds
      )
    }
    pendingSyntheticHoldKeyDownWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func storeSyntheticHoldKeyUp(_ event: CGEvent) {
    guard let replayKeyUpEvent = event.copy() else {
      return
    }

    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    syntheticHoldKeyUpTemplate = replayKeyUpEvent.copy()
    syntheticHoldKeyUpEvents = [replayKeyUpEvent]
  }

  private func releaseSyntheticHold(fallbackKeyUpEvent: CGEvent) {
    if releaseSyntheticHoldIfNeeded() {
      return
    }

    guard let replayKeyUpEvent = fallbackKeyUpEvent.copy() else {
      return
    }

    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    replayKeyUpEvent.post(tap: .cghidEventTap)
  }

  private func forwardSyntheticKeyUp(_ event: CGEvent) {
    guard let replayKeyUpEvent = event.copy() else {
      return
    }

    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    syntheticHoldKeyDownTemplate = nil
    syntheticHoldKeyUpTemplate = nil
    syntheticHoldKeyUpEvents = []
    syntheticHoldKeyDownWasSent = false
    replayKeyUpEvent.post(tap: .cghidEventTap)
  }

  private func makeSyntheticReleaseEvent(from event: CGEvent) -> CGEvent? {
    guard let replayKeyUpEvent = event.copy() else {
      return nil
    }

    replayKeyUpEvent.flags = releaseFlags(from: event.flags)
    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    return replayKeyUpEvent
  }

  private func releaseFlags(from flags: CGEventFlags) -> CGEventFlags {
    var rawValue = flags.rawValue
    for key in shortcut?.keys ?? [] {
      rawValue &= ~key.releaseRawFlagMask
      if let modifier = key.modifier {
        rawValue &= ~modifier.eventFlag.rawValue
      }
    }
    return CGEventFlags(rawValue: rawValue)
  }
}

private extension CGEvent {
  var keyCode: UInt16 {
    UInt16(getIntegerValueField(.keyboardEventKeycode))
  }

  var isDelayedReplayEvent: Bool {
    getIntegerValueField(.eventSourceUserData) == GlobalHotKeyService.delayedReplayUserData
  }

  func handle(
    disposition: GlobalHotKeyEventDisposition,
    service: GlobalHotKeyService
  ) -> Unmanaged<CGEvent>? {
    service.handle(disposition: disposition, event: self)
  }
}

private extension ShortcutModifiers {
  init(_ flags: CGEventFlags) {
    var modifiers: ShortcutModifiers = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    self = modifiers
  }
}

private extension DoubaoShortcutKey {
  var releaseRawFlagMask: UInt64 {
    switch self {
    case .leftControl:
      return 0x0000_0001
    case .rightControl:
      return 0x0000_2000
    case .leftOption:
      return 0x0000_0020
    case .rightOption:
      return 0x0000_0040
    case .leftCommand:
      return 0x0000_0008
    case .rightCommand:
      return 0x0000_0010
    case .function:
      return CGEventFlags.maskSecondaryFn.rawValue
    }
  }
}

private extension ShortcutModifiers {
  var eventFlag: CGEventFlags {
    switch self {
    case .control:
      return .maskControl
    case .option:
      return .maskAlternate
    case .command:
      return .maskCommand
    default:
      return []
    }
  }
}

enum GlobalHotKeyError: Error, CustomStringConvertible {
  case eventTapInstallFailed

  var description: String {
    switch self {
    case .eventTapInstallFailed:
      return "Global shortcut event tap install failed. Manually grant Accessibility permission to Doubao Voice Switch."
    }
  }
}

enum GlobalHotKeyEventDisposition: Equatable {
  case passThrough
  case startSyntheticHoldKeyDown
  case suppress
  case storeSyntheticHoldKeyUp
  case releaseSyntheticHold
  case forwardSyntheticKeyUp
}

struct GlobalHotKeyEventLog {
  let type: CGEventType
  let keyCode: UInt16
  let flags: UInt64
  let activeKeys: Set<DoubaoShortcutKey>
  let isActiveShortcut: Bool
  let isShortcutDown: Bool
  let eventSourceUserData: Int64
  let eventSourceUnixProcessID: Int64
  let eventSourceStateID: Int64
  let note: String?

  var message: String {
    let sortedKeys = activeKeys
      .map(\.rawValue)
      .sorted()
      .joined(separator: "+")
    return [
      "observed shortcut event type=\(type.rawValue)",
      "keyCode=\(keyCode)",
      "flags=0x\(String(flags, radix: 16))",
      "activeKeys=\(sortedKeys.isEmpty ? "none" : sortedKeys)",
      "isActiveShortcut=\(isActiveShortcut)",
      "isShortcutDown=\(isShortcutDown)",
      "eventSourceUserData=\(eventSourceUserData)",
      "eventSourceUnixProcessID=\(eventSourceUnixProcessID)",
      "eventSourceStateID=\(eventSourceStateID)",
      "note=\(note ?? "none")"
    ].joined(separator: ", ")
  }
}

struct GlobalHotKeySyntheticReplayLog {
  let delayMilliseconds: Int
  let sent: Bool
  let keyCode: UInt16
  let flags: UInt64
  let eventSourceUserData: Int64
  let eventSourceStateID: Int64

  var message: String {
    [
      "synthetic keyDown replay",
      "delayMs=\(delayMilliseconds)",
      "sent=\(sent)",
      "keyCode=\(keyCode)",
      "flags=0x\(String(flags, radix: 16))",
      "eventSourceUserData=\(eventSourceUserData)",
      "eventSourceStateID=\(eventSourceStateID)"
    ].joined(separator: ", ")
  }
}

struct GlobalHotKeySyntheticResetResult {
  let hadKeyDownTemplate: Bool
  let hadPendingReplay: Bool
  let keyDownWasSent: Bool
  let sentSyntheticKeyUp: Bool
  let clearedTracking: Bool

  var message: String {
    [
      "shortcut state reset",
      "hadKeyDownTemplate=\(hadKeyDownTemplate)",
      "hadPendingReplay=\(hadPendingReplay)",
      "keyDownWasSent=\(keyDownWasSent)",
      "sentSyntheticKeyUp=\(sentSyntheticKeyUp)",
      "clearedTracking=\(clearedTracking)"
    ].joined(separator: ", ")
  }
}

private extension CGEvent {
  func logEvent(
    type: CGEventType,
    activeKeys: Set<DoubaoShortcutKey>,
    isActiveShortcut: Bool,
    isShortcutDown: Bool,
    note: String?
  ) -> GlobalHotKeyEventLog {
    GlobalHotKeyEventLog(
      type: type,
      keyCode: keyCode,
      flags: UInt64(flags.rawValue),
      activeKeys: activeKeys,
      isActiveShortcut: isActiveShortcut,
      isShortcutDown: isShortcutDown,
      eventSourceUserData: getIntegerValueField(.eventSourceUserData),
      eventSourceUnixProcessID: getIntegerValueField(.eventSourceUnixProcessID),
      eventSourceStateID: getIntegerValueField(.eventSourceStateID),
      note: note
    )
  }

  func syntheticReplayLog(
    delayMilliseconds: Int,
    sent: Bool
  ) -> GlobalHotKeySyntheticReplayLog {
    GlobalHotKeySyntheticReplayLog(
      delayMilliseconds: delayMilliseconds,
      sent: sent,
      keyCode: keyCode,
      flags: UInt64(flags.rawValue),
      eventSourceUserData: getIntegerValueField(.eventSourceUserData),
      eventSourceStateID: getIntegerValueField(.eventSourceStateID)
    )
  }
}
