import ApplicationServices
import DoubaoVoiceSwitchCore
import Foundation

final class GlobalHotKeyService {
  var onKeyDown: ((DoubaoShortcut) -> Void)?
  var onKeyUp: (() -> Void)?
  var onShortcutEventObserved: ((GlobalHotKeyEventLog) -> Void)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: DoubaoShortcut?
  private var isShortcutDown = false
  private var activeKeys: Set<DoubaoShortcutKey> = []

  deinit {
    unregister()
  }

  func register(shortcut: DoubaoShortcut) throws {
    unregister()
    self.shortcut = shortcut

    let mask = 1 << CGEventType.flagsChanged.rawValue
    guard let eventTap = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
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

    updateActiveKeys(event: event)
    let isActiveShortcut = shortcut.matches(activeKeys: activeKeys)
    onShortcutEventObserved?(event.logEvent(
      type: type,
      activeKeys: activeKeys,
      isActiveShortcut: isActiveShortcut,
      isShortcutDown: isShortcutDown
    ))

    if isActiveShortcut, !isShortcutDown {
      isShortcutDown = true
      onKeyDown?(shortcut)
    } else if isShortcutDown, !isActiveShortcut {
      isShortcutDown = false
      onKeyUp?()
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
}

private extension CGEvent {
  var keyCode: UInt16 {
    UInt16(getIntegerValueField(.keyboardEventKeycode))
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
      "eventDisposition=passThrough",
      "eventTapLocation=hidListenOnly",
      "eventSourceUserData=\(eventSourceUserData)",
      "eventSourceUnixProcessID=\(eventSourceUnixProcessID)",
      "eventSourceStateID=\(eventSourceStateID)"
    ].joined(separator: ", ")
  }
}

private extension CGEvent {
  func logEvent(
    type: CGEventType,
    activeKeys: Set<DoubaoShortcutKey>,
    isActiveShortcut: Bool,
    isShortcutDown: Bool
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
      eventSourceStateID: getIntegerValueField(.eventSourceStateID)
    )
  }
}
