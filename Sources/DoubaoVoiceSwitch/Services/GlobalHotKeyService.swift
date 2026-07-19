import ApplicationServices
import DoubaoVoiceSwitchCore
import Foundation

final class GlobalHotKeyService {
  var onShortcutObserved: ((DoubaoShortcut) -> Void)?
  var onMonitorEvent: ((GlobalHotKeyMonitorEvent) -> Void)?

  private var worker: GlobalHotKeyEventTapWorker?

  deinit {
    unregister()
  }

  func register(shortcut: DoubaoShortcut) throws {
    unregister()

    let shortcutCallback = onShortcutObserved
    let monitorCallback = onMonitorEvent
    let worker = GlobalHotKeyEventTapWorker(
      shortcut: shortcut,
      onShortcutObserved: {
        DispatchQueue.main.async {
          shortcutCallback?(shortcut)
        }
      },
      onMonitorEvent: { event in
        DispatchQueue.main.async {
          monitorCallback?(event)
        }
      }
    )
    try worker.start()
    self.worker = worker
  }

  func unregister() {
    worker?.stop()
    worker = nil
  }
}

enum GlobalHotKeyMonitorEvent {
  case disabled(reason: String)
  case reenabled(reason: String, succeeded: Bool)

  var logDescription: String {
    switch self {
    case .disabled(let reason):
      return "eventTapDisabled reason=\(reason), eventDisposition=passThrough"
    case .reenabled(let reason, let succeeded):
      return "eventTapReenabled reason=\(reason), succeeded=\(succeeded)"
    }
  }
}

private final class GlobalHotKeyEventTapWorker {
  private let shortcut: DoubaoShortcut
  private let onShortcutObserved: () -> Void
  private let onMonitorEvent: (GlobalHotKeyMonitorEvent) -> Void
  private let started = DispatchSemaphore(value: 0)
  private let stopped = DispatchSemaphore(value: 0)

  private var shortcutObserver: ShortcutPressObserver
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var thread: Thread?
  private var didInstall = false

  init(
    shortcut: DoubaoShortcut,
    onShortcutObserved: @escaping () -> Void,
    onMonitorEvent: @escaping (GlobalHotKeyMonitorEvent) -> Void
  ) {
    self.shortcut = shortcut
    self.onShortcutObserved = onShortcutObserved
    self.onMonitorEvent = onMonitorEvent
    shortcutObserver = ShortcutPressObserver(shortcut: shortcut)
  }

  func start() throws {
    let thread = Thread { [self] in
      runEventTapLoop()
    }
    thread.name = "Doubao Voice Switch Shortcut Observer"
    thread.qualityOfService = .userInteractive
    self.thread = thread
    thread.start()
    started.wait()

    guard didInstall else {
      stopped.wait()
      self.thread = nil
      throw GlobalHotKeyError.eventTapInstallFailed
    }
  }

  func stop() {
    guard thread != nil else {
      return
    }

    if let runLoop {
      CFRunLoopStop(runLoop)
      CFRunLoopWakeUp(runLoop)
    }
    stopped.wait()
    thread = nil
  }

  private func runEventTapLoop() {
    var didSignalStart = false
    defer {
      if !didSignalStart {
        started.signal()
      }
      tearDownEventTap()
      stopped.signal()
    }

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

        let worker = Unmanaged<GlobalHotKeyEventTapWorker>
          .fromOpaque(userData)
          .takeUnretainedValue()
        return worker.handle(type: type, event: event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      return
    }

    let runLoop = CFRunLoopGetCurrent()
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.eventTap = eventTap
    self.runLoop = runLoop
    self.runLoopSource = runLoopSource
    CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)

    didInstall = CGEvent.tapIsEnabled(tap: eventTap)
    didSignalStart = true
    started.signal()
    guard didInstall else {
      return
    }

    CFRunLoopRun()
  }

  private func tearDownEventTap() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let runLoop, let runLoopSource {
      CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }

    runLoopSource = nil
    eventTap = nil
    runLoop = nil
    didInstall = false
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if let disableReason = disableReason(for: type) {
      shortcutObserver.reset()
      onMonitorEvent(.disabled(reason: disableReason))

      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        onMonitorEvent(
          .reenabled(
            reason: disableReason,
            succeeded: CGEvent.tapIsEnabled(tap: eventTap)
          )
        )
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
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
    if shortcutObserved {
      onShortcutObserved()
    }
    return Unmanaged.passUnretained(event)
  }

  private func disableReason(for type: CGEventType) -> String? {
    switch type {
    case .tapDisabledByTimeout:
      return "timeout"
    case .tapDisabledByUserInput:
      return "userInput"
    default:
      return nil
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
