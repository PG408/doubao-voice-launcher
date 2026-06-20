import ApplicationServices
import DoubaoVoiceLauncherCore
import Foundation

final class GlobalHotKeyService {
  var onKeyDown: ((DoubaoShortcut) -> GlobalHotKeyEventDisposition)?
  var onKeyUp: (() -> GlobalHotKeyEventDisposition)?

  fileprivate static let delayedReplayUserData: Int64 = 0x4442_564c_4b55_5001
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: DoubaoShortcut?
  private var isShortcutDown = false
  private var activeKeys: Set<DoubaoShortcutKey> = []
  private var deferredKeyDownEvent: CGEvent?
  private var deferredKeyDownWorkItem: DispatchWorkItem?

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
    deferredKeyDownEvent = nil
    deferredKeyDownWorkItem?.cancel()
    deferredKeyDownWorkItem = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if event.isDelayedReplayEvent {
      return Unmanaged.passUnretained(event)
    }

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
    case let .deferForwarding(milliseconds):
      deferForwarding(of: event, delayMilliseconds: milliseconds)
      return nil
    case let .replayDeferredTap(keyDownDelayMilliseconds, keyUpGapMilliseconds):
      replayDeferredTap(
        keyUpEvent: event,
        keyDownDelayMilliseconds: keyDownDelayMilliseconds,
        keyUpGapMilliseconds: keyUpGapMilliseconds
      )
      return nil
    }
  }

  private func deferForwarding(of event: CGEvent, delayMilliseconds: Int) {
    deferredKeyDownWorkItem?.cancel()
    guard let replayEvent = event.copy() else {
      return
    }

    replayEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    deferredKeyDownEvent = replayEvent
    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
            let deferredKeyDownEvent = self.deferredKeyDownEvent else {
        return
      }

      self.deferredKeyDownEvent = nil
      self.deferredKeyDownWorkItem = nil
      deferredKeyDownEvent.post(tap: .cghidEventTap)
    }
    deferredKeyDownWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(delayMilliseconds),
      execute: workItem
    )
  }

  private func replayDeferredTap(
    keyUpEvent: CGEvent,
    keyDownDelayMilliseconds: Int,
    keyUpGapMilliseconds: Int
  ) {
    deferredKeyDownWorkItem?.cancel()
    deferredKeyDownWorkItem = nil
    guard let replayKeyDownEvent = deferredKeyDownEvent,
          let replayKeyUpEvent = keyUpEvent.copy() else {
      deferredKeyDownEvent = nil
      return
    }

    deferredKeyDownEvent = nil
    replayKeyUpEvent.setIntegerValueField(.eventSourceUserData, value: Self.delayedReplayUserData)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(keyDownDelayMilliseconds)) {
      replayKeyDownEvent.post(tap: .cghidEventTap)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(keyUpGapMilliseconds)) {
        replayKeyUpEvent.post(tap: .cghidEventTap)
      }
    }
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
      return "Global shortcut event tap install failed. Manually grant Accessibility permission to DoubaoVoiceLauncher."
    }
  }
}

enum GlobalHotKeyEventDisposition: Equatable {
  case passThrough
  case deferForwarding(milliseconds: Int)
  case replayDeferredTap(keyDownDelayMilliseconds: Int, keyUpGapMilliseconds: Int)
}
