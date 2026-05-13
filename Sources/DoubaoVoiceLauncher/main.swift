import AppKit
import ApplicationServices
import Carbon
import Foundation

private let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
private let appDisplayName = "豆包语音输入切换"
private let doubaoPreferenceDomains = [
    "com.bytedance.inputmethod.doubaoime",
    "com.bytedance.inputmethod.doubaoime.settings"
]

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
}

private let defaultRightControlShortcut = Shortcut(
    keyCode: 62,
    flags: .maskControl,
    display: "右⌃"
)
private let rightControlLongPressThreshold: TimeInterval = 0.10
private let rightControlDoubleTapWindow: TimeInterval = 0.45

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
            return nil
        }
        return sourceID(for: source)
    }

    func beginDoubaoSession() -> Bool {
        if previousSourceID == nil {
            previousSourceID = currentSourceID()
        }
        if currentSourceID() == doubaoInputSourceID {
            return true
        }
        return selectSource(id: doubaoInputSourceID)
    }

    func selectDoubao() -> Bool {
        beginDoubaoSession()
    }

    func restorePrevious() -> Bool {
        guard let previousSourceID else {
            return false
        }
        let ok = selectSource(id: previousSourceID)
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
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    private func inputSource(id: String) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else {
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
            return Shortcut(
                keyCode: CGKeyCode(keyCode),
                flags: CGEventFlags(rawValue: UInt64(rawFlags)),
                display: display
            )
        }
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
        return AXIsProcessTrustedWithOptions(options)
    }

    static func canListenKeyboardEvents() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestKeyboardEventAccess() -> Bool {
        CGRequestListenEventAccess()
    }
}

private enum ShortcutSender {
    private static let syntheticEventMarker: Int64 = 0x44424F494D45

    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    static func doubleTap(shortcut: Shortcut) {
        tap(shortcut: shortcut)
        usleep(130_000)
        tap(shortcut: shortcut)
    }

    static func singleTap(shortcut: Shortcut) {
        tap(shortcut: shortcut)
    }

    static func keyDown(shortcut: Shortcut) {
        postModifierEvent(shortcut: shortcut, keyDown: true)
    }

    static func keyUp(shortcut: Shortcut) {
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

    private static func tap(shortcut: Shortcut) {
        postModifierEvent(shortcut: shortcut, keyDown: true)
        usleep(60_000)
        postModifierEvent(shortcut: shortcut, keyDown: false)
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
    private var activeShortcut: Shortcut?
    private var activeModifierKeyCodes = Set<CGKeyCode>()
    private var activeSupportsLongPress = false
    private var activeSupportsDoubleTap = false

    var onStatus: ((String) -> Void)?

    init(inputSourceService: InputSourceService) {
        self.inputSourceService = inputSourceService
    }

    func start() -> Bool {
        guard eventTap == nil else {
            onStatus?("后台监听已开启。")
            return true
        }

        guard AccessibilityService.ensureTrusted() else {
            onStatus?("后台监听需要辅助功能权限。授权后请重启本 App。")
            return false
        }

        guard AccessibilityService.canListenKeyboardEvents() || AccessibilityService.requestKeyboardEventAccess() else {
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
            onStatus?("无法创建全局键盘监听。请检查辅助功能权限。")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        onStatus?("后台监听已开启：已选择的长按或免按快捷键会自动切到豆包，结束后恢复原输入法。")
        return true
    }

    func updateShortcuts(hold: Shortcut, doubleTap: Shortcut) {
        holdShortcut = hold
        doubleTapShortcut = doubleTap
    }

    func stop() {
        resumeEventTapWorkItem?.cancel()
        resumeEventTapWorkItem = nil
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
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
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            _ = self.inputSourceService.restorePrevious()
            self.sessionActive = false
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

        if sessionActive {
            onStatus?("检测到快捷键按下，将结束免按语音输入。")
            return
        }

        guard supportsLongPress else {
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
                self.onStatus?("切换到豆包输入法失败。")
                return
            }
            self.didTriggerLongPress = true
            self.forwardShortcutEvent {
                ShortcutSender.keyDown(shortcut: shortcut)
            }
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

        if didTriggerLongPress {
            forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: shortcut)
            }
            didTriggerLongPress = false
            sessionActive = false
            resetActiveTrigger()
            restoreAfterDelay(message: "长按模式结束，已恢复原输入法。", delay: 0.45)
            return
        }

        if sessionActive {
            guard inputSourceService.beginDoubaoSession() else {
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.forwardShortcutEvent {
                    ShortcutSender.singleTap(shortcut: shortcut)
                }
                self.sessionActive = false
                self.restoreAfterDelay(message: "检测到快捷键单击结束免按语音输入，已恢复原输入法。", delay: 0.45)
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        guard supportsDoubleTap else {
            resetActiveTrigger()
            return
        }

        if now - lastShortTapUpAt <= rightControlDoubleTapWindow {
            guard inputSourceService.beginDoubaoSession() else {
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.forwardShortcutEvent {
                    ShortcutSender.doubleTap(shortcut: shortcut)
                }
                self.sessionActive = true
                self.onStatus?("检测到免按模式快捷键双击，已切到豆包并转发语音快捷键。")
            }
            lastShortTapUpAt = 0
            resetActiveTrigger()
            return
        }

        lastShortTapUpAt = now
        resetActiveTrigger()
        onStatus?("检测到一次免按模式快捷键，等待第二次按下。")
    }

    private func forwardShortcutEvent(_ send: () -> Void) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        send()

        resumeEventTapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let eventTap = self.eventTap else {
                return
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        resumeEventTapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: workItem)
    }

    private func restoreAfterDelay(message: String, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            _ = self.inputSourceService.restorePrevious()
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

    private let statusLabel = NSTextField(labelWithString: "")
    private let holdShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let doubleTapShortcutButton = NSButton(title: "", target: nil, action: nil)
    private let triggerButton = NSButton(title: "开始/停止语音输入", target: nil, action: nil)
    private let monitorToggleButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        automation.onStatus = { [weak self] message in
            self?.refreshStatus(message)
        }
        automation.updateShortcuts(hold: holdShortcut, doubleTap: doubleTapShortcut)
        let started = automation.start()
        isMonitoring = started
        updateMonitorToggleButton()
        if started {
            refreshStatus("后台监听已开启。")
        }
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: appDisplayName)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        let explanationLabel = NSTextField(labelWithString: "后台监听已选择快捷键：长按或双击时自动切到豆包；结束后自动恢复原输入法。")
        explanationLabel.font = .systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.lineBreakMode = .byWordWrapping

        let holdLabel = NSTextField(labelWithString: "长按模式")
        holdLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let holdDescription = NSTextField(labelWithString: "按住说话，松手结束")
        holdDescription.font = .systemFont(ofSize: 12)
        holdDescription.textColor = .secondaryLabelColor
        let holdTextStack = NSStackView(views: [holdLabel, holdDescription])
        holdTextStack.orientation = .vertical
        holdTextStack.spacing = 2

        let doubleTapLabel = NSTextField(labelWithString: "免按模式")
        doubleTapLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let doubleTapDescription = NSTextField(labelWithString: "双击开始，再次按键结束")
        doubleTapDescription.font = .systemFont(ofSize: 12)
        doubleTapDescription.textColor = .secondaryLabelColor
        let doubleTapTextStack = NSStackView(views: [doubleTapLabel, doubleTapDescription])
        doubleTapTextStack.orientation = .vertical
        doubleTapTextStack.spacing = 2

        holdShortcutButton.target = self
        holdShortcutButton.action = #selector(showHoldShortcutPicker(_:))
        holdShortcutButton.bezelStyle = .rounded
        holdShortcutButton.widthAnchor.constraint(equalToConstant: 160).isActive = true

        doubleTapShortcutButton.target = self
        doubleTapShortcutButton.action = #selector(showDoubleTapShortcutPicker(_:))
        doubleTapShortcutButton.bezelStyle = .rounded
        doubleTapShortcutButton.widthAnchor.constraint(equalToConstant: 160).isActive = true
        updateShortcutButtons()

        triggerButton.target = self
        triggerButton.action = #selector(triggerVoiceInput)
        triggerButton.bezelStyle = .rounded

        let restoreButton = NSButton(title: "恢复原输入法", target: self, action: #selector(restoreInputSource))
        restoreButton.bezelStyle = .rounded

        let reloadButton = NSButton(title: "重读豆包快捷键", target: self, action: #selector(reloadShortcut))
        reloadButton.bezelStyle = .rounded

        let openSettingsButton = NSButton(title: "打开豆包设置", target: self, action: #selector(openDoubaoSettings))
        openSettingsButton.bezelStyle = .rounded

        let openAccessibilityButton = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAccessibilitySettings))
        openAccessibilityButton.bezelStyle = .rounded

        let openInputMonitoringButton = NSButton(title: "打开输入监控设置", target: self, action: #selector(openInputMonitoringSettings))
        openInputMonitoringButton.bezelStyle = .rounded

        monitorToggleButton.target = self
        monitorToggleButton.action = #selector(toggleMonitoring)
        monitorToggleButton.bezelStyle = .rounded
        updateMonitorToggleButton()

        let shortcutForm = NSGridView(views: [
            [holdTextStack, holdShortcutButton],
            [doubleTapTextStack, doubleTapShortcutButton]
        ])
        shortcutForm.rowSpacing = 10
        shortcutForm.columnSpacing = 16
        shortcutForm.column(at: 0).xPlacement = .leading

        let buttonRow = NSStackView(views: [triggerButton, monitorToggleButton, restoreButton, openSettingsButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        let secondaryButtonRow = NSStackView(views: [openAccessibilityButton, openInputMonitoringButton, reloadButton])
        secondaryButtonRow.orientation = .horizontal
        secondaryButtonRow.spacing = 8
        secondaryButtonRow.distribution = .fillEqually

        let stack = NSStackView(views: [titleLabel, explanationLabel, statusLabel, shortcutForm, buttonRow, secondaryButtonRow])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            statusLabel.widthAnchor.constraint(equalToConstant: 512),
            shortcutForm.widthAnchor.constraint(equalToConstant: 512),
            buttonRow.widthAnchor.constraint(equalToConstant: 512),
            secondaryButtonRow.widthAnchor.constraint(equalToConstant: 512)
        ])
    }

    private func refreshStatus(_ message: String? = nil) {
        if let message {
            statusMessage = message
        }

        let installed = inputSourceService.isDoubaoInstalled() ? "已安装" : "未安装"
        let current = inputSourceService.currentSourceID() ?? "未知"
        let prefix = statusMessage.map { "\($0)\n" } ?? ""
        statusLabel.stringValue = "\(prefix)豆包输入法：\(installed)\n当前输入源：\(current)\n长按模式：\(holdShortcut.display)\n免按模式：\(doubleTapShortcut.display)"
    }

    private func updateShortcutButtons() {
        holdShortcutButton.title = "选择：\(holdShortcut.display)"
        doubleTapShortcutButton.title = "选择：\(doubleTapShortcut.display)"
    }

    private func updateMonitorToggleButton() {
        monitorToggleButton.title = isMonitoring ? "暂停监听" : "开始监听"
    }

    @objc private func triggerVoiceInput() {
        guard inputSourceService.isDoubaoInstalled() else {
            refreshStatus("未检测到豆包输入法。请先运行官方安装器并在系统输入法中启用豆包。")
            return
        }

        guard AccessibilityService.ensureTrusted() else {
            refreshStatus("需要在系统设置中授予本 App 辅助功能权限后才能发送快捷键。")
            return
        }

        guard inputSourceService.selectDoubao() else {
            refreshStatus("切换到豆包输入法失败。")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            ShortcutSender.doubleTap(shortcut: self.doubleTapShortcut)
            self.refreshStatus("已切换到豆包输入法，并按免按模式双击“\(self.doubleTapShortcut.display)”。")
        }
    }

    @objc private func restoreInputSource() {
        let ok = inputSourceService.restorePrevious()
        refreshStatus(ok ? "已恢复原输入法。" : "没有可恢复的历史输入法。")
    }

    @objc private func reloadShortcut() {
        let shortcut = PreferenceReader.loadShortcut() ?? defaultRightControlShortcut
        holdShortcut = shortcut
        doubleTapShortcut = shortcut
        ShortcutDefaults.saveHoldShortcut(shortcut)
        ShortcutDefaults.saveDoubleTapShortcut(shortcut)
        automation.updateShortcuts(hold: holdShortcut, doubleTap: doubleTapShortcut)
        updateShortcutButtons()
        refreshStatus("已重读豆包快捷键；未读到配置时回退为右⌃。")
    }

    @objc private func toggleMonitoring() {
        if isMonitoring {
            automation.stop()
            isMonitoring = false
            updateMonitorToggleButton()
            refreshStatus("后台监听已暂停；快捷键暂时不会触发切换。")
            return
        }

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

        let popover = NSPopover()
        let controller = ShortcutPickerViewController(title: title, currentShortcut: currentShortcut)
        controller.onApply = { [weak self, weak popover] shortcut in
            guard let self else {
                return
            }
            switch role {
            case .hold:
                self.holdShortcut = shortcut
                ShortcutDefaults.saveHoldShortcut(shortcut)
                self.refreshStatus("已设置长按模式快捷键：\(shortcut.display)。")
            case .doubleTap:
                self.doubleTapShortcut = shortcut
                ShortcutDefaults.saveDoubleTapShortcut(shortcut)
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
        popover.behavior = .transient
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .maxY)
        shortcutPickerPopover = popover
    }

    @objc private func openDoubaoSettings() {
        let paths = [
            "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app",
            "/Library/Input Methods/豆包输入法.app/Contents/DoubaoImeSettings.app"
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            refreshStatus("已尝试打开豆包设置。")
            return
        }
        refreshStatus("未找到豆包设置页。")
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            refreshStatus("无法打开辅助功能设置。")
            return
        }
        NSWorkspace.shared.open(url)
        refreshStatus("请在辅助功能列表中打开 \(appDisplayName)；若已存在但无效，先移除再重新添加。")
    }

    @objc private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            refreshStatus("无法打开输入监控设置。")
            return
        }
        NSWorkspace.shared.open(url)
        refreshStatus("请在输入监控列表中打开 \(appDisplayName)；若列表中没有，请用加号添加当前 app。")
    }
}

private final class ShortcutPickerViewController: NSViewController {
    var onApply: ((Shortcut) -> Void)?
    var onCancel: (() -> Void)?

    private let panelTitle: String
    private let currentShortcut: Shortcut
    private let validationLabel = NSTextField(labelWithString: "")
    private var candidateButtons: [CGKeyCode: NSButton] = [:]

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: panelTitle)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let descriptionLabel = NSTextField(labelWithString: "勾选一个或多个候选按键作为组合快捷键。")
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 12

        let currentKeyCodes = Set(currentShortcut.keyCodes)
        let candidates = ShortcutFormatter.candidates
        for rowIndex in stride(from: 0, to: candidates.count, by: 3) {
            let rowCandidates = Array(candidates[rowIndex..<min(rowIndex + 3, candidates.count)])
            let buttons = rowCandidates.map { candidate in
                let button = NSButton(checkboxWithTitle: candidate.title, target: self, action: #selector(candidateSelectionChanged))
                button.state = currentKeyCodes.contains(candidate.keyCode) ? .on : .off
                candidateButtons[candidate.keyCode] = button
                return button
            }
            grid.addRow(with: buttons)
        }

        validationLabel.font = .systemFont(ofSize: 12)
        validationLabel.textColor = .secondaryLabelColor
        refreshValidationText()

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded

        let applyButton = NSButton(title: "保存", target: self, action: #selector(applySelection))
        applyButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .trailing

        let stack = NSStackView(views: [titleLabel, descriptionLabel, grid, validationLabel, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.widthAnchor.constraint(equalToConstant: 320),
            validationLabel.widthAnchor.constraint(equalToConstant: 320),
            buttonRow.widthAnchor.constraint(equalToConstant: 320)
        ])
    }

    @objc private func candidateSelectionChanged() {
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = LauncherViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appDisplayName
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
