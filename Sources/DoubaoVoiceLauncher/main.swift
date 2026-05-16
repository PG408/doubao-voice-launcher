import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

private let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let appDisplayName = "豆包语音输入切换"
private let appLogSubsystem = Bundle.main.bundleIdentifier ?? "com.local.doubao.voice-launcher"
private let launcherWindowWidth: CGFloat = 480
private let launcherWindowHeight: CGFloat = 538
private let launcherContentWidth: CGFloat = 450
private let designBorderColor = NSColor.black.withAlphaComponent(0.09)
private let designDividerColor = NSColor.black.withAlphaComponent(0.09)
private let designCardFillColor = NSColor.white.withAlphaComponent(0.64)
private let designSecondaryTextColor = NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.47, alpha: 1.0)
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

private let forwardedShortcutResumeDelay: TimeInterval = 0.20
private let inputSourcePollInterval: TimeInterval = 0.01
private let inputSourcePollTimeout: TimeInterval = 0.35

private enum ShortcutRole {
    case hold
    case doubleTap
    case singleTap
}

private enum VoiceSessionKind {
    case doubleTap
    case singleTap
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
    private static let singleTapKeyCodeKey = "singleTapShortcutKeyCode"
    private static let singleTapKeyCodesKey = "singleTapShortcutKeyCodes"
    private static let singleTapFlagsKey = "singleTapShortcutFlags"
    private static let singleTapDisplayKey = "singleTapShortcutDisplay"

    static func loadHoldShortcut() -> Shortcut? {
        load(keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
    }

    static func loadDoubleTapShortcut() -> Shortcut? {
        load(keyCodeKey: doubleKeyCodeKey, keyCodesKey: doubleKeyCodesKey, flagsKey: doubleFlagsKey, displayKey: doubleDisplayKey)
    }

    static func loadSingleTapShortcut() -> Shortcut? {
        load(keyCodeKey: singleTapKeyCodeKey, keyCodesKey: singleTapKeyCodesKey, flagsKey: singleTapFlagsKey, displayKey: singleTapDisplayKey)
    }

    static func saveHoldShortcut(_ shortcut: Shortcut?) {
        save(shortcut, keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
    }

    static func saveDoubleTapShortcut(_ shortcut: Shortcut?) {
        save(shortcut, keyCodeKey: doubleKeyCodeKey, keyCodesKey: doubleKeyCodesKey, flagsKey: doubleFlagsKey, displayKey: doubleDisplayKey)
    }

    static func saveSingleTapShortcut(_ shortcut: Shortcut?) {
        save(shortcut, keyCodeKey: singleTapKeyCodeKey, keyCodesKey: singleTapKeyCodesKey, flagsKey: singleTapFlagsKey, displayKey: singleTapDisplayKey)
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

    private static func save(_ shortcut: Shortcut?, keyCodeKey: String, keyCodesKey: String, flagsKey: String, displayKey: String) {
        let defaults = UserDefaults.standard
        guard let shortcut else {
            defaults.removeObject(forKey: keyCodeKey)
            defaults.removeObject(forKey: keyCodesKey)
            defaults.removeObject(forKey: flagsKey)
            defaults.removeObject(forKey: displayKey)
            AppLog.shortcut.info("Cleared shortcut for key \(displayKey, privacy: .public)")
            return
        }
        defaults.set(Int(shortcut.keyCode), forKey: keyCodeKey)
        defaults.set(shortcut.keyCodes.map(Int.init), forKey: keyCodesKey)
        defaults.set(Int(shortcut.flags.rawValue), forKey: flagsKey)
        defaults.set(shortcut.display, forKey: displayKey)
        AppLog.shortcut.info("Saved shortcut \(shortcut.logDescription, privacy: .public) for key \(displayKey, privacy: .public)")
    }
}

private enum TimingDefaults {
    static let minimumMilliseconds = 1
    static let maximumMilliseconds = 10_000
    static let defaultForwardDelayMilliseconds = 100
    static let defaultLongPressMilliseconds = 100
    static let defaultDoubleTapMilliseconds = 450

    private static let forwardDelayKey = "forwardDelayMilliseconds"
    private static let longPressDurationKey = "longPressDurationMilliseconds"
    private static let doubleTapIntervalKey = "doubleTapIntervalMilliseconds"

    static func loadForwardDelayMilliseconds() -> Int {
        loadMilliseconds(key: forwardDelayKey, defaultValue: defaultForwardDelayMilliseconds)
    }

    static func loadLongPressMilliseconds() -> Int {
        loadMilliseconds(key: longPressDurationKey, defaultValue: defaultLongPressMilliseconds)
    }

    static func loadDoubleTapMilliseconds() -> Int {
        loadMilliseconds(key: doubleTapIntervalKey, defaultValue: defaultDoubleTapMilliseconds)
    }

    static func saveForwardDelayMilliseconds(_ milliseconds: Int) {
        saveMilliseconds(milliseconds, key: forwardDelayKey)
    }

    static func saveLongPressMilliseconds(_ milliseconds: Int) {
        saveMilliseconds(milliseconds, key: longPressDurationKey)
    }

    static func saveDoubleTapMilliseconds(_ milliseconds: Int) {
        saveMilliseconds(milliseconds, key: doubleTapIntervalKey)
    }

    static func timeInterval(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampedMilliseconds(milliseconds)) / 1_000
    }

    static func clampedMilliseconds(_ milliseconds: Int) -> Int {
        min(max(milliseconds, minimumMilliseconds), maximumMilliseconds)
    }

    private static func loadMilliseconds(key: String, defaultValue: Int) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return clampedMilliseconds(defaults.integer(forKey: key))
    }

    private static func saveMilliseconds(_ milliseconds: Int, key: String) {
        let clampedValue = clampedMilliseconds(milliseconds)
        UserDefaults.standard.set(clampedValue, forKey: key)
        AppLog.shortcut.info("Saved timing \(clampedValue, privacy: .public) ms for key \(key, privacy: .public)")
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
    private var singleTapShortcut = ShortcutDefaults.loadSingleTapShortcut()
    private var forwardDelayMilliseconds = TimingDefaults.loadForwardDelayMilliseconds()
    private var longPressMilliseconds = TimingDefaults.loadLongPressMilliseconds()
    private var doubleTapMilliseconds = TimingDefaults.loadDoubleTapMilliseconds()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTriggerDown = false
    private var triggerDownAt: TimeInterval = 0
    private var lastShortTapUpAt: TimeInterval = 0
    private var sessionActive = false
    private var sessionKind: VoiceSessionKind?
    private var longPressWorkItem: DispatchWorkItem?
    private var didTriggerLongPress = false
    private var resumeEventTapWorkItem: DispatchWorkItem?
    private var isForwardingShortcut = false
    private var activeShortcut: Shortcut?
    private var sessionShortcut: Shortcut?
    private var activeModifierKeyCodes = Set<CGKeyCode>()
    private var activeSupportsLongPress = false
    private var activeSupportsDoubleTap = false
    private var activeSupportsSingleTap = false

    var onStatus: ((String) -> Void)?

    init(inputSourceService: InputSourceService) {
        self.inputSourceService = inputSourceService
    }

    private var forwardDelay: TimeInterval {
        TimingDefaults.timeInterval(milliseconds: forwardDelayMilliseconds)
    }

    private var longPressDuration: TimeInterval {
        TimingDefaults.timeInterval(milliseconds: longPressMilliseconds)
    }

    private var doubleTapInterval: TimeInterval {
        TimingDefaults.timeInterval(milliseconds: doubleTapMilliseconds)
    }

    private func logDescription(for shortcut: Shortcut?) -> String {
        shortcut?.logDescription ?? "not set"
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
        AppLog.automation.info("Keyboard automation started with hold \(self.logDescription(for: self.holdShortcut), privacy: .public), doubleTap \(self.logDescription(for: self.doubleTapShortcut), privacy: .public), singleTap \(self.logDescription(for: self.singleTapShortcut), privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation started with hold \(logDescription(for: holdShortcut)), doubleTap \(logDescription(for: doubleTapShortcut)), singleTap \(logDescription(for: singleTapShortcut))")
        onStatus?("后台监听已开启：已选择的快捷键会自动切到豆包，结束后恢复原输入法。")
        return true
    }

    func updateConfiguration(
        hold: Shortcut?,
        doubleTap: Shortcut?,
        singleTap: Shortcut?,
        forwardDelayMilliseconds: Int,
        longPressMilliseconds: Int,
        doubleTapMilliseconds: Int
    ) {
        holdShortcut = hold
        doubleTapShortcut = doubleTap
        singleTapShortcut = singleTap
        self.forwardDelayMilliseconds = TimingDefaults.clampedMilliseconds(forwardDelayMilliseconds)
        self.longPressMilliseconds = TimingDefaults.clampedMilliseconds(longPressMilliseconds)
        self.doubleTapMilliseconds = TimingDefaults.clampedMilliseconds(doubleTapMilliseconds)
        AppLog.automation.info("Updated automation configuration: hold \(self.logDescription(for: hold), privacy: .public), doubleTap \(self.logDescription(for: doubleTap), privacy: .public), singleTap \(self.logDescription(for: singleTap), privacy: .public), forwardDelay=\(self.forwardDelayMilliseconds, privacy: .public)ms, longPress=\(self.longPressMilliseconds, privacy: .public)ms, doubleTap=\(self.doubleTapMilliseconds, privacy: .public)ms")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Updated automation configuration: hold \(logDescription(for: hold)), doubleTap \(logDescription(for: doubleTap)), singleTap \(logDescription(for: singleTap)), forwardDelay=\(self.forwardDelayMilliseconds)ms, longPress=\(self.longPressMilliseconds)ms, doubleTap=\(self.doubleTapMilliseconds)ms")
    }

    func stop() {
        AppLog.automation.info("Stop keyboard automation requested")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Stop keyboard automation requested")
        resumeEventTapWorkItem?.cancel()
        resumeEventTapWorkItem = nil
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        if sessionActive {
            if let shortcut = sessionShortcut {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            sessionActive = false
            sessionKind = nil
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

        let holdKeyCodes = holdShortcut.map { Set($0.keyCodes) }
        let doubleTapKeyCodes = doubleTapShortcut.map { Set($0.keyCodes) }
        let singleTapKeyCodes = singleTapShortcut.map { Set($0.keyCodes) }
        let supportsLongPress = holdKeyCodes.map { $0.contains(keyCode) && activeModifierKeyCodes == $0 } ?? false
        let supportsDoubleTap = doubleTapKeyCodes.map { $0.contains(keyCode) && activeModifierKeyCodes == $0 } ?? false
        let supportsSingleTap = singleTapKeyCodes.map { $0.contains(keyCode) && activeModifierKeyCodes == $0 } ?? false
        let shortcut = supportsSingleTap ? singleTapShortcut : (supportsDoubleTap ? doubleTapShortcut : holdShortcut)
        if let shortcut, (supportsLongPress || supportsDoubleTap || supportsSingleTap) && !isTriggerDown {
            handleTriggerDown(
                shortcut: shortcut,
                supportsLongPress: supportsLongPress,
                supportsDoubleTap: supportsDoubleTap,
                supportsSingleTap: supportsSingleTap
            )
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
        guard sessionActive, sessionKind == .doubleTap else {
            return Unmanaged.passUnretained(event)
        }

        AppLog.automation.info("Detected regular key down while no-hold session is active; scheduling restore")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Detected regular key down while no-hold session is active; scheduling restore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let shortcut = self.sessionShortcut else {
                return
            }
            self.forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            _ = self.inputSourceService.restorePrevious()
            self.sessionActive = false
            self.sessionKind = nil
            self.sessionShortcut = nil
            self.onStatus?("检测到按键结束语音输入，已恢复原输入法。")
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        return Unmanaged.passUnretained(event)
    }

    private func handleTriggerDown(shortcut: Shortcut, supportsLongPress: Bool, supportsDoubleTap: Bool, supportsSingleTap: Bool) {
        isTriggerDown = true
        didTriggerLongPress = false
        activeShortcut = shortcut
        activeSupportsLongPress = supportsLongPress
        activeSupportsDoubleTap = supportsDoubleTap
        activeSupportsSingleTap = supportsSingleTap
        triggerDownAt = ProcessInfo.processInfo.systemUptime
        let pressStartedAt = triggerDownAt
        AppLog.automation.info("Shortcut trigger down: \(shortcut.logDescription, privacy: .public), longPress=\(supportsLongPress, privacy: .public), doubleTap=\(supportsDoubleTap, privacy: .public), singleTap=\(supportsSingleTap, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger down: \(shortcut.logDescription), longPress=\(supportsLongPress), doubleTap=\(supportsDoubleTap), singleTap=\(supportsSingleTap)")

        if sessionActive {
            AppLog.automation.info("Shortcut pressed while no-hold session is active")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut pressed while no-hold session is active")
            onStatus?("检测到快捷键按下，将结束双击模式语音输入。")
            return
        }

        guard supportsLongPress else {
            AppLog.automation.debug("Trigger does not support long press; waiting for tap flow")
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isTriggerDown else {
                return
            }
            let heldDuration = ProcessInfo.processInfo.systemUptime - pressStartedAt
            guard heldDuration >= self.longPressDuration else {
                return
            }
            guard self.inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Long press flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Long press flow failed to switch to Doubao input source")
                self.onStatus?("切换到豆包输入法失败。")
                return
            }
            self.waitForDoubaoInputSource {
                guard self.isTriggerDown, Set(self.activeShortcut?.keyCodes ?? []) == Set(shortcut.keyCodes) else {
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
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: workItem)
    }

    private func handleTriggerUp() {
        let now = ProcessInfo.processInfo.systemUptime
        isTriggerDown = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        guard let shortcut = activeShortcut else {
            resetActiveTrigger()
            return
        }
        let supportsDoubleTap = activeSupportsDoubleTap
        let supportsSingleTap = activeSupportsSingleTap
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
                self.sessionKind = nil
                self.sessionShortcut = nil
                AppLog.automation.info("No-hold flow stopped by shortcut; restoring previous input source")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold flow stopped by shortcut; restoring previous input source")
                self.restoreAfterDelay(message: "检测到快捷键单击结束双击模式语音输入，已恢复原输入法。", delay: 0.45)
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        if supportsSingleTap {
            guard inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Single-tap flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Single-tap flow failed to switch to Doubao input source")
                onStatus?("切换到豆包输入法失败。")
                return
            }
            waitForDoubaoInputSource {
                self.forwardShortcutEvent {
                    ShortcutSender.keyDown(shortcut: shortcut)
                }
                self.sessionActive = true
                self.sessionKind = .singleTap
                self.sessionShortcut = shortcut
                AppLog.automation.info("No-hold flow started by single tap with forwarded key down")
                FileDebugLog.record(
                    level: "INFO",
                    category: "Automation",
                    message: "No-hold flow started by single tap with forwarded key down"
                )
                self.onStatus?("检测到单击模式快捷键，已切到豆包并保持语音输入。")
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

        if now - lastShortTapUpAt <= doubleTapInterval {
            guard inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Double-tap flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Double-tap flow failed to switch to Doubao input source")
                onStatus?("切换到豆包输入法失败。")
                return
            }
            waitForDoubaoInputSource {
                self.forwardShortcutEvent {
                    ShortcutSender.keyDown(shortcut: shortcut)
                }
                self.sessionActive = true
                self.sessionKind = .doubleTap
                self.sessionShortcut = shortcut
                AppLog.automation.info("No-hold flow started by double tap with forwarded key down")
                FileDebugLog.record(
                    level: "INFO",
                    category: "Automation",
                    message: "No-hold flow started by double tap with forwarded key down"
                )
                self.onStatus?("检测到双击模式快捷键双击，已切到豆包并转发语音快捷键。")
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        lastShortTapUpAt = now
        resetActiveTrigger()
        AppLog.automation.info("First double-tap candidate recorded")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "First double-tap candidate recorded")
        onStatus?("检测到一次双击模式快捷键，等待第二次按下。")
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
        activeSupportsSingleTap = false
    }

    private func waitForDoubaoInputSource(
        timeout: TimeInterval = inputSourcePollTimeout,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        onReady: @escaping () -> Void
    ) {
        if inputSourceService.currentSourceID() == doubaoInputSourceID {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            AppLog.automation.info("Doubao input source confirmed after \(elapsed, privacy: .public) seconds; waiting for configured forward delay")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Doubao input source confirmed after \(elapsed) seconds; waiting \(forwardDelay) seconds before forwarding shortcut")
            DispatchQueue.main.asyncAfter(deadline: .now() + forwardDelay) {
                onReady()
            }
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard elapsed < timeout else {
            AppLog.automation.error("Timed out waiting for Doubao input source")
            FileDebugLog.record(level: "ERROR", category: "Automation", message: "Timed out waiting for Doubao input source after \(elapsed) seconds")
            onStatus?("已请求切换到豆包输入法，但未确认切换完成。")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) {
            self.waitForDoubaoInputSource(timeout: timeout, startedAt: startedAt, onReady: onReady)
        }
    }

}

private final class EditingDismissView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
}

private enum SettingsIconKind {
    case forwardDelay
    case singleTap
    case doubleTap
    case longPress

    var assetName: String {
        switch self {
        case .forwardDelay:
            return "icon-forward-delay"
        case .singleTap:
            return "icon-single-tap"
        case .doubleTap:
            return "icon-double-tap"
        case .longPress:
            return "icon-long-press"
        }
    }
}

private enum StatusIconKind {
    case wave
    case check
    case keyboard
}

private enum IconAssetLoader {
    static func image(named name: String) -> NSImage? {
        for fileExtension in ["pdf", "svg", "png"] {
            guard let assetURL = Bundle.main.url(forResource: name, withExtension: fileExtension),
                  let image = NSImage(contentsOf: assetURL) else {
                continue
            }
            return image
        }
        return nil
    }

    static func draw(_ image: NSImage, in rect: NSRect, fraction: CGFloat = 1.0, flippedVertically: Bool = false) {
        guard flippedVertically else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: rect.minY + rect.maxY)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        drawingRect.origin.y = rect.origin.y + floor((rect.height - textSize.height) / 2) + 0.5
        drawingRect.size.height = textSize.height
        return drawingRect
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

private final class TrafficLightStripView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = [
            NSColor(calibratedRed: 1.0, green: 0.372, blue: 0.341, alpha: 1.0),
            NSColor(calibratedRed: 0.996, green: 0.737, blue: 0.180, alpha: 1.0),
            NSColor(calibratedRed: 0.157, green: 0.784, blue: 0.251, alpha: 1.0)
        ]
        for (index, color) in colors.enumerated() {
            color.setFill()
            let rect = NSRect(x: CGFloat(index) * 20, y: 0, width: 12, height: 12)
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

private final class StatusIconView: NSView {
    private let kind: StatusIconKind
    var waveAssetName = "icon-status-wave-paused" {
        didSet {
            needsDisplay = true
        }
    }
    var waveColor = NSColor.systemRed {
        didSet {
            needsDisplay = true
        }
    }

    init(kind: StatusIconKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = kind == .wave ? waveColor : .systemBlue
        color.setStroke()
        color.setFill()
        switch kind {
        case .wave:
            if let image = IconAssetLoader.image(named: waveAssetName) {
                IconAssetLoader.draw(image, in: bounds)
                return
            }
            drawWave()
        case .check:
            drawCheck()
        case .keyboard:
            drawKeyboard()
        }
    }

    private func drawWave() {
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 3.0, y: 10.0))
        path.curve(to: NSPoint(x: 7.0, y: 10.0), controlPoint1: NSPoint(x: 4.3, y: 10.0), controlPoint2: NSPoint(x: 5.0, y: 5.5))
        path.curve(to: NSPoint(x: 10.0, y: 10.0), controlPoint1: NSPoint(x: 8.3, y: 13.0), controlPoint2: NSPoint(x: 8.7, y: 13.0))
        path.curve(to: NSPoint(x: 13.0, y: 10.0), controlPoint1: NSPoint(x: 11.3, y: 7.0), controlPoint2: NSPoint(x: 11.7, y: 7.0))
        path.curve(to: NSPoint(x: 17.0, y: 10.0), controlPoint1: NSPoint(x: 15.0, y: 14.5), controlPoint2: NSPoint(x: 15.7, y: 10.0))
        path.stroke()
    }

    private func drawCheck() {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
        circle.lineWidth = 1.8
        circle.stroke()

        let mark = NSBezierPath()
        mark.lineWidth = 1.8
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 6.4, y: 10.1))
        mark.line(to: NSPoint(x: 8.7, y: 7.8))
        mark.line(to: NSPoint(x: 13.4, y: 12.4))
        mark.stroke()
    }

    private func drawKeyboard() {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.2, dy: 5.1), xRadius: 2.0, yRadius: 2.0)
        body.lineWidth = 1.6
        body.stroke()

        let keyW: CGFloat = 2.0
        let keyH: CGFloat = 1.6
        for x in [5.0, 8.0, 11.0, 14.0] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 10.3, width: keyW, height: keyH), xRadius: 0.5, yRadius: 0.5).fill()
        }
        NSBezierPath(roundedRect: NSRect(x: 5.0, y: 7.5, width: 8.0, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
        NSBezierPath(roundedRect: NSRect(x: 13.7, y: 7.5, width: 1.8, height: 1.6), xRadius: 0.5, yRadius: 0.5).fill()
    }
}

private final class LauncherViewController: NSViewController, NSTextFieldDelegate {
    private enum TimingControlTag {
        static let forwardDelay = 1
        static let longPress = 2
        static let doubleTap = 3
    }

    private let inputSourceService = InputSourceService()
    private lazy var automation = RightControlAutomation(inputSourceService: inputSourceService)
    private var holdShortcut = ShortcutDefaults.loadHoldShortcut()
    private var doubleTapShortcut = ShortcutDefaults.loadDoubleTapShortcut()
    private var singleTapShortcut = ShortcutDefaults.loadSingleTapShortcut()
    private var forwardDelayMilliseconds = TimingDefaults.loadForwardDelayMilliseconds()
    private var longPressMilliseconds = TimingDefaults.loadLongPressMilliseconds()
    private var doubleTapMilliseconds = TimingDefaults.loadDoubleTapMilliseconds()
    private var statusMessage: String?
    private var shortcutPickerPopover: NSPopover?
    private var dismissEditingMonitor: Any?
    private var isMonitoring = false

    private let messageLabel = NSTextField(labelWithString: "")
    private let monitorStatusValueLabel = NSTextField(labelWithString: "")
    private let monitorStatusIconView = StatusIconView(kind: .wave)
    private let doubaoStatusValueLabel = NSTextField(labelWithString: "")
    private let currentInputValueLabel = NSTextField(labelWithString: "")
    private let holdShortcutButton = ShortcutSelectButton(title: "")
    private let doubleTapShortcutButton = ShortcutSelectButton(title: "")
    private let singleTapShortcutButton = ShortcutSelectButton(title: "")
    private let forwardDelayTextField = NSTextField(string: "")
    private let forwardDelayStepper = NSStepper()
    private let longPressTextField = NSTextField(string: "")
    private let longPressStepper = NSStepper()
    private let doubleTapTextField = NSTextField(string: "")
    private let doubleTapStepper = NSStepper()
    private let monitorToggleButton = PrimaryActionButton(title: "开始监听")
    private let monitorStatusDotView = EditingDismissView()

    override func loadView() {
        let root = EditingDismissView(frame: NSRect(x: 0, y: 0, width: launcherWindowWidth, height: launcherWindowHeight))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.962, green: 0.962, blue: 0.969, alpha: 1.0).cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        AppLog.ui.info("Launcher view did load")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Launcher view did load; file log path: \(FileDebugLog.fileURL.path)")
        buildUI()
        installDismissEditingMonitor()
        automation.onStatus = { [weak self] message in
            self?.refreshStatus(message)
        }
        syncAutomationConfiguration()
        let started = automation.start()
        isMonitoring = started
        updateMonitorToggleButton()
        AppLog.ui.info("Initial automation start result: \(started, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "UI", message: "Initial automation start result: \(started)")
        if started {
            refreshStatus("后台监听已开启。")
        }
    }

    deinit {
        if let dismissEditingMonitor {
            NSEvent.removeMonitor(dismissEditingMonitor)
        }
    }

    private func buildUI() {
        let chromeBar = makeChromeBar()

        let titleLabel = NSTextField(labelWithString: "豆包语音输入快速切换")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)

        let explanationLabel = NSTextField(labelWithString: "点击快捷键自动切换到豆包语音输入，输入结束后自动恢复原输入法")
        explanationLabel.font = .systemFont(ofSize: 14)
        explanationLabel.textColor = NSColor(calibratedRed: 0.39, green: 0.40, blue: 0.43, alpha: 0.90)
        explanationLabel.lineBreakMode = .byWordWrapping

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = designSecondaryTextColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.stringValue = "正在检查状态..."

        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(showHoldShortcutPicker(_:))

        doubleTapShortcutButton.target = self
        doubleTapShortcutButton.action = #selector(showDoubleTapShortcutPicker(_:))

        singleTapShortcutButton.target = self
        singleTapShortcutButton.action = #selector(showSingleTapShortcutPicker(_:))
        updateShortcutButtons()

        configureTimingControls()

        let openSettingsButton = IconActionButton(title: "豆包设置", symbolName: "slider.horizontal.3")
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openDoubaoSettings)

        let accessibilityButton = IconActionButton(title: "辅助功能", symbolName: "checkmark.shield")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)

        let inputMonitoringButton = IconActionButton(title: "输入监控", symbolName: "keyboard-clear")
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(openInputMonitoringSettings)

        monitorToggleButton.target = self
        monitorToggleButton.action = #selector(toggleMonitoring)
        updateMonitorToggleButton()

        [openSettingsButton, accessibilityButton, inputMonitoringButton].forEach(configureSecondaryButton)
        configureShortcutButton(holdShortcutButton)
        configureShortcutButton(doubleTapShortcutButton)
        configureShortcutButton(singleTapShortcutButton)

        let statusContent = makeStatusContent()
        let statusCard = makeRoundedContainer(content: statusContent, horizontalPadding: 11, verticalPadding: 6)
        statusCard.heightAnchor.constraint(equalToConstant: 66).isActive = true

        let settingsSectionTitle = NSTextField(labelWithString: "设置")
        settingsSectionTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let globalTimingCard = makeRoundedContainer(
            content: makeGlobalTimingRow(),
            horizontalPadding: 11,
            verticalPadding: 1
        )
        globalTimingCard.heightAnchor.constraint(equalToConstant: 41).isActive = true

        let shortcutContent = NSStackView(views: [
            makeShortcutRow(
                iconKind: .singleTap,
                title: "单击模式",
                prefix: "单击",
                button: singleTapShortcutButton,
                suffix: "开始，再按结束",
                timingView: nil
            ),
            makeHorizontalDivider(),
            makeShortcutRow(
                iconKind: .doubleTap,
                title: "双击模式",
                prefix: "双击",
                button: doubleTapShortcutButton,
                suffix: "开始，再按结束，双击间隔",
                timingView: makeTimingControl(title: "双击最短间隔", textField: doubleTapTextField, stepper: doubleTapStepper),
                timingWidth: 78
            ),
            makeHorizontalDivider(),
            makeShortcutRow(
                iconKind: .longPress,
                title: "长按模式",
                prefix: "长按",
                button: holdShortcutButton,
                suffix: "开始，再按结束，长按时长",
                timingView: makeTimingControl(title: "长按触发时长", textField: longPressTextField, stepper: longPressStepper),
                timingWidth: 78
            )
        ])
        shortcutContent.orientation = .vertical
        shortcutContent.spacing = 4
        shortcutContent.alignment = .leading
        let shortcutCard = makeRoundedContainer(content: shortcutContent, horizontalPadding: 10, verticalPadding: 5)
        shortcutCard.heightAnchor.constraint(equalToConstant: 133).isActive = true

        let secondaryButtonRow = makeBottomActionBar(buttons: [openSettingsButton, accessibilityButton, inputMonitoringButton])

        let headerStack = NSStackView(views: [titleLabel, explanationLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 7
        headerStack.alignment = .leading

        let stack = NSStackView(views: [headerStack, statusCard, monitorToggleButton, settingsSectionTitle, globalTimingCard, shortcutCard])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: headerStack)
        stack.setCustomSpacing(15, after: statusCard)
        stack.setCustomSpacing(24, after: monitorToggleButton)
        stack.setCustomSpacing(8, after: settingsSectionTitle)
        stack.setCustomSpacing(7, after: globalTimingCard)

        view.addSubview(chromeBar)
        view.addSubview(stack)
        view.addSubview(secondaryButtonRow)
        NSLayoutConstraint.activate([
            chromeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            chromeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            chromeBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            chromeBar.heightAnchor.constraint(equalToConstant: 29),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 59),
            headerStack.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            statusCard.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            monitorToggleButton.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            monitorToggleButton.heightAnchor.constraint(equalToConstant: 36.5),
            settingsSectionTitle.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            globalTimingCard.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            shortcutCard.widthAnchor.constraint(equalToConstant: launcherContentWidth),
            secondaryButtonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secondaryButtonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secondaryButtonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            secondaryButtonRow.heightAnchor.constraint(equalToConstant: 37)
        ])
    }

    private func makeChromeBar() -> NSView {
        let titleLabel = NSTextField(labelWithString: appDisplayName)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.86)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let trafficLights = TrafficLightStripView()
        trafficLights.translatesAutoresizingMaskIntoConstraints = false

        let bar = EditingDismissView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.984, alpha: 0.92).cgColor

        let bottomLine = EditingDismissView()
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        bar.addSubview(trafficLights)
        bar.addSubview(titleLabel)
        bar.addSubview(bottomLine)
        NSLayoutConstraint.activate([
            trafficLights.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            trafficLights.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 1),
            trafficLights.widthAnchor.constraint(equalToConstant: 52),
            trafficLights.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 1),
            bottomLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1)
        ])
        return bar
    }

    private func makeRoundedContainer(content: NSView, horizontalPadding: CGFloat, verticalPadding: CGFloat) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = EditingDismissView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = designBorderColor.cgColor
        card.layer?.backgroundColor = designCardFillColor.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.04
        card.layer?.shadowRadius = 20
        card.layer?.shadowOffset = CGSize(width: 0, height: -10)
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: horizontalPadding),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -horizontalPadding),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: verticalPadding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -verticalPadding)
        ])
        return card
    }

    private func makeStatusContent() -> NSView {
        let runningItem = makeStatusItem(
            icon: monitorStatusIconView,
            valueLabel: monitorStatusValueLabel,
            caption: "运行状态",
            showsDot: false,
            iconLeading: 23.5,
            textLeading: 48.5
        )
        let installedItem = makeStatusItem(
            icon: StatusIconView(kind: .check),
            valueLabel: doubaoStatusValueLabel,
            caption: "豆包输入法",
            showsDot: false,
            iconLeading: 17.5,
            textLeading: 42.5
        )
        let inputItem = makeStatusItem(
            icon: StatusIconView(kind: .keyboard),
            valueLabel: currentInputValueLabel,
            caption: "当前输入源",
            showsDot: false,
            iconLeading: 5,
            textLeading: 30
        )
        let firstDivider = makeVerticalDivider()
        let secondDivider = makeVerticalDivider()
        let content = EditingDismissView()
        [runningItem, firstDivider, installedItem, secondDivider, inputItem].forEach {
            content.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        content.widthAnchor.constraint(equalToConstant: 428).isActive = true
        content.heightAnchor.constraint(equalToConstant: 54).isActive = true
        NSLayoutConstraint.activate([
            runningItem.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            runningItem.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            firstDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 136.5),
            firstDivider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            installedItem.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 154),
            installedItem.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            secondDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 290.5),
            secondDivider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            inputItem.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 308),
            inputItem.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return content
    }

    private func makeStatusItem(
        icon: StatusIconView,
        valueLabel: NSTextField,
        caption: String,
        showsDot: Bool,
        iconLeading: CGFloat,
        textLeading: CGFloat
    ) -> NSView {
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        valueLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let valueRow = NSStackView(views: [valueLabel])
        valueRow.orientation = .horizontal
        valueRow.spacing = 5
        if showsDot {
            monitorStatusDotView.wantsLayer = true
            monitorStatusDotView.layer?.cornerRadius = 3
            monitorStatusDotView.layer?.backgroundColor = NSColor.systemRed.cgColor
            monitorStatusDotView.widthAnchor.constraint(equalToConstant: 6).isActive = true
            monitorStatusDotView.heightAnchor.constraint(equalToConstant: 6).isActive = true
            valueRow.addArrangedSubview(monitorStatusDotView)
        }

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = NSColor.labelColor.withAlphaComponent(0.52)

        let textStack = NSStackView(views: [valueRow, captionLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let container = EditingDismissView()
        container.addSubview(icon)
        container.addSubview(textStack)
        icon.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 120),
            container.heightAnchor.constraint(equalToConstant: 54),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: iconLeading),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: textLeading),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.widthAnchor.constraint(equalToConstant: 78)
        ])
        return container
    }

    private func makeGlobalTimingRow() -> NSView {
        let icon = SettingsRowIconView(kind: .forwardDelay)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = NSTextField(labelWithString: "转发延迟")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let detailLabel = NSTextField(labelWithString: "切换到豆包输入法")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = designSecondaryTextColor
        detailLabel.lineBreakMode = .byClipping
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let valueView = makeTimingValueEditor(textField: forwardDelayTextField, stepper: forwardDelayStepper)
        valueView.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let suffixLabel = NSTextField(labelWithString: "后触发语音输入")
        suffixLabel.font = .systemFont(ofSize: 11.5)
        suffixLabel.textColor = NSColor.labelColor.withAlphaComponent(0.54)

        let sentence = NSStackView(views: [detailLabel, valueView, suffixLabel])
        sentence.orientation = .horizontal
        sentence.spacing = 3
        sentence.alignment = .centerY
        sentence.distribution = .fill
        sentence.widthAnchor.constraint(equalToConstant: 278).isActive = true

        let row = EditingDismissView()
        row.addSubview(icon)
        row.addSubview(titleLabel)
        row.addSubview(sentence)
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sentence.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 428).isActive = true
        row.heightAnchor.constraint(equalToConstant: 39).isActive = true
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 30),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sentence.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 150),
            sentence.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeShortcutRow(
        iconKind: SettingsIconKind,
        title: String,
        prefix: String,
        button: NSButton,
        suffix: String,
        timingView: NSView?,
        timingWidth: CGFloat = 0
    ) -> NSView {
        let icon = SettingsRowIconView(kind: iconKind)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let prefixLabel = NSTextField(labelWithString: prefix)
        prefixLabel.font = .systemFont(ofSize: 9.5)
        prefixLabel.textColor = designSecondaryTextColor
        prefixLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = .systemFont(ofSize: 9.5)
        suffixLabel.textColor = designSecondaryTextColor
        suffixLabel.lineBreakMode = .byTruncatingTail
        suffixLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false

        let row = EditingDismissView()
        [icon, titleLabel, prefixLabel, button, suffixLabel].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        row.widthAnchor.constraint(equalToConstant: 430).isActive = true
        row.heightAnchor.constraint(equalToConstant: 35).isActive = true
        var constraints: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 29),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            prefixLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 152),
            prefixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 175),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            suffixLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 228),
            suffixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ]
        if let timingView {
            timingView.translatesAutoresizingMaskIntoConstraints = false
            timingView.widthAnchor.constraint(equalToConstant: timingWidth).isActive = true
            row.addSubview(timingView)
            constraints.append(contentsOf: [
                suffixLabel.widthAnchor.constraint(equalToConstant: 120),
                timingView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 351),
                timingView.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
        } else {
            constraints.append(suffixLabel.widthAnchor.constraint(equalToConstant: 140))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func makeTimingControl(title _: String, textField: NSTextField, stepper: NSStepper) -> NSView {
        makeTimingValueEditor(textField: textField, stepper: stepper)
    }

    private func makeEmptyTimingPlaceholder() -> NSView {
        let placeholder = EditingDismissView()
        placeholder.widthAnchor.constraint(equalToConstant: 172).isActive = true
        placeholder.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return placeholder
    }

    private func makeTimingValueEditor(textField: NSTextField, stepper: NSStepper) -> NSView {
        textField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        textField.heightAnchor.constraint(equalToConstant: 25).isActive = true
        stepper.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stepper.heightAnchor.constraint(equalToConstant: 20).isActive = true
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        stepper.setContentCompressionResistancePriority(.required, for: .horizontal)

        let unitLabel = NSTextField(labelWithString: "ms")
        unitLabel.font = .systemFont(ofSize: 12)
        unitLabel.textColor = NSColor.labelColor.withAlphaComponent(0.52)

        let row = NSStackView(views: [textField, stepper, unitLabel])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.distribution = .fill
        stepper.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func makeVerticalDivider() -> NSView {
        let divider = EditingDismissView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.11).cgColor
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return divider
    }

    private func makeHorizontalDivider() -> NSView {
        let divider = EditingDismissView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = designDividerColor.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 430).isActive = true
        return divider
    }

    private func configureSecondaryButton(_ button: NSButton) {
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    private func makeBottomActionBar(buttons: [NSButton]) -> NSView {
        let topDivider = EditingDismissView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.11).cgColor

        let dividers = (0..<max(0, buttons.count - 1)).map { _ -> NSView in
            let divider = EditingDismissView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
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

        let bar = EditingDismissView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.985, alpha: 0.74).cgColor
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
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.widthAnchor.constraint(equalToConstant: 50).isActive = true
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureTimingControls() {
        configureTimingPair(
            textField: forwardDelayTextField,
            stepper: forwardDelayStepper,
            tag: TimingControlTag.forwardDelay,
            value: forwardDelayMilliseconds
        )
        configureTimingPair(
            textField: longPressTextField,
            stepper: longPressStepper,
            tag: TimingControlTag.longPress,
            value: longPressMilliseconds
        )
        configureTimingPair(
            textField: doubleTapTextField,
            stepper: doubleTapStepper,
            tag: TimingControlTag.doubleTap,
            value: doubleTapMilliseconds
        )
    }

    private func installDismissEditingMonitor() {
        dismissEditingMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window == self.view.window else {
                return event
            }
            guard self.view.window?.firstResponder is NSTextView else {
                return event
            }

            let point = self.view.convert(event.locationInWindow, from: nil)
            guard let hitView = self.view.hitTest(point), !self.isTimingTextField(hitView) else {
                return event
            }

            self.view.window?.makeFirstResponder(nil)
            return event
        }
    }

    private func isTimingTextField(_ view: NSView) -> Bool {
        let timingTextFields = [forwardDelayTextField, longPressTextField, doubleTapTextField]
        return timingTextFields.contains { textField in
            view === textField || view.isDescendant(of: textField)
        }
    }

    private func configureTimingPair(textField: NSTextField, stepper: NSStepper, tag: Int, value: Int) {
        let centeredCell = CenteredTextFieldCell(textCell: "")
        centeredCell.alignment = .center
        centeredCell.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        centeredCell.isEditable = true
        centeredCell.isSelectable = true
        centeredCell.isScrollable = true
        centeredCell.usesSingleLineMode = true
        centeredCell.lineBreakMode = .byClipping
        textField.cell = centeredCell
        textField.tag = tag
        textField.delegate = self
        textField.alignment = .center
        textField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        textField.controlSize = .small
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = true
        textField.backgroundColor = NSColor(calibratedRed: 0.962, green: 0.965, blue: 0.969, alpha: 1.0)
        textField.focusRingType = .none
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 6
        textField.layer?.borderWidth = 1
        textField.layer?.borderColor = NSColor(calibratedRed: 0.878, green: 0.890, blue: 0.906, alpha: 1.0).cgColor
        textField.formatter = makeMillisecondsFormatter()
        textField.target = self
        textField.action = #selector(timingTextFieldSubmitted(_:))
        textField.integerValue = TimingDefaults.clampedMilliseconds(value)

        stepper.tag = tag
        stepper.controlSize = .small
        stepper.minValue = Double(TimingDefaults.minimumMilliseconds)
        stepper.maxValue = Double(TimingDefaults.maximumMilliseconds)
        stepper.increment = 10
        stepper.integerValue = TimingDefaults.clampedMilliseconds(value)
        stepper.target = self
        stepper.action = #selector(timingStepperChanged(_:))
    }

    private func makeMillisecondsFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: TimingDefaults.minimumMilliseconds)
        formatter.maximum = NSNumber(value: TimingDefaults.maximumMilliseconds)
        formatter.generatesDecimalNumbers = false
        return formatter
    }

    @objc private func timingStepperChanged(_ sender: NSStepper) {
        applyTimingValue(sender.integerValue, tag: sender.tag)
    }

    @objc private func timingTextFieldSubmitted(_ sender: NSTextField) {
        applyTimingValue(sender.integerValue, tag: sender.tag)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else {
            return
        }
        applyTimingValue(textField.integerValue, tag: textField.tag)
    }

    private func applyTimingValue(_ rawValue: Int, tag: Int) {
        let value = TimingDefaults.clampedMilliseconds(rawValue)
        switch tag {
        case TimingControlTag.forwardDelay:
            forwardDelayMilliseconds = value
            TimingDefaults.saveForwardDelayMilliseconds(value)
            forwardDelayTextField.integerValue = value
            forwardDelayStepper.integerValue = value
            refreshStatus("已更新转发延迟：\(value) ms。")
        case TimingControlTag.longPress:
            longPressMilliseconds = value
            TimingDefaults.saveLongPressMilliseconds(value)
            longPressTextField.integerValue = value
            longPressStepper.integerValue = value
            refreshStatus("已更新长按触发时长：\(value) ms。")
        case TimingControlTag.doubleTap:
            doubleTapMilliseconds = value
            TimingDefaults.saveDoubleTapMilliseconds(value)
            doubleTapTextField.integerValue = value
            doubleTapStepper.integerValue = value
            refreshStatus("已更新双击最短间隔：\(value) ms。")
        default:
            return
        }
        syncAutomationConfiguration()
    }

    private func syncAutomationConfiguration() {
        automation.updateConfiguration(
            hold: holdShortcut,
            doubleTap: doubleTapShortcut,
            singleTap: singleTapShortcut,
            forwardDelayMilliseconds: forwardDelayMilliseconds,
            longPressMilliseconds: longPressMilliseconds,
            doubleTapMilliseconds: doubleTapMilliseconds
        )
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
        monitorStatusIconView.waveAssetName = isMonitoring ? "icon-status-wave-listening" : "icon-status-wave-paused"
        monitorStatusIconView.waveColor = isMonitoring
            ? NSColor(calibratedRed: 0.09, green: 0.72, blue: 0.33, alpha: 1.0)
            : .systemRed
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
        holdShortcutButton.title = holdShortcut?.display ?? "快捷键"
        doubleTapShortcutButton.title = doubleTapShortcut?.display ?? "快捷键"
        singleTapShortcutButton.title = singleTapShortcut?.display ?? "快捷键"
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

    @objc private func showSingleTapShortcutPicker(_ sender: NSButton) {
        showShortcutPicker(role: .singleTap, sourceButton: sender)
    }

    private func showShortcutPicker(role: ShortcutRole, sourceButton: NSButton) {
        shortcutPickerPopover?.close()
        let currentShortcut: Shortcut?
        let title: String
        switch role {
        case .hold:
            currentShortcut = holdShortcut
            title = "选择长按模式快捷键"
        case .doubleTap:
            currentShortcut = doubleTapShortcut
            title = "选择双击模式快捷键"
        case .singleTap:
            currentShortcut = singleTapShortcut
            title = "选择单击模式快捷键"
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
            let shortcutDisplay = shortcut?.display ?? "未设置"
            let shortcutLog = shortcut?.logDescription ?? "not set"
            switch role {
            case .hold:
                self.holdShortcut = shortcut
                ShortcutDefaults.saveHoldShortcut(shortcut)
                AppLog.ui.info("Applied hold shortcut \(shortcutLog, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "UI", message: "Applied hold shortcut \(shortcutLog)")
                self.refreshStatus("已设置长按模式快捷键：\(shortcutDisplay)。")
            case .doubleTap:
                self.doubleTapShortcut = shortcut
                ShortcutDefaults.saveDoubleTapShortcut(shortcut)
                AppLog.ui.info("Applied double-tap shortcut \(shortcutLog, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "UI", message: "Applied double-tap shortcut \(shortcutLog)")
                self.refreshStatus("已设置双击模式快捷键：\(shortcutDisplay)。")
            case .singleTap:
                self.singleTapShortcut = shortcut
                ShortcutDefaults.saveSingleTapShortcut(shortcut)
                AppLog.ui.info("Applied single-tap shortcut \(shortcutLog, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "UI", message: "Applied single-tap shortcut \(shortcutLog)")
                self.refreshStatus("已设置单击模式快捷键：\(shortcutDisplay)。")
            }
            self.syncAutomationConfiguration()
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
    var onApply: ((Shortcut?) -> Void)?
    var onCancel: (() -> Void)?

    private let panelTitle: String
    private let currentShortcut: Shortcut?
    private let validationLabel = NSTextField(labelWithString: "")
    private var candidateButtons: [CGKeyCode: ShortcutChoiceButton] = [:]

    init(title: String, currentShortcut: Shortcut?) {
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

        let currentKeyCodes = Set(currentShortcut?.keyCodes ?? [])
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
        onApply?(ShortcutFormatter.shortcut(fromCandidateKeyCodes: selectedKeyCodes))
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
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(srgbRed: 0.0, green: 0.42, blue: 0.94, alpha: 1.0).cgColor
        layer?.shadowColor = NSColor(srgbRed: 0.0, green: 0.45, blue: 0.92, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        font = .systemFont(ofSize: 15, weight: .semibold)
        contentTintColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = bounds.insetBy(dx: 0.5, dy: 0.5).roundedPath(radius: 9)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.03, green: 0.51, blue: 0.98, alpha: 1.0),
            ending: NSColor(srgbRed: 0.0, green: 0.44, blue: 0.92, alpha: 1.0)
        )
        gradient?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
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
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor(calibratedRed: 0.962, green: 0.965, blue: 0.969, alpha: 1.0)
        fill.setFill()
        path.fill()
        NSColor(calibratedRed: 0.83, green: 0.84, blue: 0.86, alpha: 1.0).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.86)
        ]
        let displayTitle = title.count > 5 ? String(title.prefix(5)) : title
        let textSize = displayTitle.size(withAttributes: textAttributes)
        displayTitle.draw(
            at: NSPoint(x: (bounds.width - textSize.width) / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: textAttributes
        )
    }
}

private final class SettingsRowIconView: NSView {
    private let kind: SettingsIconKind

    init(kind: SettingsIconKind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = IconAssetLoader.image(named: kind.assetName) {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }

        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        iconGradient.draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        switch kind {
        case .forwardDelay:
            drawHourglass(in: rect)
        case .singleTap:
            drawCursor(in: rect, offset: .zero, alpha: 1.0)
        case .doubleTap:
            drawCursor(in: rect, offset: NSPoint(x: -2.1, y: 2.0), alpha: 0.58)
            drawCursor(in: rect, offset: NSPoint(x: 1.0, y: -0.9), alpha: 1.0)
        case .longPress:
            drawFinger(in: rect)
        }
    }

    private var iconGradient: NSGradient {
        switch kind {
        case .forwardDelay:
            return NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.25, alpha: 1), ending: NSColor(calibratedRed: 1.0, green: 0.54, blue: 0.0, alpha: 1))!
        case .singleTap:
            return NSGradient(starting: NSColor(calibratedRed: 0.34, green: 0.85, blue: 0.47, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.63, blue: 0.31, alpha: 1))!
        case .doubleTap:
            return NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.66, blue: 1.0, alpha: 1), ending: NSColor(calibratedRed: 0.0, green: 0.40, blue: 0.84, alpha: 1))!
        case .longPress:
            return NSGradient(starting: NSColor(calibratedRed: 0.78, green: 0.49, blue: 1.0, alpha: 1), ending: NSColor(calibratedRed: 0.49, green: 0.24, blue: 0.80, alpha: 1))!
        }
    }

    private func drawHourglass(in rect: NSRect) {
        let stroke = NSBezierPath()
        stroke.lineWidth = 1.6
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round
        stroke.move(to: NSPoint(x: rect.minX + 6.3, y: rect.maxY - 5.0))
        stroke.line(to: NSPoint(x: rect.maxX - 6.3, y: rect.maxY - 5.0))
        stroke.move(to: NSPoint(x: rect.minX + 6.3, y: rect.minY + 5.0))
        stroke.line(to: NSPoint(x: rect.maxX - 6.3, y: rect.minY + 5.0))
        stroke.move(to: NSPoint(x: rect.minX + 7.1, y: rect.maxY - 6.0))
        stroke.curve(
            to: NSPoint(x: rect.maxX - 7.1, y: rect.minY + 6.0),
            controlPoint1: NSPoint(x: rect.minX + 7.5, y: rect.maxY - 9.0),
            controlPoint2: NSPoint(x: rect.maxX - 7.5, y: rect.minY + 9.0)
        )
        stroke.move(to: NSPoint(x: rect.maxX - 7.1, y: rect.maxY - 6.0))
        stroke.curve(
            to: NSPoint(x: rect.minX + 7.1, y: rect.minY + 6.0),
            controlPoint1: NSPoint(x: rect.maxX - 7.5, y: rect.maxY - 9.0),
            controlPoint2: NSPoint(x: rect.minX + 7.5, y: rect.minY + 9.0)
        )
        NSColor.white.setStroke()
        stroke.stroke()
    }

    private func drawCursor(in rect: NSRect, offset: NSPoint, alpha: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 5.2 + offset.x, y: rect.maxY - 4.0 + offset.y))
        path.line(to: NSPoint(x: rect.maxX - 4.0 + offset.x, y: rect.midY + 0.3 + offset.y))
        path.line(to: NSPoint(x: rect.maxX - 7.7 + offset.x, y: rect.midY - 1.0 + offset.y))
        path.line(to: NSPoint(x: rect.maxX - 5.1 + offset.x, y: rect.minY + 4.0 + offset.y))
        path.line(to: NSPoint(x: rect.maxX - 7.2 + offset.x, y: rect.minY + 3.0 + offset.y))
        path.line(to: NSPoint(x: rect.maxX - 9.9 + offset.x, y: rect.midY - 2.1 + offset.y))
        path.line(to: NSPoint(x: rect.minX + 7.0 + offset.x, y: rect.minY + 6.4 + offset.y))
        path.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawFinger(in rect: NSRect) {
        let finger = NSBezierPath()
        finger.lineWidth = 2.05
        finger.lineJoinStyle = .round
        finger.lineCapStyle = .round
        finger.move(to: NSPoint(x: rect.midX - 0.7, y: rect.minY + 4.6))
        finger.line(to: NSPoint(x: rect.midX - 0.7, y: rect.maxY - 5.1))
        finger.curve(
            to: NSPoint(x: rect.midX + 2.0, y: rect.maxY - 5.1),
            controlPoint1: NSPoint(x: rect.midX - 0.7, y: rect.maxY - 3.5),
            controlPoint2: NSPoint(x: rect.midX + 2.0, y: rect.maxY - 3.5)
        )
        finger.line(to: NSPoint(x: rect.midX + 2.0, y: rect.midY - 0.5))
        finger.line(to: NSPoint(x: rect.maxX - 5.0, y: rect.midY + 0.8))
        finger.curve(
            to: NSPoint(x: rect.maxX - 3.7, y: rect.midY - 1.6),
            controlPoint1: NSPoint(x: rect.maxX - 3.6, y: rect.midY + 0.9),
            controlPoint2: NSPoint(x: rect.maxX - 3.0, y: rect.midY - 0.4)
        )
        finger.line(to: NSPoint(x: rect.maxX - 5.0, y: rect.minY + 4.1))
        finger.curve(
            to: NSPoint(x: rect.midX - 0.6, y: rect.minY + 3.4),
            controlPoint1: NSPoint(x: rect.maxX - 6.2, y: rect.minY + 2.6),
            controlPoint2: NSPoint(x: rect.midX + 1.3, y: rect.minY + 2.5)
        )
        finger.line(to: NSPoint(x: rect.minX + 6.0, y: rect.minY + 5.8))
        NSColor.white.setStroke()
        finger.stroke()

        let pulse = NSBezierPath()
        pulse.lineWidth = 1.0
        pulse.lineCapStyle = .round
        pulse.move(to: NSPoint(x: rect.minX + 6.0, y: rect.maxY - 6.0))
        pulse.curve(
            to: NSPoint(x: rect.minX + 5.9, y: rect.midY + 0.4),
            controlPoint1: NSPoint(x: rect.minX + 4.7, y: rect.maxY - 7.4),
            controlPoint2: NSPoint(x: rect.minX + 4.5, y: rect.midY + 2.0)
        )
        NSColor.white.withAlphaComponent(0.62).setStroke()
        pulse.stroke()
    }
}

private final class IconActionButton: NSButton {
    private let symbolName: String

    private var assetName: String? {
        switch symbolName {
        case "checkmark.shield":
            return "icon-footer-accessibility"
        case "keyboard-clear":
            return "icon-footer-input-monitoring"
        default:
            return nil
        }
    }

    init(title: String, symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        controlSize = .large
        font = .systemFont(ofSize: 13, weight: .semibold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
        ]
        let textSize = title.size(withAttributes: textAttributes)
        let iconSize = NSSize(width: 16, height: 16)
        let spacing: CGFloat = 7
        let totalWidth = iconSize.width + spacing + textSize.width
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.midY

        let imageRect = NSRect(x: startX, y: centerY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
        if let assetName,
           let image = IconAssetLoader.image(named: assetName) {
            IconAssetLoader.draw(image, in: imageRect, fraction: isEnabled ? 1.0 : 0.35, flippedVertically: true)
        } else if symbolName == "keyboard-clear" {
            drawClearKeyboard(in: imageRect)
        } else if symbolName == "slider.horizontal.3" {
            drawSliders(in: imageRect)
        } else if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1.0 : 0.35)
        }

        title.draw(
            at: NSPoint(x: startX + iconSize.width + spacing, y: centerY - textSize.height / 2),
            withAttributes: textAttributes
        )
    }

    private func drawClearKeyboard(in rect: NSRect) {
        let color = NSColor.controlTextColor.withAlphaComponent(0.88)
        color.setStroke()
        color.setFill()

        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1.8, dy: 3.6), xRadius: 2.1, yRadius: 2.1)
        body.lineWidth = 1.45
        body.stroke()

        for x in [rect.minX + 4.0, rect.minX + 7.2, rect.minX + 10.45] {
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 8.8, width: 1.55, height: 1.55), xRadius: 0.45, yRadius: 0.45).fill()
        }
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 4.0, y: rect.minY + 5.55, width: 5.25, height: 1.35), xRadius: 0.65, yRadius: 0.65).fill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 10.45, y: rect.minY + 5.55, width: 1.55, height: 1.35), xRadius: 0.45, yRadius: 0.45).fill()
    }

    private func drawSliders(in rect: NSRect) {
        let color = NSColor.controlTextColor.withAlphaComponent(0.88)
        color.setStroke()
        color.setFill()

        func line(from x1: CGFloat, to x2: CGFloat, y: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = 1.55
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x1, y: y))
            path.line(to: NSPoint(x: x2, y: y))
            path.stroke()
        }

        line(from: rect.minX + 2.4, to: rect.minX + 6.2, y: rect.minY + 11.75)
        line(from: rect.minX + 9.75, to: rect.minX + 13.6, y: rect.minY + 11.75)
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 6.6, y: rect.minY + 10.4, width: 2.7, height: 2.7)).stroke()

        line(from: rect.minX + 2.4, to: rect.minX + 3.95, y: rect.minY + 8)
        line(from: rect.minX + 7.5, to: rect.minX + 13.6, y: rect.minY + 8)
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 4.3, y: rect.minY + 6.65, width: 2.7, height: 2.7)).stroke()

        line(from: rect.minX + 2.4, to: rect.minX + 8.2, y: rect.minY + 4.25)
        line(from: rect.minX + 11.75, to: rect.minX + 13.6, y: rect.minY + 4.25)
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 8.6, y: rect.minY + 2.9, width: 2.7, height: 2.7)).stroke()
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: launcherWindowWidth, height: launcherWindowHeight)
        window.contentMaxSize = NSSize(width: launcherWindowWidth, height: launcherWindowHeight)
        window.title = appDisplayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
        window.contentViewController = controller
        window.center()
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
