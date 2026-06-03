import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import Darwin
import DoubaoVoiceLauncherCore
import Foundation
import OSLog

private let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let appDisplayName = "豆包语音输入切换"
private let appLogSubsystem = Bundle.main.bundleIdentifier ?? "com.local.doubao.voice-launcher"
private let launcherWindowWidth: CGFloat = 440
private let launcherWindowHeight: CGFloat = 493
private let launcherContentWidth: CGFloat = 410
private let launcherCardContentWidth: CGFloat = launcherContentWidth - 22
private let launcherShortcutContentWidth: CGFloat = launcherContentWidth - 20
private let designBorderColor = NSColor.black.withAlphaComponent(0.09)
private let designDividerColor = NSColor.black.withAlphaComponent(0.09)
private let designCardFillColor = NSColor.white.withAlphaComponent(0.64)
private let designSecondaryTextColor = NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.47, alpha: 1.0)
private let designSettingsAuxiliaryFont = NSFont.systemFont(ofSize: 9.5)
private let designInlineControlGap: CGFloat = 3
private let designStatusIconSize: CGFloat = 23
private let designStatusIconTextGap: CGFloat = 8
private let designStatusTextWidth: CGFloat = 78
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
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func record(level: String, category: String, message: String) {
        let timestampDate = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let timestamp = timestampFormatter.string(from: timestampDate)
                let uptimeText = String(format: "%.6f", uptime)
                let line = "\(timestamp) uptime=\(uptimeText) [\(level)] [\(category)] \(message)\n"
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
private let eventTapHealthCheckInterval: TimeInterval = 2.0
private let eventTapHealthLogInterval: TimeInterval = 30.0
private let inputSourcePollInterval: TimeInterval = 0.01
private let inputSourcePollTimeout: TimeInterval = 0.35
private let voiceActivationProbeDelays: [TimeInterval] = [0.35, 0.25, 0.15]
private let voiceActivationRetryResetDelay: TimeInterval = 0.10
private let doubaoImeExecutablePath = "/Library/Input Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme"
private let doubaoImeBundleID = "com.bytedance.inputmethod.doubaoime"
private let processPathBufferSize = 4_096

private enum ShortcutRole {
    case hold
    case singleTap
}

private enum VoiceSessionKind {
    case singleTap
}

private struct PendingVoiceActivation {
    let id: Int
    let shortcut: Shortcut
    let kind: VoiceSessionKind
    let attempt: Int
    let startedAt: TimeInterval
    let shortcutIsDown: Bool
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
    private static let singleTapKeyCodeKey = "singleTapShortcutKeyCode"
    private static let singleTapKeyCodesKey = "singleTapShortcutKeyCodes"
    private static let singleTapFlagsKey = "singleTapShortcutFlags"
    private static let singleTapDisplayKey = "singleTapShortcutDisplay"

    static func loadHoldShortcut() -> Shortcut? {
        load(keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
    }

    static func loadSingleTapShortcut() -> Shortcut? {
        load(keyCodeKey: singleTapKeyCodeKey, keyCodesKey: singleTapKeyCodesKey, flagsKey: singleTapFlagsKey, displayKey: singleTapDisplayKey)
    }

    static func saveHoldShortcut(_ shortcut: Shortcut?) {
        save(shortcut, keyCodeKey: holdKeyCodeKey, keyCodesKey: holdKeyCodesKey, flagsKey: holdFlagsKey, displayKey: holdDisplayKey)
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

    private static let forwardDelayKey = "forwardDelayMilliseconds"
    private static let longPressDurationKey = "longPressDurationMilliseconds"

    static func loadForwardDelayMilliseconds() -> Int {
        loadMilliseconds(key: forwardDelayKey, defaultValue: defaultForwardDelayMilliseconds)
    }

    static func loadLongPressMilliseconds() -> Int {
        loadMilliseconds(key: longPressDurationKey, defaultValue: defaultLongPressMilliseconds)
    }

    static func saveForwardDelayMilliseconds(_ milliseconds: Int) {
        saveMilliseconds(milliseconds, key: forwardDelayKey)
    }

    static func saveLongPressMilliseconds(_ milliseconds: Int) {
        saveMilliseconds(milliseconds, key: longPressDurationKey)
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
}

private enum DoubaoAudioInputProbe {
    private static var cachedProcessID: pid_t?
    private static var cachedProcessObjectID: AudioObjectID?

    static func isRunningInput() -> Bool {
        guard let (pid, processObjectID) = doubaoProcessObjectID() else {
            AppLog.automation.warning("Doubao audio probe could not find DoubaoIme process")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Doubao audio probe could not find DoubaoIme process")
            return false
        }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunningInput = UInt32(0)
        var isRunningInputSize = UInt32(MemoryLayout<UInt32>.size)
        let inputStatus = AudioObjectGetPropertyData(
            processObjectID,
            &inputAddress,
            0,
            nil,
            &isRunningInputSize,
            &isRunningInput
        )
        guard inputStatus == noErr else {
            clearCachedProcessObject()
            AppLog.automation.warning("Doubao audio probe failed to query input state for pid \(pid, privacy: .public), processObjectID \(processObjectID, privacy: .public), status \(inputStatus, privacy: .public)")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Doubao audio probe failed to query input state for pid \(pid), processObjectID \(processObjectID), status \(inputStatus)")
            return false
        }

        AppLog.automation.info("Doubao audio probe pid \(pid, privacy: .public), processObjectID \(processObjectID, privacy: .public), runningInput \(isRunningInput, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Doubao audio probe pid \(pid), processObjectID \(processObjectID), runningInput \(isRunningInput)")
        return isRunningInput == 1
    }

    private static func doubaoProcessObjectID() -> (pid_t, AudioObjectID)? {
        if let cachedProcessID, let cachedProcessObjectID {
            return (cachedProcessID, cachedProcessObjectID)
        }

        guard let pid = doubaoProcessID() else {
            clearCachedProcessObject()
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var processObjectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidValue = pid
        let pidSize = UInt32(MemoryLayout<pid_t>.size)
        let translateStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            pidSize,
            &pidValue,
            &processObjectIDSize,
            &processObjectID
        )
        guard translateStatus == noErr, processObjectID != kAudioObjectUnknown else {
            clearCachedProcessObject()
            AppLog.automation.warning("Doubao audio probe failed to translate pid \(pid, privacy: .public), status \(translateStatus, privacy: .public), processObjectID \(processObjectID, privacy: .public)")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Doubao audio probe failed to translate pid \(pid), status \(translateStatus), processObjectID \(processObjectID)")
            return nil
        }

        cachedProcessID = pid
        cachedProcessObjectID = processObjectID
        AppLog.automation.info("Doubao audio probe cached pid \(pid, privacy: .public), processObjectID \(processObjectID, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Doubao audio probe cached pid \(pid), processObjectID \(processObjectID)")
        return (pid, processObjectID)
    }

    private static func clearCachedProcessObject() {
        cachedProcessID = nil
        cachedProcessObjectID = nil
    }

    private static func doubaoProcessID() -> pid_t? {
        if let runningApplicationPID = NSWorkspace.shared.runningApplications.first(where: { app in
            app.bundleIdentifier == doubaoImeBundleID
                || app.executableURL?.path == doubaoImeExecutablePath
                || app.bundleURL?.path.hasSuffix("DoubaoIme.app") == true
        })?.processIdentifier {
            return runningApplicationPID
        }

        return processIDFromProcessList()
    }

    private static func processIDFromProcessList() -> pid_t? {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else {
            return nil
        }

        let pidCapacity = Int(requiredBytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let writtenBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, requiredBytes)
        }
        guard writtenBytes > 0 else {
            return nil
        }

        let pidCount = Int(writtenBytes) / MemoryLayout<pid_t>.stride
        for pid in pids.prefix(pidCount) where pid > 0 {
            var pathBuffer = [CChar](repeating: 0, count: processPathBufferSize)
            let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard pathLength > 0 else {
                continue
            }
            if String(cString: pathBuffer) == doubaoImeExecutablePath {
                return pid
            }
        }
        return nil
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

private struct KeyboardEventSnapshot {
    let type: CGEventType
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let autorepeat: Bool
    let isSynthetic: Bool

    init(type: CGEventType, event: CGEvent) {
        self.type = type
        self.keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        self.flags = event.flags
        self.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        self.isSynthetic = ShortcutSender.isSyntheticEvent(event)
    }
}

private struct EventTapHealthSnapshot: Equatable {
    let isTapEnabled: Bool
    let isForwardingShortcut: Bool
    let canRecreateEnabledTap: Bool
    let action: EventTapHealthAction
}

private final class RightControlAutomation {
    private let inputSourceService: InputSourceService
    private var holdShortcut = ShortcutDefaults.loadHoldShortcut()
    private var singleTapShortcut = ShortcutDefaults.loadSingleTapShortcut()
    private var forwardDelayMilliseconds = TimingDefaults.loadForwardDelayMilliseconds()
    private var longPressMilliseconds = TimingDefaults.loadLongPressMilliseconds()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var eventTapThread: Thread?
    private var eventTapHealthPolicy = EventTapHealthPolicy()
    private var eventTapHealthCheckWorkItem: DispatchWorkItem?
    private var eventTapGeneration = 0
    private var lastKeyboardEventAt: TimeInterval?
    private var lastShortcutCandidateEventAt: TimeInterval?
    private var lastEventTapHealthLogAt: TimeInterval = 0
    private var lastEventTapHealthSnapshot: EventTapHealthSnapshot?
    private var isTriggerDown = false
    private var triggerDownAt: TimeInterval = 0
    private var sessionActive = false
    private var sessionKind: VoiceSessionKind?
    private var longPressWorkItem: DispatchWorkItem?
    private var didTriggerLongPress = false
    private var resumeEventTapWorkItem: DispatchWorkItem?
    private var restoreInputSourceWorkItem: DispatchWorkItem?
    private var voiceActivationProbeWorkItem: DispatchWorkItem?
    private var sessionStopWorkItem: DispatchWorkItem?
    private var preparingActivationID: Int?
    private var pendingActivation: PendingVoiceActivation?
    private var activationSequence = 0
    private var isForwardingShortcut = false
    private var activeShortcut: Shortcut?
    private var sessionShortcut: Shortcut?
    private var activeModifierKeyCodes = Set<CGKeyCode>()
    private var activeSupportsLongPress = false
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

        guard installEventTap() else {
            return false
        }

        startEventTapHealthChecks()
        AppLog.automation.info("Keyboard automation started with hold \(self.logDescription(for: self.holdShortcut), privacy: .public), singleTap \(self.logDescription(for: self.singleTapShortcut), privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation started with hold \(logDescription(for: holdShortcut)), singleTap \(logDescription(for: singleTapShortcut))")
        onStatus?("后台监听已开启：已选择的快捷键会自动切到豆包，结束后恢复原输入法。")
        return true
    }

    func updateConfiguration(
        hold: Shortcut?,
        singleTap: Shortcut?,
        forwardDelayMilliseconds: Int,
        longPressMilliseconds: Int
    ) {
        holdShortcut = hold
        singleTapShortcut = singleTap
        self.forwardDelayMilliseconds = TimingDefaults.clampedMilliseconds(forwardDelayMilliseconds)
        self.longPressMilliseconds = TimingDefaults.clampedMilliseconds(longPressMilliseconds)
        AppLog.automation.info("Updated automation configuration: hold \(self.logDescription(for: hold), privacy: .public), singleTap \(self.logDescription(for: singleTap), privacy: .public), forwardDelay=\(self.forwardDelayMilliseconds, privacy: .public)ms, longPress=\(self.longPressMilliseconds, privacy: .public)ms")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Updated automation configuration: hold \(logDescription(for: hold)), singleTap \(logDescription(for: singleTap)), forwardDelay=\(self.forwardDelayMilliseconds)ms, longPress=\(self.longPressMilliseconds)ms")
    }

    func stop() {
        AppLog.automation.info("Stop keyboard automation requested")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Stop keyboard automation requested")
        stopEventTapHealthChecks()
        resumeEventTapWorkItem?.cancel()
        resumeEventTapWorkItem = nil
        restoreInputSourceWorkItem?.cancel()
        restoreInputSourceWorkItem = nil
        sessionStopWorkItem?.cancel()
        sessionStopWorkItem = nil
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        voiceActivationProbeWorkItem?.cancel()
        voiceActivationProbeWorkItem = nil
        preparingActivationID = nil
        if let pendingActivation {
            if pendingActivation.shortcutIsDown {
                forwardShortcutEvent {
                    ShortcutSender.keyUp(shortcut: pendingActivation.shortcut)
                }
            }
            self.pendingActivation = nil
        }
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
        removeEventTap()
        AppLog.automation.info("Keyboard automation stopped")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard automation stopped")
    }

    private func installEventTap() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var installed = false
        eventTapGeneration += 1
        let generation = eventTapGeneration
        AppLog.automation.info("Starting keyboard event tap thread generation \(generation, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Starting keyboard event tap thread generation \(generation)")
        let thread = Thread { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }

            installed = self.installEventTapOnCurrentThread(generation: generation)
            semaphore.signal()
            guard installed else {
                return
            }

            AppLog.automation.info("Keyboard event tap run loop starting generation \(generation, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard event tap run loop starting generation \(generation)")
            CFRunLoopRun()
            AppLog.automation.info("Keyboard event tap run loop stopped generation \(generation, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard event tap run loop stopped generation \(generation)")
        }
        thread.name = "DoubaoVoiceLauncher.keyboard-event-tap"
        eventTapThread = thread
        thread.start()

        let waitResult = semaphore.wait(timeout: .now() + 2.0)
        if !installed {
            eventTapThread = nil
        }
        AppLog.automation.info("Keyboard event tap install wait finished generation \(generation, privacy: .public), installed=\(installed, privacy: .public), timedOut=\(waitResult == .timedOut, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard event tap install wait finished generation \(generation), installed=\(installed), timedOut=\(waitResult == .timedOut)")
        return installed
    }

    private func installEventTapOnCurrentThread(generation: Int) -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        AppLog.automation.info("Creating keyboard event tap generation \(generation, privacy: .public), options=listenOnly, mask=\(mask, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Creating keyboard event tap generation \(generation), options=listenOnly, mask=\(mask)")
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<RightControlAutomation>.fromOpaque(refcon).takeUnretainedValue()
            let snapshot = KeyboardEventSnapshot(type: type, event: event)
            DispatchQueue.main.async {
                monitor.handle(snapshot)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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
        eventTapRunLoop = CFRunLoopGetCurrent()
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTapHealthPolicy.reset()
        lastEventTapHealthSnapshot = nil
        lastEventTapHealthLogAt = 0
        AppLog.automation.info("Keyboard event tap installed generation \(generation, privacy: .public), sourceCreated=\(self.runLoopSource != nil, privacy: .public), enabled=\(CGEvent.tapIsEnabled(tap: tap), privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard event tap installed generation \(generation), sourceCreated=\(self.runLoopSource != nil), enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        return true
    }

    private func removeEventTap() {
        let tap = eventTap
        let source = runLoopSource
        let runLoop = eventTapRunLoop
        let generation = eventTapGeneration
        AppLog.automation.info("Removing keyboard event tap generation \(generation, privacy: .public), hasTap=\(tap != nil, privacy: .public), hasSource=\(source != nil, privacy: .public), hasRunLoop=\(runLoop != nil, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Removing keyboard event tap generation \(generation), hasTap=\(tap != nil), hasSource=\(source != nil), hasRunLoop=\(runLoop != nil)")
        eventTap = nil
        runLoopSource = nil
        eventTapRunLoop = nil
        eventTapThread = nil
        lastEventTapHealthSnapshot = nil

        guard let runLoop else {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            eventTapHealthPolicy.reset()
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let tap {
                AppLog.automation.info("Invalidating keyboard event tap generation \(generation, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "Invalidating keyboard event tap generation \(generation)")
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        eventTapHealthPolicy.reset()
    }

    private func startEventTapHealthChecks() {
        eventTapHealthCheckWorkItem?.cancel()
        scheduleEventTapHealthCheck()
    }

    private func stopEventTapHealthChecks() {
        eventTapHealthCheckWorkItem?.cancel()
        eventTapHealthCheckWorkItem = nil
        eventTapHealthPolicy.reset()
    }

    private func scheduleEventTapHealthCheck() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.verifyEventTapHealth()
            guard self.eventTap != nil else {
                return
            }
            self.scheduleEventTapHealthCheck()
        }
        eventTapHealthCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + eventTapHealthCheckInterval, execute: workItem)
    }

    private func verifyEventTapHealth() {
        guard let eventTap else {
            eventTapHealthPolicy.reset()
            return
        }

        let isTapEnabled = CGEvent.tapIsEnabled(tap: eventTap)
        let canRecreateEnabledTap = canRenewEnabledEventTap
        let action = eventTapHealthPolicy.nextAction(
            isTapPresent: true,
            isTapEnabled: isTapEnabled,
            isForwardingShortcut: isForwardingShortcut,
            canRecreateEnabledTap: canRecreateEnabledTap
        )
        logEventTapHealthIfNeeded(
            isTapEnabled: isTapEnabled,
            canRecreateEnabledTap: canRecreateEnabledTap,
            action: action
        )

        switch action {
        case .none:
            return
        case .reenable:
            AppLog.automation.warning("Keyboard event tap health check found disabled tap; re-enabling")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Keyboard event tap health check found disabled tap; re-enabling")
            CGEvent.tapEnable(tap: eventTap, enable: true)
        case .recreate:
            AppLog.automation.warning("Keyboard event tap health check is recreating tap")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Keyboard event tap health check is recreating tap")
            removeEventTap()
            if installEventTap() {
                AppLog.automation.info("Keyboard event tap recreated by health check")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "Keyboard event tap recreated by health check")
            }
        }
    }

    private func logEventTapHealthIfNeeded(
        isTapEnabled: Bool,
        canRecreateEnabledTap: Bool,
        action: EventTapHealthAction
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = EventTapHealthSnapshot(
            isTapEnabled: isTapEnabled,
            isForwardingShortcut: isForwardingShortcut,
            canRecreateEnabledTap: canRecreateEnabledTap,
            action: action
        )
        let shouldLog = snapshot != lastEventTapHealthSnapshot
            || action != .none
            || lastEventTapHealthLogAt == 0
            || now - lastEventTapHealthLogAt >= eventTapHealthLogInterval
        guard shouldLog else {
            return
        }

        lastEventTapHealthSnapshot = snapshot
        lastEventTapHealthLogAt = now
        let message = "Keyboard event tap health: enabled=\(isTapEnabled), forwarding=\(isForwardingShortcut), canRecreateEnabledTap=\(canRecreateEnabledTap), action=\(action), lastEventAge=\(ageDescription(since: lastKeyboardEventAt, now: now)), lastShortcutEventAge=\(ageDescription(since: lastShortcutCandidateEventAt, now: now))"
        AppLog.automation.info("\(message, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: message)
    }

    private var canRenewEnabledEventTap: Bool {
        !isForwardingShortcut
            && !isTriggerDown
            && !sessionActive
            && preparingActivationID == nil
            && pendingActivation == nil
    }

    private func ageDescription(since timestamp: TimeInterval?, now: TimeInterval) -> String {
        guard let timestamp else {
            return "never"
        }
        return String(format: "%.3fs", max(0, now - timestamp))
    }

    private func eventTypeDescription(_ type: CGEventType) -> String {
        switch type {
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        case .flagsChanged:
            return "flagsChanged"
        case .tapDisabledByTimeout:
            return "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            return "tapDisabledByUserInput"
        default:
            return "type=\(type.rawValue)"
        }
    }

    private func keyName(for keyCode: CGKeyCode) -> String {
        switch keyCode {
        case 54:
            return "RightCommand"
        case 55:
            return "LeftCommand"
        case 56:
            return "LeftShift"
        case 60:
            return "RightShift"
        case 58:
            return "LeftOption"
        case 61:
            return "RightOption"
        case 59:
            return "LeftControl"
        case 62:
            return "RightControl"
        case 63:
            return "Function"
        default:
            return "Key\(keyCode)"
        }
    }

    private func modifierSummary(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        if flags.contains(.maskControl) { parts.append("control") }
        if flags.contains(.maskAlternate) { parts.append("option") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskCommand) { parts.append("cmd") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    private func keyCodesDescription(_ keyCodes: Set<CGKeyCode>) -> String {
        guard !keyCodes.isEmpty else {
            return "none"
        }
        return keyCodes.sorted().map { "\($0):\(keyName(for: $0))" }.joined(separator: ",")
    }

    private func shortcutRoles(for keyCode: CGKeyCode) -> String? {
        var roles: [String] = []
        if holdShortcut?.keyCodes.contains(keyCode) == true {
            roles.append("hold")
        }
        if singleTapShortcut?.keyCodes.contains(keyCode) == true {
            roles.append("singleTap")
        }
        return roles.isEmpty ? nil : roles.joined(separator: "+")
    }

    private func eventAction(for event: KeyboardEventSnapshot) -> String {
        if event.type == .keyDown {
            return event.autorepeat ? "repeat" : "down"
        }
        if event.type == .keyUp {
            return "up"
        }
        if event.type == .flagsChanged,
           let modifierFlag = ShortcutFormatter.modifierFlag(for: event.keyCode) {
            return event.flags.contains(modifierFlag) ? "down" : "up"
        }
        return "changed"
    }

    private func logConfiguredShortcutEvent(
        _ event: KeyboardEventSnapshot,
        activeBefore: Set<CGKeyCode>,
        activeAfter: Set<CGKeyCode>,
        note: String? = nil
    ) {
        guard let roles = shortcutRoles(for: event.keyCode) else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !event.isSynthetic {
            lastShortcutCandidateEventAt = now
        }
        let noteText = note.map { ", note=\($0)" } ?? ""
        let message = String(
            format: "Event tap received shortcut key event: type=%@ action=%@ keyCode=%hu key=%@ flags=0x%016llx mods=%@ synthetic=%@ roles=%@ activeBefore=%@ activeAfter=%@%@",
            eventTypeDescription(event.type),
            eventAction(for: event),
            event.keyCode,
            keyName(for: event.keyCode),
            event.flags.rawValue,
            modifierSummary(event.flags),
            String(event.isSynthetic),
            roles,
            keyCodesDescription(activeBefore),
            keyCodesDescription(activeAfter),
            noteText
        )
        AppLog.automation.info("\(message, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: message)
    }

    private func handle(_ event: KeyboardEventSnapshot) {
        let type = event.type
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isForwardingShortcut {
                AppLog.automation.debug("Event tap disabled while forwarding synthetic shortcut; waiting for scheduled re-enable")
                return
            }
            AppLog.automation.warning("Event tap disabled by system, re-enabling")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Event tap disabled by system, re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                eventTapHealthPolicy.reset()
            }
            return
        }

        if event.isSynthetic {
            logConfiguredShortcutEvent(
                event,
                activeBefore: activeModifierKeyCodes,
                activeAfter: activeModifierKeyCodes,
                note: "ignoredSynthetic"
            )
            return
        }

        lastKeyboardEventAt = ProcessInfo.processInfo.systemUptime

        if type == .keyDown {
            logConfiguredShortcutEvent(
                event,
                activeBefore: activeModifierKeyCodes,
                activeAfter: activeModifierKeyCodes
            )
            handleKeyDown()
            return
        }

        if type == .keyUp {
            logConfiguredShortcutEvent(
                event,
                activeBefore: activeModifierKeyCodes,
                activeAfter: activeModifierKeyCodes
            )
            handleKeyUp()
            return
        }

        guard type == .flagsChanged else {
            return
        }

        let keyCode = event.keyCode
        let staleModifierKeyCodes = ModifierKeyState.staleKeyCodes(
            activeKeyCodes: activeModifierKeyCodes,
            currentKeyCode: keyCode,
            activeFlagsRawValue: event.flags.rawValue
        ) { keyCode in
            ShortcutFormatter.modifierFlag(for: CGKeyCode(keyCode))?.rawValue
        }
        if !staleModifierKeyCodes.isEmpty {
            let activeBeforeCleanup = activeModifierKeyCodes
            activeModifierKeyCodes.subtract(staleModifierKeyCodes)
            let message = "Cleared stale modifier key state: stale=\(keyCodesDescription(staleModifierKeyCodes)), flags=\(modifierSummary(event.flags)), activeBefore=\(keyCodesDescription(activeBeforeCleanup)), activeAfter=\(keyCodesDescription(activeModifierKeyCodes))"
            AppLog.automation.warning("\(message, privacy: .public)")
            FileDebugLog.record(level: "WARN", category: "Automation", message: message)
        }
        let activeModifierKeyCodesBefore = activeModifierKeyCodes
        if let modifierFlag = ShortcutFormatter.modifierFlag(for: keyCode) {
            if event.flags.contains(modifierFlag) {
                activeModifierKeyCodes.insert(keyCode)
            } else {
                activeModifierKeyCodes.remove(keyCode)
            }
        }
        logConfiguredShortcutEvent(
            event,
            activeBefore: activeModifierKeyCodesBefore,
            activeAfter: activeModifierKeyCodes
        )

        let holdKeyCodes = holdShortcut.map { Set($0.keyCodes) }
        let singleTapKeyCodes = singleTapShortcut.map { Set($0.keyCodes) }
        let supportsLongPress = holdKeyCodes.map {
            ShortcutMatchState.isPressed(
                changedKeyCode: keyCode,
                activeModifierKeyCodes: activeModifierKeyCodes,
                shortcutKeyCodes: $0
            )
        } ?? false
        let supportsSingleTap = singleTapKeyCodes.map {
            ShortcutMatchState.isPressed(
                changedKeyCode: keyCode,
                activeModifierKeyCodes: activeModifierKeyCodes,
                shortcutKeyCodes: $0
            )
        } ?? false
        let shortcut = supportsSingleTap ? singleTapShortcut : holdShortcut
        if let shortcut, (supportsLongPress || supportsSingleTap) && !isTriggerDown {
            handleTriggerDown(
                shortcut: shortcut,
                supportsLongPress: supportsLongPress,
                supportsSingleTap: supportsSingleTap
            )
            return
        }

        let activeKeyCodes = Set(activeShortcut?.keyCodes ?? [])
        if isTriggerDown && ShortcutMatchState.isReleased(
            changedKeyCode: keyCode,
            activeModifierKeyCodes: activeModifierKeyCodes,
            shortcutKeyCodes: activeKeyCodes
        ) {
            handleTriggerUp()
            return
        }
    }

    private func handleKeyDown() {
    }

    private func handleKeyUp() {
    }

    private func handleTriggerDown(shortcut: Shortcut, supportsLongPress: Bool, supportsSingleTap: Bool) {
        if isShortcutTransitionBlocked {
            let reason = shortcutTransitionBlockReason
            AppLog.automation.info("Shortcut trigger down ignored because \(reason, privacy: .public)")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger down ignored because \(reason)")
            onStatus?("正在处理上一轮快捷键操作。")
            return
        }

        isTriggerDown = true
        didTriggerLongPress = false
        activeShortcut = shortcut
        activeSupportsLongPress = supportsLongPress
        activeSupportsSingleTap = supportsSingleTap
        triggerDownAt = ProcessInfo.processInfo.systemUptime
        let pressStartedAt = triggerDownAt
        AppLog.automation.info("Shortcut trigger down: \(shortcut.logDescription, privacy: .public), longPress=\(supportsLongPress, privacy: .public), singleTap=\(supportsSingleTap, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger down: \(shortcut.logDescription), longPress=\(supportsLongPress), singleTap=\(supportsSingleTap)")

        if sessionActive {
            AppLog.automation.info("Shortcut pressed while no-hold session is active")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut pressed while no-hold session is active")
            onStatus?("检测到快捷键按下，将结束当前语音输入。")
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
        isTriggerDown = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        guard let shortcut = activeShortcut else {
            resetActiveTrigger()
            return
        }
        let supportsSingleTap = activeSupportsSingleTap
        AppLog.automation.info("Shortcut trigger up: \(shortcut.logDescription, privacy: .public), didLongPress=\(self.didTriggerLongPress, privacy: .public), sessionActive=\(self.sessionActive, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "Shortcut trigger up: \(shortcut.logDescription), didLongPress=\(didTriggerLongPress), sessionActive=\(sessionActive)")
        defer {
            resetActiveTrigger()
        }

        if preparingActivationID != nil || pendingActivation != nil {
            AppLog.automation.info("Trigger up ignored because voice activation is pending")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Trigger up ignored because voice activation is pending")
            return
        }

        if didTriggerLongPress {
            forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            didTriggerLongPress = false
            sessionActive = false
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
            scheduleNoHoldStop(shortcut: sessionShortcut ?? shortcut, delay: 0.08, message: "检测到快捷键单击结束语音输入，已恢复原输入法。")
            return
        }

        if supportsSingleTap {
            guard inputSourceService.beginDoubaoSession() else {
                AppLog.automation.error("Single-tap flow failed to switch to Doubao input source")
                FileDebugLog.record(level: "ERROR", category: "Automation", message: "Single-tap flow failed to switch to Doubao input source")
                onStatus?("切换到豆包输入法失败。")
                return
            }
            prepareNoHoldActivation(shortcut: shortcut, kind: .singleTap)
            return
        }
    }

    private func prepareNoHoldActivation(shortcut: Shortcut, kind: VoiceSessionKind) {
        activationSequence += 1
        let preparationID = activationSequence
        preparingActivationID = preparationID
        waitForDoubaoInputSource(
            waitForForwardDelay: false,
            onTimeout: {
                guard self.preparingActivationID == preparationID else {
                    return
                }
                self.preparingActivationID = nil
            },
            onReady: {
                guard self.preparingActivationID == preparationID else {
                    return
                }
                self.schedulePreflightResetAndActivation(
                    preparationID: preparationID,
                    shortcut: shortcut,
                    kind: kind
                )
            }
        )
    }

    private func schedulePreflightResetAndActivation(
        preparationID: Int,
        shortcut: Shortcut,
        kind: VoiceSessionKind
    ) {
        AppLog.automation.info("No-hold activation preflight reset keyUp sent; waiting configured forward delay \(self.forwardDelay, privacy: .public) seconds")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold activation preflight reset keyUp sent; waiting configured forward delay \(forwardDelay) seconds")
        forwardShortcutEvent {
            ShortcutSender.keyUp(shortcut: shortcut)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.preparingActivationID == preparationID else {
                return
            }
            guard self.inputSourceService.currentSourceID() == doubaoInputSourceID else {
                self.preparingActivationID = nil
                AppLog.automation.warning("No-hold activation preflight stopped because Doubao input source is no longer active")
                FileDebugLog.record(level: "WARN", category: "Automation", message: "No-hold activation preflight stopped because Doubao input source is no longer active")
                self.onStatus?("豆包输入法状态变化，已取消语音启动。")
                return
            }
            self.preparingActivationID = nil
            AppLog.automation.info("No-hold activation preflight reset delay finished; sending attempt 1 keyDown")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold activation preflight reset delay finished; sending attempt 1 keyDown")
            self.startPendingNoHoldActivation(shortcut: shortcut, kind: kind, attempt: 1)
        }
        voiceActivationProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + forwardDelay, execute: workItem)
    }

    private func startPendingNoHoldActivation(shortcut: Shortcut, kind: VoiceSessionKind, attempt: Int) {
        guard pendingActivation == nil, !sessionActive else {
            AppLog.automation.info("Skip no-hold activation because another voice session is already active")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "Skip no-hold activation because another voice session is already active")
            return
        }
        activationSequence += 1
        let pending = PendingVoiceActivation(
            id: activationSequence,
            shortcut: shortcut,
            kind: kind,
            attempt: attempt,
            startedAt: ProcessInfo.processInfo.systemUptime,
            shortcutIsDown: true
        )
        pendingActivation = pending
        forwardShortcutEvent {
            ShortcutSender.keyDown(shortcut: shortcut)
        }
        AppLog.automation.info("No-hold activation pending after forwarded keyDown, attempt \(attempt, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold activation pending after forwarded keyDown, attempt \(attempt)")
        scheduleVoiceActivationProbe(id: pending.id, delay: voiceActivationProbeDelays[0], probeIndex: 0)
    }

    private func scheduleVoiceActivationProbe(id: Int, delay: TimeInterval, probeIndex: Int) {
        voiceActivationProbeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runVoiceActivationProbe(id: id, probeIndex: probeIndex)
        }
        voiceActivationProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runVoiceActivationProbe(id: Int, probeIndex: Int) {
        guard let pending = pendingActivation, pending.id == id else {
            return
        }

        if inputSourceService.currentSourceID() != doubaoInputSourceID {
            AppLog.automation.warning("Voice activation probe stopped because Doubao input source is no longer active")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "Voice activation probe stopped because Doubao input source is no longer active")
            failPendingActivation(pending, message: "豆包输入法状态变化，已取消语音启动。")
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - pending.startedAt
        let probeNumber = probeIndex + 1
        let probeCount = voiceActivationProbeDelays.count
        if DoubaoAudioInputProbe.isRunningInput() {
            completePendingActivation(pending, elapsed: elapsed, probeNumber: probeNumber, probeCount: probeCount)
            return
        }

        handleVoiceActivationProbeMiss(
            pending,
            probeIndex: probeIndex,
            elapsed: elapsed,
            probeNumber: probeNumber,
            probeCount: probeCount
        )
    }

    private func completePendingActivation(
        _ pending: PendingVoiceActivation,
        elapsed: TimeInterval,
        probeNumber: Int,
        probeCount: Int
    ) {
        pendingActivation = nil
        voiceActivationProbeWorkItem?.cancel()
        voiceActivationProbeWorkItem = nil
        sessionActive = true
        sessionKind = pending.kind
        sessionShortcut = pending.shortcut
        AppLog.automation.info("No-hold activation confirmed after \(elapsed, privacy: .public) seconds, attempt \(pending.attempt, privacy: .public), probe \(probeNumber, privacy: .public)/\(probeCount, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold activation confirmed after \(elapsed) seconds, attempt \(pending.attempt), probe \(probeNumber)/\(probeCount)")
        onStatus?("检测到单击模式快捷键，已确认豆包语音输入启动。")
    }

    private func handleVoiceActivationProbeMiss(
        _ pending: PendingVoiceActivation,
        probeIndex: Int,
        elapsed: TimeInterval,
        probeNumber: Int,
        probeCount: Int
    ) {
        let nextProbeIndex = probeIndex + 1
        if nextProbeIndex < voiceActivationProbeDelays.count {
            let nextDelay = voiceActivationProbeDelays[nextProbeIndex]
            AppLog.automation.info("No-hold activation probe \(probeNumber, privacy: .public)/\(probeCount, privacy: .public) missed after \(elapsed, privacy: .public) seconds, attempt \(pending.attempt, privacy: .public); keeping keyDown and scheduling next probe in \(nextDelay, privacy: .public) seconds")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold activation probe \(probeNumber)/\(probeCount) missed after \(elapsed) seconds, attempt \(pending.attempt); keeping keyDown and scheduling next probe in \(nextDelay) seconds")
            onStatus?("豆包语音输入尚未启动，继续保持快捷键并最终确认。")
            scheduleVoiceActivationProbe(id: pending.id, delay: nextDelay, probeIndex: nextProbeIndex)
            return
        }

        AppLog.automation.warning("No-hold activation probe \(probeNumber, privacy: .public)/\(probeCount, privacy: .public) timed out after \(elapsed, privacy: .public) seconds, attempt \(pending.attempt, privacy: .public)")
        FileDebugLog.record(level: "WARN", category: "Automation", message: "No-hold activation probe \(probeNumber)/\(probeCount) timed out after \(elapsed) seconds, attempt \(pending.attempt)")

        if pending.attempt == 1 {
            scheduleNoHoldActivationRetry(from: pending)
            return
        }

        failPendingActivation(pending, message: "豆包语音输入未启动，已恢复原输入法，可再次单击重试。")
    }

    private func scheduleNoHoldActivationRetry(from pending: PendingVoiceActivation) {
        guard pendingActivation?.id == pending.id else {
            return
        }
        activationSequence += 1
        let retryID = activationSequence
        let released = PendingVoiceActivation(
            id: retryID,
            shortcut: pending.shortcut,
            kind: pending.kind,
            attempt: 2,
            startedAt: ProcessInfo.processInfo.systemUptime,
            shortcutIsDown: false
        )
        pendingActivation = released
        voiceActivationProbeWorkItem?.cancel()
        AppLog.automation.warning("No-hold activation attempt 1 failed; sending keyUp, waiting retry reset \(voiceActivationRetryResetDelay, privacy: .public) seconds, then retrying keyDown")
        FileDebugLog.record(level: "WARN", category: "Automation", message: "No-hold activation attempt 1 failed; sending keyUp, waiting retry reset \(voiceActivationRetryResetDelay) seconds, then retrying keyDown")
        onStatus?("豆包语音输入未启动，正在释放并重新发送快捷键。")
        forwardShortcutEvent {
            ShortcutSender.keyUp(shortcut: pending.shortcut)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.sendNoHoldActivationRetry(id: retryID)
        }
        voiceActivationProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + voiceActivationRetryResetDelay, execute: workItem)
    }

    private func sendNoHoldActivationRetry(id: Int) {
        guard let released = pendingActivation, released.id == id else {
            return
        }

        if inputSourceService.currentSourceID() != doubaoInputSourceID {
            AppLog.automation.warning("No-hold activation retry stopped because Doubao input source is no longer active")
            FileDebugLog.record(level: "WARN", category: "Automation", message: "No-hold activation retry stopped because Doubao input source is no longer active")
            failPendingActivation(released, message: "豆包输入法状态变化，已取消语音启动。")
            return
        }

        AppLog.automation.warning("No-hold activation attempt 2 started with a fresh key down after reset")
        FileDebugLog.record(level: "WARN", category: "Automation", message: "No-hold activation attempt 2 started with a fresh key down after reset")
        pendingActivation = nil
        startPendingNoHoldActivation(shortcut: released.shortcut, kind: released.kind, attempt: 2)
        onStatus?("已重新发送快捷键，正在确认豆包语音输入是否启动。")
    }

    private func failPendingActivation(_ pending: PendingVoiceActivation, message: String) {
        guard pendingActivation?.id == pending.id else {
            return
        }
        voiceActivationProbeWorkItem?.cancel()
        voiceActivationProbeWorkItem = nil
        pendingActivation = nil
        sessionActive = false
        sessionKind = nil
        sessionShortcut = nil
        isTriggerDown = false
        didTriggerLongPress = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        resetActiveTrigger()
        if pending.shortcutIsDown {
            forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: pending.shortcut)
            }
        }
        restoreAfterDelay(message: message, delay: 0.10, warningContext: "No-hold activation failed; restored previous input source")
    }

    private var isShortcutTransitionBlocked: Bool {
        preparingActivationID != nil
            || pendingActivation != nil
            || sessionStopWorkItem != nil
            || restoreInputSourceWorkItem != nil
    }

    private var shortcutTransitionBlockReason: String {
        var reasons: [String] = []
        if preparingActivationID != nil {
            reasons.append("input source preparation is pending")
        }
        if pendingActivation != nil {
            reasons.append("voice activation is pending")
        }
        if sessionStopWorkItem != nil {
            reasons.append("voice stop is pending")
        }
        if restoreInputSourceWorkItem != nil {
            reasons.append("input source restore is pending")
        }
        return reasons.isEmpty ? "transition is pending" : reasons.joined(separator: ", ")
    }

    private func scheduleNoHoldStop(shortcut: Shortcut, delay: TimeInterval, message: String) {
        sessionStopWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentWorkItem = workItem, !currentWorkItem.isCancelled else {
                return
            }
            if self.sessionStopWorkItem === currentWorkItem {
                self.sessionStopWorkItem = nil
            }
            self.forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            self.sessionActive = false
            self.sessionKind = nil
            self.sessionShortcut = nil
            AppLog.automation.info("No-hold flow stopped by shortcut; restoring previous input source")
            FileDebugLog.record(level: "INFO", category: "Automation", message: "No-hold flow stopped by shortcut; restoring previous input source")
            self.restoreAfterDelay(message: message, delay: 0.45)
        }
        sessionStopWorkItem = workItem
        if let workItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func forwardShortcutEvent(resumeDelay: TimeInterval = forwardedShortcutResumeDelay, _ send: () -> Void) {
        isForwardingShortcut = true

        send()

        resumeEventTapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.isForwardingShortcut = false
            self.eventTapHealthPolicy.reset()
            AppLog.automation.debug("Finished forwarding synthetic shortcut")
        }
        resumeEventTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay, execute: workItem)
    }

    private func restoreAfterDelay(message: String, delay: TimeInterval, warningContext: String? = nil) {
        restoreInputSourceWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentWorkItem = workItem, !currentWorkItem.isCancelled else {
                return
            }
            if self.restoreInputSourceWorkItem === currentWorkItem {
                self.restoreInputSourceWorkItem = nil
            }
            let restored = self.inputSourceService.restorePrevious()
            if let warningContext {
                AppLog.automation.warning("\(warningContext, privacy: .public): \(restored, privacy: .public)")
                FileDebugLog.record(level: "WARN", category: "Automation", message: "\(warningContext): \(restored)")
            } else {
                AppLog.automation.info("Restore after delay finished: \(restored, privacy: .public)")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "Restore after delay finished: \(restored)")
            }
            self.onStatus?(message)
        }
        restoreInputSourceWorkItem = workItem
        if let workItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func resetActiveTrigger() {
        activeShortcut = nil
        activeSupportsLongPress = false
        activeSupportsSingleTap = false
        triggerDownAt = 0
    }

    private func waitForDoubaoInputSource(
        timeout: TimeInterval = inputSourcePollTimeout,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        waitForForwardDelay: Bool = true,
        onTimeout: (() -> Void)? = nil,
        onReady: @escaping () -> Void
    ) {
        if inputSourceService.currentSourceID() == doubaoInputSourceID {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            if waitForForwardDelay {
                AppLog.automation.info("Doubao input source confirmed after \(elapsed, privacy: .public) seconds; waiting for configured forward delay")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "Doubao input source confirmed after \(elapsed) seconds; waiting \(forwardDelay) seconds before forwarding shortcut")
                DispatchQueue.main.asyncAfter(deadline: .now() + forwardDelay) {
                    onReady()
                }
            } else {
                AppLog.automation.info("Doubao input source confirmed after \(elapsed, privacy: .public) seconds; continuing without built-in forward delay")
                FileDebugLog.record(level: "INFO", category: "Automation", message: "Doubao input source confirmed after \(elapsed) seconds; continuing without built-in forward delay")
                onReady()
            }
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        guard elapsed < timeout else {
            AppLog.automation.error("Timed out waiting for Doubao input source")
            FileDebugLog.record(level: "ERROR", category: "Automation", message: "Timed out waiting for Doubao input source after \(elapsed) seconds")
            onStatus?("已请求切换到豆包输入法，但未确认切换完成。")
            onTimeout?()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) {
            self.waitForDoubaoInputSource(
                timeout: timeout,
                startedAt: startedAt,
                waitForForwardDelay: waitForForwardDelay,
                onTimeout: onTimeout,
                onReady: onReady
            )
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
    case longPress

    var assetName: String {
        switch self {
        case .forwardDelay:
            return "icon-forward-delay"
        case .singleTap:
            return "icon-single-tap"
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

private final class StatusIconView: NSView {
    private static let drawingBaseSize: CGFloat = 20

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
            drawInCenteredCanvas {
                drawWave()
            }
        case .check:
            drawInCenteredCanvas {
                drawCheck()
            }
        case .keyboard:
            drawInCenteredCanvas {
                drawKeyboard()
            }
        }
    }

    private func drawInCenteredCanvas(_ drawContent: () -> Void) {
        let scale = min(bounds.width, bounds.height) / Self.drawingBaseSize
        let translatedX = bounds.midX - (Self.drawingBaseSize * scale / 2)
        let translatedY = bounds.midY - (Self.drawingBaseSize * scale / 2)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: translatedX, yBy: translatedY)
        transform.scale(by: scale)
        transform.concat()
        drawContent()
        NSGraphicsContext.restoreGraphicsState()
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
        let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: Self.drawingBaseSize, height: Self.drawingBaseSize).insetBy(dx: 2.5, dy: 2.5))
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
        let drawingBounds = NSRect(x: 0, y: 0, width: Self.drawingBaseSize, height: Self.drawingBaseSize)
        let body = NSBezierPath(roundedRect: drawingBounds.insetBy(dx: 2.2, dy: 5.1), xRadius: 2.0, yRadius: 2.0)
        body.lineWidth = 1.6
        body.stroke()

        let keySize: CGFloat = 1.15
        let columnGap: CGFloat = 2.7
        let rowGap: CGFloat = 2.5
        let columnCount = 4
        let rowCount = 2
        let gridWidth = CGFloat(columnCount - 1) * columnGap + keySize
        let gridHeight = CGFloat(rowCount - 1) * rowGap + keySize
        let startX = body.bounds.midX - gridWidth / 2
        let startY = body.bounds.midY - gridHeight / 2

        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let x = startX + CGFloat(column) * columnGap
                let y = startY + CGFloat(row) * rowGap
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: keySize, height: keySize)).fill()
            }
        }
    }
}

private final class LauncherViewController: NSViewController, NSTextFieldDelegate {
    private enum TimingControlTag {
        static let forwardDelay = 1
        static let longPress = 2
    }

    private let inputSourceService = InputSourceService()
    private lazy var automation = RightControlAutomation(inputSourceService: inputSourceService)
    private var holdShortcut = ShortcutDefaults.loadHoldShortcut()
    private var singleTapShortcut = ShortcutDefaults.loadSingleTapShortcut()
    private var forwardDelayMilliseconds = TimingDefaults.loadForwardDelayMilliseconds()
    private var longPressMilliseconds = TimingDefaults.loadLongPressMilliseconds()
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
    private let singleTapShortcutButton = ShortcutSelectButton(title: "")
    private let forwardDelayTextField = NSTextField(string: "")
    private let forwardDelayStepper = NSStepper()
    private let longPressTextField = NSTextField(string: "")
    private let longPressStepper = NSStepper()
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

        let explanationLabel = NSTextField(labelWithString: "使用快捷键自动切换到豆包语音输入，结束后自动恢复原输入法")
        explanationLabel.font = .systemFont(ofSize: 14)
        explanationLabel.textColor = NSColor(calibratedRed: 0.39, green: 0.40, blue: 0.43, alpha: 0.90)
        explanationLabel.lineBreakMode = .byWordWrapping

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = designSecondaryTextColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.stringValue = "正在检查状态..."

        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(showHoldShortcutPicker(_:))

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

        monitorToggleButton.target = self
        monitorToggleButton.action = #selector(toggleMonitoring)
        updateMonitorToggleButton()

        [openSettingsButton, accessibilityButton].forEach(configureSecondaryButton)
        configureShortcutButton(holdShortcutButton)
        configureShortcutButton(singleTapShortcutButton)

        let statusContent = makeStatusContent()
        let statusCard = makeRoundedContainer(content: statusContent, horizontalPadding: 11, verticalPadding: 6)
        statusCard.heightAnchor.constraint(equalToConstant: 66).isActive = true

        let settingsSectionTitle = NSTextField(labelWithString: "设置")
        settingsSectionTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let globalTimingCard = makeRoundedContainer(
            content: makeGlobalTimingRow(),
            horizontalPadding: 10,
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
        shortcutCard.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let secondaryButtonRow = makeBottomActionBar(buttons: [openSettingsButton, accessibilityButton])

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

        let bar = EditingDismissView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.984, alpha: 0.92).cgColor

        let bottomLine = EditingDismissView()
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        bar.addSubview(titleLabel)
        bar.addSubview(bottomLine)
        NSLayoutConstraint.activate([
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
        let statusColumnGap: CGFloat = 17.5
        let statusColumnWidth = (launcherCardContentWidth - (statusColumnGap * 2) - 2) / 3
        let firstDividerX = statusColumnWidth
        let installedItemX = firstDividerX + 1 + statusColumnGap
        let secondDividerX = installedItemX + statusColumnWidth
        let inputItemX = secondDividerX + 1 + statusColumnGap

        let runningItem = makeStatusItem(
            icon: monitorStatusIconView,
            valueLabel: monitorStatusValueLabel,
            caption: "运行状态",
            showsDot: false,
            columnWidth: statusColumnWidth
        )
        let installedItem = makeStatusItem(
            icon: StatusIconView(kind: .check),
            valueLabel: doubaoStatusValueLabel,
            caption: "豆包输入法",
            showsDot: false,
            columnWidth: statusColumnWidth
        )
        let inputItem = makeStatusItem(
            icon: StatusIconView(kind: .keyboard),
            valueLabel: currentInputValueLabel,
            caption: "当前输入源",
            showsDot: false,
            columnWidth: statusColumnWidth
        )
        let firstDivider = makeVerticalDivider()
        let secondDivider = makeVerticalDivider()
        let content = EditingDismissView()
        [runningItem, firstDivider, installedItem, secondDivider, inputItem].forEach {
            content.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        content.widthAnchor.constraint(equalToConstant: launcherCardContentWidth).isActive = true
        content.heightAnchor.constraint(equalToConstant: 54).isActive = true
        NSLayoutConstraint.activate([
            runningItem.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            runningItem.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            firstDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: firstDividerX),
            firstDivider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            installedItem.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: installedItemX),
            installedItem.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            secondDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: secondDividerX),
            secondDivider.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            inputItem.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inputItemX),
            inputItem.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        return content
    }

    private func makeStatusItem(
        icon: StatusIconView,
        valueLabel: NSTextField,
        caption: String,
        showsDot: Bool,
        columnWidth: CGFloat
    ) -> NSView {
        icon.widthAnchor.constraint(equalToConstant: designStatusIconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: designStatusIconSize).isActive = true

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
        let contentWidth = designStatusIconSize + designStatusIconTextGap + designStatusTextWidth
        let iconLeading = max(0, (columnWidth - contentWidth) / 2)
        let textLeading = iconLeading + designStatusIconSize + designStatusIconTextGap
        container.addSubview(icon)
        container.addSubview(textStack)
        icon.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: columnWidth),
            container.heightAnchor.constraint(equalToConstant: 54),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: iconLeading),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: textLeading),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.widthAnchor.constraint(equalToConstant: designStatusTextWidth)
        ])
        return container
    }

    private func makeGlobalTimingRow() -> NSView {
        let icon = SettingsRowIconView(kind: .forwardDelay)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = NSTextField(labelWithString: "转发延迟")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let detailLabel = NSTextField(labelWithString: "切换到豆包输入法")
        detailLabel.font = designSettingsAuxiliaryFont
        detailLabel.textColor = designSecondaryTextColor
        detailLabel.lineBreakMode = .byClipping
        configureInlineTimingLabel(detailLabel)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let valueView = makeTimingValueEditor(
            textField: forwardDelayTextField,
            stepper: forwardDelayStepper,
            unitFont: detailLabel.font ?? designSettingsAuxiliaryFont,
            unitColor: detailLabel.textColor ?? designSecondaryTextColor
        )

        let suffixLabel = NSTextField(labelWithString: "后触发语音输入")
        suffixLabel.font = detailLabel.font
        suffixLabel.textColor = detailLabel.textColor
        configureInlineTimingLabel(suffixLabel)

        let sentence = NSStackView(views: [detailLabel, valueView, suffixLabel])
        sentence.orientation = .horizontal
        sentence.spacing = designInlineControlGap
        sentence.alignment = .centerY
        sentence.distribution = .fill

        let row = EditingDismissView()
        row.addSubview(icon)
        row.addSubview(titleLabel)
        row.addSubview(sentence)
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sentence.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: launcherCardContentWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 39).isActive = true
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 29),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            sentence.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 115),
            sentence.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func configureInlineTimingLabel(_ label: NSTextField) {
        let centeredCell = CenteredTextFieldCell(textCell: label.stringValue)
        centeredCell.font = label.font
        centeredCell.textColor = label.textColor
        centeredCell.isEditable = false
        centeredCell.isSelectable = false
        centeredCell.lineBreakMode = label.lineBreakMode
        label.cell = centeredCell
        label.isBordered = false
        label.drawsBackground = false
        label.heightAnchor.constraint(equalToConstant: 25).isActive = true
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
        prefixLabel.font = designSettingsAuxiliaryFont
        prefixLabel.textColor = designSecondaryTextColor
        prefixLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let suffixLabel = NSTextField(labelWithString: suffix)
        suffixLabel.font = designSettingsAuxiliaryFont
        suffixLabel.textColor = designSecondaryTextColor
        suffixLabel.lineBreakMode = .byTruncatingTail
        suffixLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false

        let row = EditingDismissView()
        [icon, titleLabel, prefixLabel, button, suffixLabel].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        row.widthAnchor.constraint(equalToConstant: launcherShortcutContentWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 35).isActive = true
        var constraints: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 29),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            prefixLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 115),
            prefixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 138),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            suffixLabel.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: designInlineControlGap),
            suffixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ]
        if let timingView {
            timingView.translatesAutoresizingMaskIntoConstraints = false
            timingView.widthAnchor.constraint(equalToConstant: timingWidth).isActive = true
            row.addSubview(timingView)
            constraints.append(contentsOf: [
                timingView.leadingAnchor.constraint(equalTo: suffixLabel.trailingAnchor, constant: designInlineControlGap),
                timingView.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func makeTimingControl(title _: String, textField: NSTextField, stepper: NSStepper) -> NSView {
        makeTimingValueEditor(
            textField: textField,
            stepper: stepper,
            unitFont: designSettingsAuxiliaryFont,
            unitColor: designSecondaryTextColor
        )
    }

    private func makeEmptyTimingPlaceholder() -> NSView {
        let placeholder = EditingDismissView()
        placeholder.widthAnchor.constraint(equalToConstant: 172).isActive = true
        placeholder.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return placeholder
    }

    private func makeTimingValueEditor(
        textField: NSTextField,
        stepper: NSStepper,
        unitFont: NSFont = .systemFont(ofSize: 12),
        unitColor: NSColor = NSColor.labelColor.withAlphaComponent(0.52)
    ) -> NSView {
        textField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        textField.heightAnchor.constraint(equalToConstant: 25).isActive = true
        stepper.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stepper.heightAnchor.constraint(equalToConstant: 20).isActive = true
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        stepper.setContentCompressionResistancePriority(.required, for: .horizontal)

        let unitLabel = NSTextField(labelWithString: "ms")
        unitLabel.font = unitFont
        unitLabel.textColor = unitColor

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
        divider.widthAnchor.constraint(equalToConstant: launcherShortcutContentWidth).isActive = true
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
        let timingTextFields = [forwardDelayTextField, longPressTextField]
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
        default:
            return
        }
        syncAutomationConfiguration()
    }

    private func syncAutomationConfiguration() {
        automation.updateConfiguration(
            hold: holdShortcut,
            singleTap: singleTapShortcut,
            forwardDelayMilliseconds: forwardDelayMilliseconds,
            longPressMilliseconds: longPressMilliseconds
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
        font = .systemFont(ofSize: 10, weight: .medium)
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
            .font: font ?? NSFont.systemFont(ofSize: 10, weight: .medium),
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
    private var launcherViewController: LauncherViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("Application did finish launching")
        FileDebugLog.record(level: "INFO", category: "App", message: "Application did finish launching")
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        let controller = LauncherViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: launcherWindowWidth, height: launcherWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: launcherWindowWidth, height: launcherWindowHeight)
        window.contentMaxSize = NSSize(width: launcherWindowWidth, height: launcherWindowHeight)
        window.title = appDisplayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.launcherViewController = controller
        self.window = window
        AppLog.app.info("Main window is visible")
        FileDebugLog.record(level: "INFO", category: "App", message: "Main window is visible")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow(reason: "reopen")
        }
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = appDisplayName
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "退出 \(appDisplayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = "窗口"
        let windowMenu = NSMenu(title: "窗口")
        let showWindowItem = NSMenuItem(
            title: "显示设置窗口",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: "0"
        )
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsWindow(_ sender: Any?) {
        showMainWindow(reason: "menu")
    }

    private func showMainWindow(reason: String) {
        guard let window else {
            AppLog.app.error("Main window reopen requested before window is available")
            FileDebugLog.record(
                level: "ERROR",
                category: "App",
                message: "Main window reopen requested before window is available reason=\(reason)"
            )
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.app.info("Main window reopened reason=\(reason, privacy: .public)")
        FileDebugLog.record(level: "INFO", category: "App", message: "Main window reopened reason=\(reason)")
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
