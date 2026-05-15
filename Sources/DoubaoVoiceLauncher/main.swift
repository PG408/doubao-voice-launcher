import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

private let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let appDisplayName = "豆包语音输入切换"
private let appLogSubsystem = Bundle.main.bundleIdentifier ?? "com.local.doubao.voice-launcher"
private let launcherWindowWidth: CGFloat = 510
private let launcherWindowHeight: CGFloat = 480
private let launcherContentWidth: CGFloat = 450
private let doubaoPreferenceDomains = [
    "com.bytedance.inputmethod.doubaoime",
    "com.bytedance.inputmethod.doubaoime.settings"
]

private enum AppLog {
    static let app = Logger(subsystem: appLogSubsystem, category: "App")
    static let automation = Logger(subsystem: appLogSubsystem, category: "Automation")
    static let inputSource = Logger(subsystem: appLogSubsystem, category: "InputSource")
    static let permissions = Logger(subsystem: appLogSubsystem, category: "Permissions")
    static let shortcut = Logger(subsystem: appLogSubsystem, category: "Shortcut")
    static let ui = Logger(subsystem: appLogSubsystem, category: "UI")
}

private enum FileDebugLog {
    static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DoubaoVoiceLauncher", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("DoubaoVoiceLauncher.log")
    private static let queue = DispatchQueue(label: "com.local.doubao.voice-launcher.file-log")

    static func record(level: String, category: String, message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"
                guard let data = line.data(using: .utf8) else {
                    return
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                AppLog.app.error("Failed to write file debug log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct Shortcut {
    let keyCode: CGKeyCode
    let keyCodes: [CGKeyCode]
    let flags: CGEventFlags
    let display: String

    init(keyCode: CGKeyCode, flags: CGEventFlags, display: String) {
        self.keyCode = keyCode
        self.keyCodes = [keyCode]
        self.flags = flags
        self.display = display
    }

    init(keyCodes: [CGKeyCode]) {
        let uniqueKeyCodes = Array(NSOrderedSet(array: keyCodes.map { NSNumber(value: $0) }))
            .compactMap { ($0 as? NSNumber).map { CGKeyCode($0.uint16Value) } }
        let flags = uniqueKeyCodes.reduce(into: CGEventFlags()) { result, keyCode in
            if let flag = ShortcutFormatter.modifierFlag(for: keyCode) {
                result.insert(flag)
            }
        }
        let display = uniqueKeyCodes.map { ShortcutFormatter.display(keyCode: $0, flags: ShortcutFormatter.modifierFlag(for: $0) ?? []) }
            .joined(separator: " + ")
        self.keyCode = uniqueKeyCodes.first ?? 62
        self.keyCodes = uniqueKeyCodes
        self.flags = flags
        self.display = display
    }

    init(keyCodes: [CGKeyCode], flags: CGEventFlags, display: String) {
        self.keyCode = keyCodes.first ?? 62
        self.keyCodes = keyCodes.isEmpty ? [self.keyCode] : keyCodes
        self.flags = flags
        self.display = display
    }

    var logDescription: String {
        let keyCodesDescription = keyCodes.map { String($0) }.joined(separator: ",")
        return "\(display) [keyCodes=\(keyCodesDescription), flags=\(flags.rawValue)]"
    }
}

private let defaultRightControlShortcut = Shortcut(
    keyCode: 62,
    flags: .maskControl,
    display: "右⌃"
)
private let rightControlLongPressThreshold: TimeInterval = 0.10
private let rightControlDoubleTapWindow: TimeInterval = 0.45
private let forwardedShortcutResumeDelay: TimeInterval = 0.20

private enum ShortcutRole {
    case hold
    case doubleTap
}

private struct ShortcutCandidate {
    let title: String
    let keyCode: CGKeyCode
    let flag: CGEventFlags
}

private enum ShortcutDefaults {
    private static let holdKeyCodeKey = "holdShortcutKeyCode"
    private static let holdKeyCodesKey = "holdShortcutKeyCodes"
    private static let holdFlagsKey = "holdShortcutFlags"
    private static let holdDisplayKey = "holdShortcutDisplay"
    private static let doubleKeyCodeKey = "doubleTapShortcutKeyCode"
    private static let doubleKeyCodesKey = "doubleTapShortcutKeyCodes"
    private static let doubleFlagsKey = "doubleTapShortcutFlags"
    private static let doubleDisplayKey = "doubleTapShortcutDisplay"

    static func loadHoldShortcut() -> Shortcut {
        load(keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
            ?? defaultRightControlShortcut
    }

    static func loadDoubleTapShortcut() -> Shortcut {
        load(keyCodeKey: doubleKeyCodeKey, keyCodesKey: doubleKeyCodesKey, flagsKey: doubleFlagsKey, displayKey: doubleDisplayKey)
            ?? defaultRightControlShortcut
    }

    static func saveHoldShortcut(_ shortcut: Shortcut) {
        save(shortcut, keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
    }

    static func saveDoubleTapShortcut(_ shortcut: Shortcut) {
        save(shortcut, keyCodeKey: doubleKeyCodeKey, keyCodesKey: doubleKeyCodesKey, flagsKey: doubleFlagsKey, displayKey: doubleDisplayKey)
    }

    private static func load(keyCodeKey: String, keyCodesKey: String, flagsKey: String, displayKey: String) -> Shortcut? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return nil
        }
        let keyCode = CGKeyCode(defaults.integer(forKey: keyCodeKey))
        let keyCodes = defaults.array(forKey: keyCodesKey) as? [Int] ?? [Int(keyCode)]
        let rawFlags = UInt64(defaults.integer(forKey: flagsKey))
        let display = defaults.string(forKey: displayKey)
            ?? ShortcutFormatter.display(keyCode: keyCode, flags: CGEventFlags(rawValue: rawFlags))
        return Shortcut(
            keyCodes: keyCodes.map { CGKeyCode($0) },
            flags: CGEventFlags(rawValue: rawFlags),
            display: display
        )
    }

    private static func save(_ shortcut: Shortcut, keyCodeKey: String, keyCodesKey: String, flagsKey: String, displayKey: String) {
        let defaults = UserDefaults.standard
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(shortcut.keyCodes.map(Int.init), forKey: keyCodesKey)
        defaults.set(Int(shortcut.flags.rawValue), forKey: flagsKey)
        defaults.set(shortcut.display, forKey: displayKey)
        AppLog.shortcut.info("Saved shortcut \(shortcut.logDescription, privacy: .public) for key \(displayKey, privacy: .public)")
    }
}

private enum ShortcutFormatter {
    static let candidates: [ShortcutCandidate] = [
        ShortcutCandidate(title: "fn", keyCode: 63, flag: .maskSecondaryFn),
        ShortcutCandidate(title: "左⇧", keyCode: 56, flag: .maskShift),
        ShortcutCandidate(title: "右⇧", keyCode: 60, flag: .maskShift),
        ShortcutCandidate(title: "左⌘", keyCode: 55, flag: .maskCommand),
        ShortcutCandidate(title: "右⌘", keyCode: 54, flag: .maskCommand),
        ShortcutCandidate(title: "左⌥", keyCode: 58, flag: .maskAlternate),
        ShortcutCandidate(title: "右⌥", keyCode: 61, flag: .maskAlternate),
        ShortcutCandidate(title: "左⌃", keyCode: 59, flag: .maskControl),
        ShortcutCandidate(title: "右⌃", keyCode: 62, flag: .maskControl)
    ]

    static func shortcut(fromCandidateKeyCodes keyCodes: [CGKeyCode]) -> Shortcut? {
        let selected = candidates.filter { keyCodes.contains($0.keyCode) }
        guard !selected.isEmpty else {
            return nil
        }
        let flags = selected.reduce(into: CGEventFlags()) { result, candidate in
            result.insert(candidate.flag)
        }
        return Shortcut(
            keyCodes: selected.map(\.keyCode),
            flags: flags,
            display: selected.map(\.title).joined(separator: " + ")
        )
    }

    static func shortcut(from event: CGEvent) -> Shortcut? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = allowedModifierFlags(from: event.flags)
        guard !flags.isEmpty else {
            return nil
        }
        return Shortcut(keyCode: keyCode, flags: flags, display: display(keyCode: keyCode, flags: flags))
    }

    static func isModifierShortcut(_ shortcut: Shortcut) -> Bool {
        !allowedModifierFlags(from: shortcut.flags).isEmpty
    }

    static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 63:
            return .maskSecondaryFn
        case 54, 55:
            return .maskCommand
        case 56, 60:
            return .maskShift
        case 58, 61:
            return .maskAlternate
        case 59, 62:
            return .maskControl
        default:
            return nil
        }
    }

    static func display(keyCode: CGKeyCode, flags: CGEventFlags) -> String {
        let allowedFlags = allowedModifierFlags(from: flags)
        if allowedFlags == .maskControl, let modifierDisplay = modifierKeyDisplay(keyCode: keyCode) {
            return modifierDisplay
        }
        if allowedFlags == .maskShift, let modifierDisplay = modifierKeyDisplay(keyCode: keyCode) {
            return modifierDisplay
        }
        var parts: [String] = []
        if allowedFlags.contains(.maskSecondaryFn) { parts.append("fn") }
        if allowedFlags.contains(.maskControl) { parts.append("⌃") }
        if allowedFlags.contains(.maskAlternate) { parts.append("⌥") }
        if allowedFlags.contains(.maskShift) { parts.append("⇧") }
        if allowedFlags.contains(.maskCommand) { parts.append("⌘") }
        if parts.isEmpty {
            parts.append(keyDisplay(keyCode: keyCode))
        }
        return parts.joined()
    }

    static func allowedModifierFlags(from eventFlags: CGEventFlags) -> CGEventFlags {
        let masks: [CGEventFlags] = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
        return masks.reduce(into: CGEventFlags()) { result, mask in
            if eventFlags.contains(mask) {
                result.insert(mask)
            }
        }
    }

    static func modifierCount(in flags: CGEventFlags) -> Int {
        let masks: [CGEventFlags] = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
        return masks.reduce(0) { count, mask in
            flags.contains(mask) ? count + 1 : count
        }
    }

    private static func modifierKeyDisplay(keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 63:
            return "fn"
        case 54:
            return "右⌘"
        case 55:
            return "左⌘"
        case 56:
            return "左⇧"
        case 60:
            return "右⇧"
        case 58:
            return "左⌥"
        case 61:
            return "右⌥"
        case 59:
            return "左⌃"
        case 62:
            return "右⌃"
        default:
            return nil
        }
    }

    private static func keyDisplay(keyCode: CGKeyCode) -> String {
        let names: [CGKeyCode: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            51: "⌫", 53: "Esc", 76: "⌅", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

private final class InputSourceService {
    private var previousSourceID: String?

    func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            AppLog.inputSource.error("Failed to copy current keyboard input source")
            FileDebugLog.record(level: "ERROR", category: "InputSource", message: "Failed to copy current keyboard input source")
            return nil
        }
        let currentID = sourceID(for: source)
        if currentID == nil {
            AppLog.inputSource.error("Current keyboard input source has no source ID")
            FileDebugLog.record(level: "ERROR", category: "InputSource", message: "Current keyboard input source has no source ID")
        }
        return currentID
    }

    func beginDoubaoSession() -> Bool {
        if previousSourceID == nil {
            previousSourceID = currentSourceID()
            AppLog.inputSource.info("Captured previous input source \(self.previousSourceID ?? "nil", privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "InputSource", message: "Captured previous input source \(previousSourceID ?? "nil")")
        }
        let currentID = currentSourceID()
        if currentID == doubaoInputSourceID {
            AppLog.inputSource.debug("Doubao input source is already active")
            FileDebugLog.record(level: "DEBUG", category: "InputSource", message: "Doubao input source is already active")
            return true
        }
        let ok = selectSource(id: doubaoInputSourceID)
        AppLog.inputSource.info("Begin Doubao session from \(currentID ?? "nil", privacy: .public): \(ok, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "InputSource", message: "Begin Doubao session from \(currentID ?? "nil"): \(ok)")
        return ok
    }

    func selectDoubao() -> Bool {
        beginDoubaoSession()
    }

    func restorePrevious() -> Bool {
        guard let previousSourceID else {
            AppLog.inputSource.info("Skip restoring input source because no previous source was captured")
            FileDebugLog.record(level: "INFO", category: "InputSource", message: "Skip restoring input source because no previous source was captured")
            return false
        }
        let ok = selectSource(id: previousSourceID)
        AppLog.inputSource.info("Restore previous input source \(previousSourceID, privacy: .public): \(ok, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "InputSource", message: "Restore previous input source \(previousSourceID): \(ok)")
        if ok {
            self.previousSourceID = nil
        }
        return ok
    }

    func isDoubaoInstalled() -> Bool {
        inputSource(id: doubaoInputSourceID) != nil
    }

    private func selectSource(id: String) -> Bool {
        guard let source = inputSource(id: id) else {
            AppLog.inputSource.error("Input source not found: \(id, privacy: .public)")
            FileDebugLog.record(level: "ERROR", category: "InputSource", message: "Input source not found: \(id)")
            return false
        }
        let status = TISSelectInputSource(source)
        if status != noErr {
            AppLog.inputSource.error("Failed to select input source \(id, privacy: .public), status \(status, privacy: .public)")
            FileDebugLog.record(level: "ERROR", category: "InputSource", message: "Failed to select input source \(id), status \(status)")
        }
        return status == noErr
    }

    private func inputSource(id: String) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else {
            AppLog.inputSource.error("Failed to create input source list for \(id, privacy: .public)")
            FileDebugLog.record(level: "ERROR", category: "InputSource", message: "Failed to create input source list for \(id)")
            return nil
        }
        return list.first
    }

    private func sourceID(for source: TISInputSource) -> String? {
        let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        guard value != nil else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(value!).takeUnretainedValue() as String
    }
}

private enum PreferenceReader {
    static func loadShortcut() -> Shortcut? {
        for domain in doubaoPreferenceDomains {
            guard let keyCode = integerValue("asrShortcutKeyCode", domain: domain),
                  let rawFlags = integerValue("asrShortcutModifierFlags", domain: domain) else {
                continue
            }
            let display = stringValue("asrShortcutKeyDisplay", domain: domain)
                ?? "keyCode=\(keyCode), flags=\(rawFlags)"
            AppLog.shortcut.info("Loaded Doubao preference shortcut from \(domain, privacy: .public): \(display, privacy: .public)")
            return Shortcut(
                keyCode: CGKeyCode(keyCode),
                flags: CGEventFlags(rawValue: UInt64(rawFlags)),
                display: display
            )
        }
        AppLog.shortcut.info("No Doubao preference shortcut found")
        return nil
    }

    private static func integerValue(_ key: String, domain: String) -> Int? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func stringValue(_ key: String, domain: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
    }
}

private enum AccessibilityService {
    static func ensureTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppLog.permissions.info("Accessibility permission trusted: \(trusted, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Permissions", message: "Accessibility permission trusted: \(trusted)")
        return trusted
    }

    static func canListenKeyboardEvents() -> Bool {
        let canListen = CGPreflightListenEventAccess()
        AppLog.permissions.info("Input monitoring permission preflight: \(canListen, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Permissions", message: "Input monitoring permission preflight: \(canListen)")
        return canListen
    }

    static func requestKeyboardEventAccess() -> Bool {
        let granted = CGRequestListenEventAccess()
        AppLog.permissions.info("Input monitoring permission request result: \(granted, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Permissions", message: "Input monitoring permission request result: \(granted)")
        return granted
    }
}

private enum ShortcutSender {
    private static let syntheticEventMarker: Int64 = 0x44424F494D45

    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    static func keyDown(shortcut: Shortcut) {
        AppLog.shortcut.info("Send shortcut key down \(shortcut.logDescription, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Shortcut", message: "Send shortcut key down \(shortcut.logDescription)")
        postModifierEvent(shortcut: shortcut, keyDown: true)
    }

    static func keyUp(shortcut: Shortcut) {
        AppLog.shortcut.info("Send shortcut key up \(shortcut.logDescription, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Shortcut", message: "Send shortcut key up \(shortcut.logDescription)")
        postModifierEvent(shortcut: shortcut, keyDown: false)
    }

    private static func postModifierEvent(shortcut: Shortcut, keyDown: Bool) {
        if ShortcutFormatter.isModifierShortcut(shortcut) {
            postModifierShortcut(shortcut: shortcut, keyDown: keyDown)
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: keyDown)
        event?.flags = keyDown ? shortcut.flags : []
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event?.post(tap: .cghidEventTap)
    }

    private static func postModifierShortcut(shortcut: Shortcut, keyDown: Bool) {
        let modifiers = modifierSteps(for: shortcut)
        guard !modifiers.isEmpty else {
            return
        }
        var activeFlags = keyDown ? CGEventFlags() : shortcut.flags
        var activeKeyCodes = Set(keyDown ? [] : modifiers.map(\.keyCode))
        let steps = keyDown ? modifiers : modifiers.reversed()

        for step in steps {
            if keyDown {
                activeKeyCodes.insert(step.keyCode)
                activeFlags.insert(step.flag)
            } else {
                activeKeyCodes.remove(step.keyCode)
                let stillPressed = modifiers.contains { other in
                    activeKeyCodes.contains(other.keyCode) && other.flag == step.flag
                }
                if !stillPressed {
                    activeFlags.remove(step.flag)
                }
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let event = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: keyDown)
            event?.type = .flagsChanged
            event?.flags = activeFlags
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    private static func modifierSteps(for shortcut: Shortcut) -> [(flag: CGEventFlags, keyCode: CGKeyCode)] {
        shortcut.keyCodes.compactMap { keyCode in
            guard let flag = ShortcutFormatter.modifierFlag(for: keyCode) else {
                return nil
            }
            return (flag, keyCode)
        }
    }

}

private final class RightControlAutomation {
    private let inputSourceService: InputSourceService
    private var holdShortcut = ShortcutDefaults.loadHoldShortcut()
    private var doubleTapShortcut = ShortcutDefaults.loadDoubleTapShortcut()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTriggerDown = false
    private var triggerDownAt: TimeInterval = 0
    private var lastShortTapUpAt: TimeInterval = 0
    private var sessionActive = false
    private var longPressWorkItem: DispatchWorkItem?
    private var didTriggerLongPress = false
    private var resumeEventTapWorkItem: DispatchWorkItem?
    private var isForwardingShortcut = false
    private var activeShortcut: Shortcut?
    private var sessionShortcut: Shortcut?
    private var activeModifierKeyCodes = Set<CGKeyCode>()
    private var activeSupportsLongPress = false
    private var activeSupportsDoubleTap = false

    var onStatus: ((String) -> Void)?

    init(inputSourceService: InputSourceService) {
        self.inputSourceService = inputSourceService
    }

    func start() -> Bool {
        AppLog.automation.info("Start keyboard automation requested")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Start keyboard automation requested")
        guard eventTap == nil else {
            AppLog.automation.info("Keyboard automation is already running")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation is already running")
            onStatus?("后台监听已开启。")
            return true
        }

        guard AccessibilityService.ensureTrusted() else {
            AppLog.automation.error("Keyboard automation start failed because accessibility permission is missing")
            FileDebugLog.record(level: "ERROR", category: "Automation", message: "Keyboard automation start failed because accessibility permission is missing")
            onStatus?("后台监听需要辅助功能权限。授权后请重启本 App。")
            return false
        }

        guard AccessibilityService.canListenKeyboardEvents() || AccessibilityService.requestKeyboardEventAccess() else {
            AppLog.automation.error("Keyboard automation start failed because input monitoring permission is missing")
            FileDebugLog.record(level: "ERROR", category: "Automation", message: "Keyboard automation start failed because input monitoring permission is missing")
            onStatus?("后台监听还需要输入监控权限。请在系统设置中打开本 App 的输入监控权限后重启。")
            return false
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<RightControlAutomation>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLog.automation.error("Failed to create global keyboard event tap")
            FileDebugLog.record(level: "ERROR", category: "Automation", message: "Failed to create global keyboard event tap")
            onStatus?("无法创建全局键盘监听。请检查辅助功能权限。")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.automation.info("Keyboard automation started with hold \(self.holdShortcut.logDescription, privacy: .public), doubleTap \(self.doubleTapShortcut.logDescription, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation started with hold \(holdShortcut.logDescription), doubleTap \(doubleTapShortcut.logDescription)")
        onStatus?("后台监听已开启：已选择的长按或免按快捷键会自动切到豆包，结束后恢复原输入法。")
        return true
    }

    func updateShortcuts(hold: Shortcut, doubleTap: Shortcut) {
        holdShortcut = hold
        doubleTapShortcut = doubleTap
        AppLog.automation.info("Updated automation shortcuts: hold \(hold.logDescription, privacy: .public), doubleTap \(doubleTap.logDescription, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Updated automation shortcuts: hold \(hold.logDescription), doubleTap \(doubleTap.logDescription)")
    }

    func stop() {
        AppLog.automation.info("Stop keyboard automation requested")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Stop keyboard automation requested")
        resumeEventTapWorkItem?.cancel()
        resumeEventTapWorkItem = nil
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        if sessionActive {
            ShortcutSender.keyUp(shortcut: sessionShortcut ?? doubleTapShortcut)
            sessionActive = false
            sessionShortcut = nil
        }
        isForwardingShortcut = false
        isTriggerDown = false
        didTriggerLongPress = false
        activeModifierKeyCodes.removeAll()
        resetActiveTrigger()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        AppLog.automation.info("Keyboard automation stopped")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isForwardingShortcut {
                AppLog.automation.debug("Event tap disabled while forwarding synthetic shortcut; waiting for scheduled re-enable")
                return Unmanaged.passUnretained(event)
            }
            AppLog.automation.warning("Event tap disabled by system, re-enabling")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Event tap disabled by system, re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if ShortcutSender.isSyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            return handleKeyDown(event: event)
        }

        if type == .keyUp {
            return handleKeyUp(event: event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let modifierFlag = ShortcutFormatter.modifierFlag(for: keyCode) {
            if event.flags.contains(modifierFlag) {
                activeModifierKeyCodes.insert(keyCode)
            } else {
                activeModifierKeyCodes.remove(keyCode)
            }
        }

        let holdKeyCodes = Set(holdShortcut.keyCodes)
        let doubleTapKeyCodes = Set(doubleTapShortcut.keyCodes)
        let supportsLongPress = holdKeyCodes.contains(keyCode) && activeModifierKeyCodes == holdKeyCodes
        let supportsDoubleTap = doubleTapKeyCodes.contains(keyCode) && activeModifierKeyCodes == doubleTapKeyCodes
        let shortcut = supportsDoubleTap ? doubleTapShortcut : holdShortcut
        if (supportsLongPress || supportsDoubleTap) && !isTriggerDown {
            handleTriggerDown(shortcut: shortcut, supportsLongPress: supportsLongPress, supportsDoubleTap: supportsDoubleTap)
            return Unmanaged.passUnretained(event)
        }

        let activeKeyCodes = Set(activeShortcut?.keyCodes ?? [])
        if isTriggerDown && activeKeyCodes.contains(keyCode) && activeModifierKeyCodes != activeKeyCodes {
            handleTriggerUp()
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard sessionActive else {
            return Unmanaged.passUnretained(event)
        }

        AppLog.automation.info("Detected regular key down while no-hold session is active; scheduling restore")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Detected regular key down while no-hold session is active; scheduling restore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let shortcut = self.sessionShortcut ?? self.doubleTapShortcut
            self.forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            _ = self.inputSourceService.restorePrevious()
            self.sessionActive = false
            self.sessionShortcut = nil
            self.onStatus?("检测到按键结束语音输入，已恢复原输入法。")
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        return Unmanaged.passUnretained(event)
    }

    private func handleTriggerDown(shortcut: Shortcut, supportsLongPress: Bool, supportsDoubleTap: Bool) {
        isTriggerDown = true
        didTriggerLongPress = false
        activeShortcut = shortcut
        activeSupportsLongPress = supportsLongPress
        activeSupportsDoubleTap = supportsDoubleTap
        triggerDownAt = ProcessInfo.processInfo.systemUptime
        let pressStartedAt = triggerDownAt
        AppLog.automation.info("Shortcut trigger down: \(shortcut.logDescription, privacy: .public), longPress=\(supportsLongPress, privacy: .public), doubleTap=\(supportsDoubleTap, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger down: \(shortcut.logDescription), longPress=\(supportsLongPress), doubleTap=\(supportsDoubleTap)")

        if sessionActive {
            AppLog.automation.info("Shortcut pressed while no-hold session is active")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut pressed while no-hold session is active")
            onStatus?("检测到快捷键按下，将结束免按语音输入。")
            return
        }

        guard supportsLongPress else {
            AppLog.automation.debug("Trigger does not support long press; waiting for double-tap flow")
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isTriggerDown else {
                return
            }
            let heldDuration = ProcessInfo.processInfo.systemUptime - pressStartedAt
            guard heldDuration >= rightControlLongPressThreshold else {
                return
            }
            guard self.inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Long press flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Long press flow failed to switch to Doubao input source")
                self.onStatus?("切换到豆包输入法失败。")
                return
            }
            self.didTriggerLongPress = true
            self.forwardShortcutEvent {
                ShortcutSender.keyDown(shortcut: shortcut)
            }
            AppLog.automation.info("Long press flow started after \(heldDuration, privacy: .public) seconds")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Long press flow started after \(heldDuration) seconds")
            self.onStatus?("检测到长按模式快捷键，已切到豆包并开始语音输入。")
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + rightControlLongPressThreshold, execute: workItem)
    }

    private func handleTriggerUp() {
        let now = ProcessInfo.processInfo.systemUptime
        isTriggerDown = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        let shortcut = activeShortcut ?? doubleTapShortcut
        let supportsDoubleTap = activeSupportsDoubleTap
        AppLog.automation.info("Shortcut trigger up: \(shortcut.logDescription, privacy: .public), didLongPress=\(self.didTriggerLongPress, privacy: .public), sessionActive=\(self.sessionActive, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger up: \(shortcut.logDescription), didLongPress=\(didTriggerLongPress), sessionActive=\(sessionActive)")

        if didTriggerLongPress {
            forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            didTriggerLongPress = false
            sessionActive = false
            resetActiveTrigger()
            AppLog.automation.info("Long press flow ended; restoring previous input source")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Long press flow ended; restoring previous input source")
            restoreAfterDelay(message: "长按模式结束，已恢复原输入法。", delay: 0.45)
            return
        }

        if sessionActive {
            guard inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("No-hold stop flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "No-hold stop flow failed to switch to Doubao input source")
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let endingShortcut = self.sessionShortcut ?? shortcut
                self.forwardShortcutEvent {
                    ShortcutSender.keyUp(shortcut: endingShortcut)
                }
                self.sessionActive = false
                self.sessionShortcut = nil
                AppLog.automation.info("No-hold flow stopped by shortcut; restoring previous input source")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold flow stopped by shortcut; restoring previous input source")
                self.restoreAfterDelay(message: "检测到快捷键单击结束免按语音输入，已恢复原输入法。", delay: 0.45)
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        guard supportsDoubleTap else {
            AppLog.automation.debug("Trigger up ignored because active shortcut does not support double-tap flow")
            resetActiveTrigger()
            return
        }

        if now - lastShortTapUpAt <= rightControlDoubleTapWindow {
            guard inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Double-tap flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Double-tap flow failed to switch to Doubao input source")
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.forwardShortcutEvent {
                    ShortcutSender.keyDown(shortcut: shortcut)
                }
                self.sessionActive = true
                self.sessionShortcut = shortcut
                AppLog.automation.info("No-hold flow started by double tap with forwarded key down")
                FileDebugLog.record(
                    level: "INFO",
                    category: "Automation",
                    message: "No-hold flow started by double tap with forwarded key down"
                )
                self.onStatus?("检测到免按模式快捷键双击，已切到豆包并转发语音快捷键。")
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        lastShortTapUpAt = now
        resetActiveTrigger()
        AppLog.automation.info("First double-tap candidate recorded")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "First double-tap candidate recorded")
        onStatus?("检测到一次免按模式快捷键，等待第二次按下。")
    }

    private func forwardShortcutEvent(resumeDelay: TimeInterval = forwardedShortcutResumeDelay, _ send: () -> Void) {
        if let eventTap {
            AppLog.automation.debug("Temporarily disabling event tap before forwarding shortcut")
            isForwardingShortcut = true
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        send()

        resumeEventTapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let eventTap = self.eventTap else {
                return
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            self.isForwardingShortcut = false
            AppLog.automation.debug("Re-enabled event tap after forwarding shortcut")
        }
        resumeEventTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay, execute: workItem)
    }

    private func restoreAfterDelay(message: String, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let restored = self.inputSourceService.restorePrevious()
            AppLog.automation.info("Restore after delay finished: \(restored, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Restore after delay finished: \(restored)")
            self.onStatus?(message)
        }
    }

    private func resetActiveTrigger() {
        activeShortcut = nil
        activeSupportsLongPress = false
        activeSupportsDoubleTap = false
    }
}

private final class LauncherViewController: NSViewController {
    private let inputSourceService = InputSourceService()
    private lazy var automation = RightControlAutomation(inputSourceService: inputSourceService)
    private var holdShortcut = ShortcutDefaults.loadHoldShortcut()
    private var doubleTapShortcut = ShortcutDefaults.loadDoubleTapShortcut()
    private var statusMessage: String?
    private var shortcutPickerPopover: NSPopover?
    private var isMonitoring = false

    private let messageLabel = NSTextField(labelWithString: "")
    private let monitorStatusValueLabel = NSTextField(labelWithString: "")
    private let doubaoStatusValueLabel = NSTextField(labelWithString: "")
    private let currentInputValueLabel = NSTextField(labelWithString: "")
    private let holdShortcutButton = ShortcutSelectButton(title: "")
    private let doubleTapShortcutButton = ShortcutSelectButton(title: "")
    private let monitorToggleButton = PrimaryActionButton(title: "开始监听")
    private let monitorStatusDotView = NSView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: launcherWindowWidth, height: launcherWindowHeight))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        AppLog.ui.info("Launcher view did load")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Launcher view did load; file log path: \(FileDebugLog.fileURL.path)")
        buildUI()
        automation.onStatus = { [weak self] message in
            self?.refreshStatus(message)
        }
        automation.updateShortcuts(hold: holdShortcut, doubleTap: doubleTapShortcut)
        let started = automation.start()
        isMonitoring = started
        updateMonitorToggleButton()
        AppLog.ui.info("Initial automation start result: \(started, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Initial automation start result: \(started)")
        if started {
            refreshStatus("后台监听已开启。")
        }
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: appDisplayName)
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)

        let explanationLabel = NSTextField(labelWithString: "自动切换到豆包语音输入，结束后恢复原输入法")
        explanationLabel.font = .systemFont(ofSize: 15)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.lineBreakMode = .byWordWrapping

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.stringValue = "正在检查状态..."

        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(showHoldShortcutPicker(_:))
        holdShortcutButton.widthAnchor.constraint(equalToConstant: 112).isActive = true

        doubleTapShortcutButton.target = self
        doubleTapShortcutButton.action = #selector(showDoubleTapShortcutPicker(_:))
        doubleTapShortcutButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        updateShortcutButtons()

        let openSettingsButton = IconActionButton(title: "打开豆包设置", symbolName: "gearshape")
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openDoubaoSettings)

        let accessibilityButton = IconActionButton(title: "辅助功能", symbolName: "checkmark.shield")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)

        let inputMonitoringButton = IconActionButton(title: "输入监控", symbolName: "keyboard")
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(openInputMonitoringSettings)

        monitorToggleButton.target = self
        monitorToggleButton.action = #selector(toggleMonitoring)
        updateMonitorToggleButton()

        [openSettingsButton, accessibilityButton, inputMonitoringButton].forEach(configureSecondaryButton)
        configureShortcutButton(holdShortcutButton)
        configureShortcutButton(doubleTapShortcutButton)

        let statusContent = NSStackView(views: [
            makeStatusItem(symbolName: "waveform", valueLabel: monitorStatusValueLabel, caption: "运行状态", showsDot: true),
            makeVerticalDivider(),
            makeStatusItem(symbolName: "checkmark.circle", valueLabel: doubaoStatusValueLabel, caption: "豆包输入法", showsDot: false),
            makeVerticalDivider(),
            makeStatusItem(symbolName: "keyboard", valueLabel: currentInputValueLabel, caption: "当前输入源", showsDot: false)
        ])
        statusContent.orientation = .horizontal
        statusContent.spacing = 0
        statusContent.alignment = .centerY
        statusContent.distribution = .fill
        let statusCard = makeRoundedContainer(content: statusContent, horizontalPadding: 18, verticalPadding: 15)

        let shortcutContent = NSStackView(views: [
            makePlainShortcutRow(
                title: "长按模式",
                detail: "按住说话，松手结束",
                button: holdShortcutButton
            ),
            makeHorizontalDivider(),
            makePlainShortcutRow(
                title: "免按模式",
                detail: "双击开始，再次按键结束",
                button: doubleTapShortcutButton
            )
        ])
        shortcutContent.orientation = .vertical
        shortcutContent.spacing = 0
        shortcutContent.alignment = .leading
        let shortcutSectionTitle = NSTextField(labelWithString: "快捷键")
        shortcutSectionTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let shortcutCard = makeRoundedContainer(content: shortcutContent, horizontalPadding: 18, verticalPadding: 14)

        let secondaryButtonRow = makeBottomActionBar(buttons: [openSettingsButton, accessibilityButton, inputMonitoringButton])

        let stack = NSStackView(views: [titleLabel, explanationLabel, statusCard, monitorToggleButton, shortcutSectionTitle, shortcutCard])
        stack.orientation = .vertical
        stack.spacing = 13
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(secondaryButtonRow)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            titleLabel.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            explanationLabel.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            statusCard.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            monitorToggleButton.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            monitorToggleButton.heightAnchor.constraint(equalToConstant: 37),
            shortcutSectionTitle.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            shortcutCard.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            secondaryButtonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secondaryButtonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secondaryButtonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            secondaryButtonRow.heightAnchor.constraint(equalToConstant: 37)
        ])
    }

    private func makeRoundedContainer(content: NSView, horizontalPadding: CGFloat, verticalPadding: CGFloat) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.26).cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.18).cgColor
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: horizontalPadding),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -horizontalPadding),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: verticalPadding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -verticalPadding)
        ])
        return card
    }

    private func makeStatusItem(symbolName: String, valueLabel: NSTextField, caption: String, showsDot: Bool) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor = .systemBlue
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true

        valueLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let valueRow = NSStackView(views: [valueLabel])
        valueRow.orientation = .horizontal
        valueRow.spacing = 8
        if showsDot {
            monitorStatusDotView.wantsLayer = true
            monitorStatusDotView.layer?.cornerRadius = 4
            monitorStatusDotView.layer?.backgroundColor = NSColor.systemRed.cgColor
            monitorStatusDotView.widthAnchor.constraint(equalToConstant: 8).isActive = true
            monitorStatusDotView.heightAnchor.constraint(equalToConstant: 8).isActive = true
            valueRow.addArrangedSubview(monitorStatusDotView)
        }

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [valueRow, captionLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let container = NSView()
        container.addSubview(icon)
        container.addSubview(textStack)
        icon.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 137),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 54),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.widthAnchor.constraint(equalToConstant: 72)
        ])
        return container
    }

    private func makePlainShortcutRow(title: String, detail: String, button: NSButton) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.spacing = 5
        textStack.alignment = .leading
        textStack.widthAnchor.constraint(equalToConstant: 248).isActive = true
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 42
        row.widthAnchor.constraint(equalToConstant: 414).isActive = true
        row.heightAnchor.constraint(equalToConstant: 58).isActive = true
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeVerticalDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return divider
    }

    private func makeHorizontalDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 414).isActive = true
        return divider
    }

    private func configureSecondaryButton(_ button: NSButton) {
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    private func makeBottomActionBar(buttons: [NSButton]) -> NSView {
        let topDivider = NSView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor

        let dividers = (0..<max(0, buttons.count - 1)).map { _ -> NSView in
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 21).isActive = true
            return divider
        }

        var rowViews: [NSView] = []
        for (index, button) in buttons.enumerated() {
            rowViews.append(button)
            if index < dividers.count {
                rowViews.append(dividers[index])
            }
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        let buttonWidth = (launcherWindowWidth - CGFloat(dividers.count)) / CGFloat(buttons.count)
        buttons.forEach { $0.widthAnchor.constraint(equalToConstant: buttonWidth).isActive = true }

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.06).cgColor
        bar.addSubview(topDivider)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            topDivider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: bar.topAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        return bar
    }

    private func configureShortcutButton(_ button: NSButton) {
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 33).isActive = true
    }

    private func setSymbol(_ symbolName: String, on button: NSButton) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.contentTintColor = .controlTextColor
    }

    private func refreshStatus(_ message: String? = nil) {
        if let message {
            statusMessage = message
            AppLog.ui.info("Status message updated: \(message, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "UI", message: "Status message updated: \(message)")
        }

        let installed = inputSourceService.isDoubaoInstalled() ? "已安装" : "未安装"
        let current = displayName(forInputSourceID: inputSourceService.currentSourceID())
        messageLabel.stringValue = statusMessage ?? "监听开启后，仅已选择的快捷键会触发自动切换。"
        monitorStatusValueLabel.stringValue = isMonitoring ? "监听中" : "已暂停"
        monitorStatusDotView.layer?.backgroundColor = (isMonitoring ? NSColor.systemGreen : NSColor.systemRed).cgColor
        doubaoStatusValueLabel.stringValue = installed
        currentInputValueLabel.stringValue = current
    }

    private func displayName(forInputSourceID sourceID: String?) -> String {
        guard let sourceID else {
            return "未知"
        }
        if sourceID == doubaoInputSourceID {
            return "豆包输入法"
        }
        if sourceID.contains("sogou") {
            return "搜狗拼音"
        }
        return sourceID
    }

    private func updateShortcutButtons() {
        holdShortcutButton.title = holdShortcut.display
        doubleTapShortcutButton.title = doubleTapShortcut.display
    }

    private func updateMonitorToggleButton() {
        let title = isMonitoring ? "暂停监听" : "开始监听"
        monitorToggleButton.title = title
        monitorToggleButton.symbolName = isMonitoring ? "pause.circle.fill" : "play.circle.fill"
    }

    @objc private func toggleMonitoring() {
        if isMonitoring {
            AppLog.ui.info("User paused keyboard automation from launcher UI")
            FileDebugLog.record(level: "INFO", category: "UI", message: "User paused keyboard automation from launcher UI")
            automation.stop()
            isMonitoring = false
            updateMonitorToggleButton()
            refreshStatus("后台监听已暂停；快捷键暂时不会触发切换。")
            return
        }

        AppLog.ui.info("User started keyboard automation from launcher UI")
        FileDebugLog.record(level: "INFO", category: "UI", message: "User started keyboard automation from launcher UI")
        let started = automation.start()
        isMonitoring = started
        updateMonitorToggleButton()
        refreshStatus(started ? "后台监听已开启。" : "后台监听启动失败，请检查权限。")
    }

    @objc private func showHoldShortcutPicker(_ sender: NSButton) {
        showShortcutPicker(role: .hold, sourceButton: sender)
    }

    @objc private func showDoubleTapShortcutPicker(_ sender: NSButton) {
        showShortcutPicker(role: .doubleTap, sourceButton: sender)
    }

    private func showShortcutPicker(role: ShortcutRole, sourceButton: NSButton) {
        shortcutPickerPopover?.close()
        let currentShortcut: Shortcut
        let title: String
        switch role {
        case .hold:
            currentShortcut = holdShortcut
            title = "选择长按模式快捷键"
        case .doubleTap:
            currentShortcut = doubleTapShortcut
            title = "选择免按模式快捷键"
        }
        AppLog.ui.info("Open shortcut picker for role \(String(describing: role), privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Open shortcut picker for role \(String(describing: role))")

        let popover = NSPopover()
        let controller = ShortcutPickerViewController(title: title, currentShortcut: currentShortcut)
        controller.preferredContentSize = NSSize(width: 202, height: 150)
        controller.onApply = { [weak self, weak popover] shortcut in
            guard let self else {
                return
            }
            switch role {
            case .hold:
                self.holdShortcut = shortcut
                ShortcutDefaults.saveHoldShortcut(shortcut)
                AppLog.ui.info("Applied hold shortcut \(shortcut.logDescription, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "UI", message: "Applied hold shortcut \(shortcut.logDescription)")
                self.refreshStatus("已设置长按模式快捷键：\(shortcut.display)。")
            case .doubleTap:
                self.doubleTapShortcut = shortcut
                ShortcutDefaults.saveDoubleTapShortcut(shortcut)
                AppLog.ui.info("Applied double-tap shortcut \(shortcut.logDescription, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "UI", message: "Applied double-tap shortcut \(shortcut.logDescription)")
                self.refreshStatus("已设置免按模式快捷键：\(shortcut.display)。")
            }
            self.automation.updateShortcuts(hold: self.holdShortcut, doubleTap: self.doubleTapShortcut)
            self.updateShortcutButtons()
            popover?.close()
        }
        controller.onCancel = { [weak popover] in
            popover?.close()
        }
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 202, height: 150)
        popover.behavior = .transient
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .minX)
        shortcutPickerPopover = popover
    }

    @objc private func openDoubaoSettings() {
        let paths = [
            "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app",
            "/Library/Input Methods/豆包输入法.app/Contents/DoubaoImeSettings.app"
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            AppLog.ui.info("Opened Doubao settings at \(path, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "UI", message: "Opened Doubao settings at \(path)")
            refreshStatus("已尝试打开豆包设置。")
            return
        }
        AppLog.ui.error("Doubao settings app was not found")
        FileDebugLog.record(level: "ERROR", category: "UI", message: "Doubao settings app was not found")
        refreshStatus("未找到豆包设置页。")
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            AppLog.ui.error("Failed to build accessibility settings URL")
            FileDebugLog.record(level: "ERROR", category: "UI", message: "Failed to build accessibility settings URL")
            refreshStatus("无法打开辅助功能设置。")
            return
        }
        NSWorkspace.shared.open(url)
        AppLog.ui.info("Opened accessibility settings")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Opened accessibility settings")
        refreshStatus("请在辅助功能列表中打开 \(appDisplayName)；若已存在但无效，先移除再重新添加。")
    }

    @objc private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            AppLog.ui.error("Failed to build input monitoring settings URL")
            FileDebugLog.record(level: "ERROR", category: "UI", message: "Failed to build input monitoring settings URL")
            refreshStatus("无法打开输入监控设置。")
            return
        }
        NSWorkspace.shared.open(url)
        AppLog.ui.info("Opened input monitoring settings")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Opened input monitoring settings")
        refreshStatus("请在输入监控列表中打开 \(appDisplayName)；若列表中没有，请用加号添加当前 app。")
    }
}

private final class ShortcutPickerViewController: NSViewController {
    var onApply: ((Shortcut) -> Void)?
    var onCancel: (() -> Void)?

    private let panelTitle: String
    private let currentShortcut: Shortcut
    private let validationLabel = NSTextField(labelWithString: "")
    private var candidateButtons: [CGKeyCode: ShortcutChoiceButton] = [:]

    init(title: String, currentShortcut: Shortcut) {
        self.panelTitle = title
        self.currentShortcut = currentShortcut
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 202, height: 150))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.32).cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: panelTitle)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let descriptionLabel = NSTextField(labelWithString: "可多选组合键。")
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 6

        let currentKeyCodes = Set(currentShortcut.keyCodes)
        let candidates = ShortcutFormatter.candidates
        for rowIndex in stride(from: 0, to: candidates.count, by: 3) {
            let rowCandidates = Array(candidates[rowIndex..<min(rowIndex + 3, candidates.count)])
            let buttons = rowCandidates.map { candidate in
                let button = ShortcutChoiceButton(title: candidate.title)
                button.target = self
                button.action = #selector(candidateSelectionChanged)
                button.state = currentKeyCodes.contains(candidate.keyCode) ? .on : .off
                button.widthAnchor.constraint(equalToConstant: 54).isActive = true
                button.heightAnchor.constraint(equalToConstant: 23).isActive = true
                candidateButtons[candidate.keyCode] = button
                return button
            }
            grid.addRow(with: buttons)
        }

        validationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        validationLabel.textColor = .secondaryLabelColor
        refreshValidationText()

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded

        let applyButton = NSButton(title: "保存", target: self, action: #selector(applySelection))
        applyButton.bezelStyle = .rounded

        cancelButton.controlSize = .small
        applyButton.controlSize = .small
        cancelButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        applyButton.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let buttonRow = NSStackView(views: [validationLabel, cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fill
        validationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [titleLabel, descriptionLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 2
        headerStack.alignment = .leading

        let stack = NSStackView(views: [headerStack, grid, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 9
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
            grid.widthAnchor.constraint(equalToConstant: 174),
            buttonRow.widthAnchor.constraint(equalToConstant: 174)
        ])
    }

    @objc private func candidateSelectionChanged() {
        candidateButtons.values.forEach { $0.needsDisplay = true }
        refreshValidationText()
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    @objc private func applySelection() {
        let selectedKeyCodes = selectedCandidateKeyCodes()
        guard let shortcut = ShortcutFormatter.shortcut(fromCandidateKeyCodes: selectedKeyCodes) else {
            validationLabel.stringValue = "请至少选择一个候选按键。"
            validationLabel.textColor = .systemRed
            return
        }
        onApply?(shortcut)
    }

    private func selectedCandidateKeyCodes() -> [CGKeyCode] {
        ShortcutFormatter.candidates.compactMap { candidate in
            guard candidateButtons[candidate.keyCode]?.state == .on else {
                return nil
            }
            return candidate.keyCode
        }
    }

    private func refreshValidationText() {
        guard let shortcut = ShortcutFormatter.shortcut(fromCandidateKeyCodes: selectedCandidateKeyCodes()) else {
            validationLabel.stringValue = "当前未选择快捷键。"
            validationLabel.textColor = .secondaryLabelColor
            return
        }
        validationLabel.stringValue = "当前选择：\(shortcut.display)"
        validationLabel.textColor = .secondaryLabelColor
    }
}

private final class ShortcutChoiceButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.toggle)
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .medium)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let fillColor: NSColor = if selected {
            .systemBlue
        } else if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.10)
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        }
        fillColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(selected ? 0.0 : 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: selected ? NSColor.white : NSColor.controlTextColor
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}

private final class PrimaryActionButton: NSButton {
    var symbolName: String = "play.circle.fill" {
        didSet {
            needsDisplay = true
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        font = .systemFont(ofSize: 16, weight: .semibold)
        contentTintColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        bounds.insetBy(dx: 0.5, dy: 0.5).roundedPath(radius: 8).fill()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = title.size(withAttributes: textAttributes)
        let iconSize = NSSize(width: 16, height: 16)
        let spacing: CGFloat = 8
        let totalWidth = iconSize.width + spacing + textSize.width
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.midY

        let iconRect = NSRect(x: startX, y: centerY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
        if symbolName.contains("pause") {
            drawPauseGlyph(in: iconRect)
        } else {
            drawPlayGlyph(in: iconRect)
        }
        title.draw(
            at: NSPoint(x: startX + iconSize.width + spacing, y: centerY - textSize.height / 2),
            withAttributes: textAttributes
        )
    }

    private func drawPlayGlyph(in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        circle.fill()

        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.30))
        triangle.line(to: NSPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.70))
        triangle.line(to: NSPoint(x: rect.minX + rect.width * 0.72, y: rect.midY))
        triangle.close()
        NSColor.systemBlue.setFill()
        triangle.fill()
    }

    private func drawPauseGlyph(in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        circle.fill()

        let barWidth = rect.width * 0.15
        let barHeight = rect.height * 0.46
        let y = rect.midY - barHeight / 2
        let leftBar = NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.34, y: y, width: barWidth, height: barHeight), xRadius: 1.5, yRadius: 1.5)
        let rightBar = NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.54, y: y, width: barWidth, height: barHeight), xRadius: 1.5, yRadius: 1.5)
        NSColor.systemBlue.setFill()
        leftBar.fill()
        rightBar.fill()
    }
}

private final class ShortcutSelectButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 15, weight: .medium)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let fill = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.36)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.controlTextColor
        ]
        let textSize = title.size(withAttributes: textAttributes)
        let textX = max(12, (bounds.width - textSize.width) / 2 - 6)
        title.draw(
            at: NSPoint(x: textX, y: bounds.midY - textSize.height / 2),
            withAttributes: textAttributes
        )

        let badgeSize: CGFloat = 14
        let badgeRect = NSRect(
            x: bounds.maxX - badgeSize - 10,
            y: bounds.midY - badgeSize / 2,
            width: badgeSize,
            height: badgeSize
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.50).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let mark = NSBezierPath()
        mark.lineWidth = 1.6
        mark.lineCapStyle = .round
        mark.move(to: NSPoint(x: badgeRect.minX + 4.5, y: badgeRect.minY + 4.5))
        mark.line(to: NSPoint(x: badgeRect.maxX - 4.5, y: badgeRect.maxY - 4.5))
        mark.move(to: NSPoint(x: badgeRect.maxX - 4.5, y: badgeRect.minY + 4.5))
        mark.line(to: NSPoint(x: badgeRect.minX + 4.5, y: badgeRect.maxY - 4.5))
        NSColor.white.withAlphaComponent(0.92).setStroke()
        mark.stroke()
    }
}

private final class IconActionButton: NSButton {
    private let symbolName: String

    init(title: String, symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        controlSize = .large
        font = .systemFont(ofSize: 14, weight: .medium)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.controlTextColor
        ]
        let textSize = title.size(withAttributes: textAttributes)
        let iconSize = NSSize(width: 16, height: 16)
        let spacing: CGFloat = 7
        let totalWidth = iconSize.width + spacing + textSize.width
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.midY

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let imageRect = NSRect(x: startX, y: centerY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1.0 : 0.35)
        }

        title.draw(
            at: NSPoint(x: startX + iconSize.width + spacing, y: centerY - textSize.height / 2),
            withAttributes: textAttributes
        )
    }
}

private extension NSRect {
    func roundedPath(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: self, xRadius: radius, yRadius: radius)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("Application did finish launching")
        FileDebugLog.record(level: "INFO", category: "App", message: "Application did finish launching")
        NSApp.setActivationPolicy(.regular)
        let controller = LauncherViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: launcherWindowWidth, height: launcherWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appDisplayName
        window.titleVisibility = .hidden
        window.contentViewController = controller
        window.center()
        installCenteredTitle(in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        AppLog.app.info("Main window is visible")
        FileDebugLog.record(level: "INFO", category: "App", message: "Main window is visible")
    }

    private func installCenteredTitle(in window: NSWindow) {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else {
            return
        }
        let titleLabel = NSTextField(labelWithString: appDisplayName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titlebarView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor)
        ])
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
