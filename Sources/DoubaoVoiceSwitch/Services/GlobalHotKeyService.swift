import ApplicationServices
import DoubaoVoiceSwitchCore
import Foundation

final class GlobalHotKeyService {
  var onShortcutObserved: ((DoubaoShortcut) -> Void)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: DoubaoShortcut?
  private var shortcutObserver: ShortcutPressObserver?

  deinit {
    unregister()
  }

  func register(shortcut: DoubaoShortcut) throws {
    unregister()
    self.shortcut = shortcut
    shortcutObserver = ShortcutPressObserver(shortcut: shortcut)

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
    shortcutObserver = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .flagsChanged else {
      return Unmanaged.passUnretained(event)
    }

    guard let shortcut, var shortcutObserver else {
      return Unmanaged.passUnretained(event)
    }

    guard let key = DoubaoShortcutKey.key(forKeyCode: event.keyCode),
          shortcut.keys.contains(key) else {
      return Unmanaged.passUnretained(event)
    }

    let shortcutObserved = shortcutObserver.observe(
      key: key,
      activeModifiers: ShortcutModifiers(event.flags),
      isFunctionActive: event.flags.contains(.maskSecondaryFn)
    )
    self.shortcutObserver = shortcutObserver
    if shortcutObserved {
      let callback = onShortcutObserved
      DispatchQueue.main.async {
        callback?(shortcut)
      }
    }

    return Unmanaged.passUnretained(event)
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
