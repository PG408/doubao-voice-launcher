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
    let flags: CGEventFlags
    let display: String
}

private enum TriggerMode: String, CaseIterable {
    case doubleTap = "免按模式：双击快捷键"
    case holdToggle = "长按模式：按下/松开切换"
}

private let defaultRightControlShortcut = Shortcut(
    keyCode: 62,
    flags: .maskControl,
    display: "右⌃"
)
private let rightControlLongPressThreshold: TimeInterval = 0.10
private let rightControlDoubleTapWindow: TimeInterval = 0.45

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
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: keyDown)
        event?.type = .flagsChanged
        event?.flags = keyDown ? shortcut.flags : []
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event?.post(tap: .cghidEventTap)
    }

    private static func tap(shortcut: Shortcut) {
        postModifierEvent(shortcut: shortcut, keyDown: true)
        usleep(60_000)
        postModifierEvent(shortcut: shortcut, keyDown: false)
    }
}

private final class RightControlAutomation {
    private let inputSourceService: InputSourceService
    private let shortcut = defaultRightControlShortcut
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightControlDown = false
    private var rightControlDownAt: TimeInterval = 0
    private var lastShortTapUpAt: TimeInterval = 0
    private var sessionActive = false
    private var longPressWorkItem: DispatchWorkItem?
    private var didTriggerLongPress = false
    private var resumeEventTapWorkItem: DispatchWorkItem?

    var onStatus: ((String) -> Void)?

    init(inputSourceService: InputSourceService) {
        self.inputSourceService = inputSourceService
    }

    func start() -> Bool {
        guard AccessibilityService.ensureTrusted() else {
            onStatus?("后台监听需要辅助功能权限。授权后请重启本 App。")
            return false
        }

        guard AccessibilityService.canListenKeyboardEvents() || AccessibilityService.requestKeyboardEventAccess() else {
            onStatus?("后台监听还需要输入监控权限。请在系统设置中打开本 App 的输入监控权限后重启。")
            return false
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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
        onStatus?("后台监听已开启：右⌃ 长按或双击会自动切到豆包，结束后恢复原输入法。")
        return true
    }

    func stop() {
        resumeEventTapWorkItem?.cancel()
        resumeEventTapWorkItem = nil
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

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let controlIsDown = event.flags.contains(.maskControl)
        if controlIsDown && !isRightControlDown {
            handleRightControlDown()
            return nil
        }

        if !controlIsDown && isRightControlDown {
            handleRightControlUp()
            return nil
        }

        return nil
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

    private func handleRightControlDown() {
        isRightControlDown = true
        didTriggerLongPress = false
        rightControlDownAt = ProcessInfo.processInfo.systemUptime
        let pressStartedAt = rightControlDownAt

        if sessionActive {
            onStatus?("检测到右⌃按下，将结束免按语音输入。")
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRightControlDown else {
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
                ShortcutSender.keyDown(shortcut: self.shortcut)
            }
            self.onStatus?("检测到右⌃长按，已切到豆包并开始语音输入。")
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + rightControlLongPressThreshold, execute: workItem)
    }

    private func handleRightControlUp() {
        let now = ProcessInfo.processInfo.systemUptime
        _ = now - rightControlDownAt
        isRightControlDown = false
        longPressWorkItem?.cancel()
        longPressWorkItem = nil

        if didTriggerLongPress {
            forwardShortcutEvent {
                ShortcutSender.keyUp(shortcut: self.shortcut)
            }
            didTriggerLongPress = false
            sessionActive = false
            restoreAfterDelay(message: "右⌃长按结束，已恢复原输入法。", delay: 0.45)
            return
        }

        if sessionActive {
            guard inputSourceService.beginDoubaoSession() else {
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.forwardShortcutEvent {
                    ShortcutSender.singleTap(shortcut: self.shortcut)
                }
                self.sessionActive = false
                self.restoreAfterDelay(message: "检测到右⌃单击结束免按语音输入，已恢复原输入法。", delay: 0.45)
            }
            lastShortTapUpAt = 0
            return
        }

        if now - lastShortTapUpAt <= rightControlDoubleTapWindow {
            guard inputSourceService.beginDoubaoSession() else {
                onStatus?("切换到豆包输入法失败。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.forwardShortcutEvent {
                    ShortcutSender.doubleTap(shortcut: self.shortcut)
                }
                self.sessionActive = true
                self.onStatus?("检测到右⌃双击，已切到豆包并转发免按语音快捷键。")
            }
            lastShortTapUpAt = 0
            return
        }

        lastShortTapUpAt = now
        onStatus?("检测到一次右⌃短按，等待第二次短按。")
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
}

private final class LauncherViewController: NSViewController {
    private let inputSourceService = InputSourceService()
    private lazy var automation = RightControlAutomation(inputSourceService: inputSourceService)
    private var shortcut = PreferenceReader.loadShortcut() ?? defaultRightControlShortcut
    private var isHoldingShortcut = false
    private var statusMessage: String?

    private let statusLabel = NSTextField(labelWithString: "")
    private let keyCodeField = NSTextField(string: "")
    private let flagsField = NSTextField(string: "")
    private let triggerModePopup = NSPopUpButton()
    private let triggerButton = NSButton(title: "开始/停止语音输入", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 310))
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
        let started = automation.start()
        if started {
            refreshStatus("后台监听已开启。")
        }
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: appDisplayName)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        let explanationLabel = NSTextField(labelWithString: "后台监听右⌃：长按或双击时自动切到豆包；结束后自动恢复原输入法。")
        explanationLabel.font = .systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.lineBreakMode = .byWordWrapping

        let keyCodeLabel = NSTextField(labelWithString: "KeyCode")
        let flagsLabel = NSTextField(labelWithString: "Flags")
        let modeLabel = NSTextField(labelWithString: "触发方式")
        keyCodeField.placeholderString = "右⌃ 是 62"
        flagsField.placeholderString = "右⌃ 是 0x40000"
        triggerModePopup.addItems(withTitles: TriggerMode.allCases.map(\.rawValue))
        triggerModePopup.selectItem(withTitle: TriggerMode.doubleTap.rawValue)

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

        let rightControlButton = NSButton(title: "使用右⌃", target: self, action: #selector(useRightControlShortcut))
        rightControlButton.bezelStyle = .rounded

        let form = NSGridView(views: [
            [keyCodeLabel, keyCodeField],
            [flagsLabel, flagsField],
            [modeLabel, triggerModePopup]
        ])
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing

        let buttonRow = NSStackView(views: [triggerButton, rightControlButton, restoreButton, openSettingsButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        let secondaryButtonRow = NSStackView(views: [openAccessibilityButton, openInputMonitoringButton, reloadButton])
        secondaryButtonRow.orientation = .horizontal
        secondaryButtonRow.spacing = 8
        secondaryButtonRow.distribution = .fillEqually

        let stack = NSStackView(views: [titleLabel, explanationLabel, statusLabel, form, buttonRow, secondaryButtonRow])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            keyCodeField.widthAnchor.constraint(equalToConstant: 280),
            flagsField.widthAnchor.constraint(equalToConstant: 280),
            triggerModePopup.widthAnchor.constraint(equalToConstant: 280),
            statusLabel.widthAnchor.constraint(equalToConstant: 512),
            buttonRow.widthAnchor.constraint(equalToConstant: 512),
            secondaryButtonRow.widthAnchor.constraint(equalToConstant: 512)
        ])
    }

    private func refreshStatus(_ message: String? = nil) {
        if let message {
            statusMessage = message
        }
        keyCodeField.stringValue = "\(shortcut.keyCode)"
        flagsField.stringValue = "0x" + String(shortcut.flags.rawValue, radix: 16)

        let installed = inputSourceService.isDoubaoInstalled() ? "已安装" : "未安装"
        let current = inputSourceService.currentSourceID() ?? "未知"
        let shortcutText = shortcut.display
        let mode = selectedTriggerMode().rawValue
        let prefix = statusMessage.map { "\($0)\n" } ?? ""
        statusLabel.stringValue = "\(prefix)豆包输入法：\(installed)\n当前输入源：\(current)\n快捷键：\(shortcutText)\n触发方式：\(mode)"
    }

    private func shortcutFromFields() -> Shortcut {
        guard let keyCode = UInt16(keyCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return shortcut
        }

        let rawFlagsText = flagsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFlags: UInt64?
        if rawFlagsText.lowercased().hasPrefix("0x") {
            rawFlags = UInt64(rawFlagsText.dropFirst(2), radix: 16)
        } else {
            rawFlags = UInt64(rawFlagsText)
        }

        guard let rawFlags else {
            return shortcut
        }
        return Shortcut(
            keyCode: CGKeyCode(keyCode),
            flags: CGEventFlags(rawValue: rawFlags),
            display: "keyCode=\(keyCode), flags=\(rawFlagsText)"
        )
    }

    private func selectedTriggerMode() -> TriggerMode {
        guard let title = triggerModePopup.selectedItem?.title,
              let mode = TriggerMode(rawValue: title) else {
            return .doubleTap
        }
        return mode
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

        let shortcut = shortcutFromFields()

        guard inputSourceService.selectDoubao() else {
            refreshStatus("切换到豆包输入法失败。")
            return
        }

        self.shortcut = shortcut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            switch self.selectedTriggerMode() {
            case .doubleTap:
                ShortcutSender.doubleTap(shortcut: shortcut)
                self.refreshStatus("已切换到豆包输入法，并按免按模式双击“右⌃”。")
            case .holdToggle:
                if self.isHoldingShortcut {
                    ShortcutSender.keyUp(shortcut: shortcut)
                    self.isHoldingShortcut = false
                    self.triggerButton.title = "开始/停止语音输入"
                    self.refreshStatus("已松开语音快捷键。")
                } else {
                    ShortcutSender.keyDown(shortcut: shortcut)
                    self.isHoldingShortcut = true
                    self.triggerButton.title = "结束长按"
                    self.refreshStatus("已按下语音快捷键；再次点击会松开。")
                }
            }
        }
    }

    @objc private func restoreInputSource() {
        let ok = inputSourceService.restorePrevious()
        refreshStatus(ok ? "已恢复原输入法。" : "没有可恢复的历史输入法。")
    }

    @objc private func reloadShortcut() {
        shortcut = PreferenceReader.loadShortcut() ?? defaultRightControlShortcut
        refreshStatus("未从标准偏好读取到配置时，已回退为截图中的右⌃。")
    }

    @objc private func useRightControlShortcut() {
        shortcut = defaultRightControlShortcut
        keyCodeField.stringValue = "\(shortcut.keyCode)"
        flagsField.stringValue = "0x" + String(shortcut.flags.rawValue, radix: 16)
        triggerModePopup.selectItem(withTitle: TriggerMode.doubleTap.rawValue)
        refreshStatus("已设置为右⌃，并使用免按模式双击。")
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = LauncherViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 310),
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
