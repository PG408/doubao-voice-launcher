import ApplicationServices
import DoubaoVoiceSwitchCore
import Foundation

final class GlobalHotKeyService {
  var onKeyDown: ((DoubaoShortcut) -> GlobalHotKeyEventDisposition)?
  var onKeyUp: (() -> GlobalHotKeyEventDisposition)?
  var onShortcutEventObserved: ((GlobalHotKeyEventLog) -> Void)?

  fileprivate static let delayedReplayUserData: Int64 = 0x4442_564c_4b55_5001
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: DoubaoShortcut?
  private var isShortcutDown = false
  private var activeKeys: Set<DoubaoShortcutKey> = []
  private var capturedKeyDownEvent: CGEvent?
  private var syntheticHoldKeyUpEvent: CGEvent?

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
    capturedKeyDownEvent = nil
    syntheticHoldKeyUpEvent = nil
  }

  @discardableResult
  func forwardCapturedKeyDown() -> Bool {
    guard let capturedKeyDownEvent else {
      return false
    }

    self.capturedKeyDownEvent = nil
    capturedKeyDownEvent.post(tap: .cghidEventTap)
    return true
  }

  @discardableResult
  func releaseSyntheticHoldIfNeeded() -> Bool {
    guard let syntheticHoldKeyUpEvent else {
      return false
    }

    self.syntheticHoldKeyUpEvent = nil
    syntheticHoldKeyUpEvent.post(tap: .cghidEventTap)
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
    case .captureForSyntheticForwarding:
      captureForSyntheticForwarding(event)
      return nil
    case .suppress:
      return nil
    case .startSyntheticHold:
      startSyntheticHold(keyUpEvent: event)
      return nil
    case .releaseSyntheticHold:
      releaseSyntheticHold(fallbackKeyUpEvent: event)
      return nil
    case .forwardSyntheticKeyUp:
      forwardSyntheticKeyUp(event)
      return nil
    }
  }

  private func captureForSyntheticForwarding(_ event: CGEvent) {
    guard let capturedEvent = event.copy() else {
      return
    }

    capturedEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    capturedKeyDownEvent = capturedEvent
  }

  private func startSyntheticHold(keyUpEvent: CGEvent) {
    guard let replayKeyDownEvent = capturedKeyDownEvent,
          let replayKeyUpEvent = keyUpEvent.copy() else {
      capturedKeyDownEvent = nil
      return
    }

    capturedKeyDownEvent = nil
    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    syntheticHoldKeyUpEvent = replayKeyUpEvent
    replayKeyDownEvent.post(tap: .cghidEventTap)
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
    replayKeyUpEvent.post(tap: .cghidEventTap)
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
  case captureForSyntheticForwarding
  case suppress
  case startSyntheticHold
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
}
