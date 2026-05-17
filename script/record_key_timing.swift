import ApplicationServices
import Foundation

final class KeyTimingLogger {
    private let formatter: ISO8601DateFormatter
    private let startUptime: TimeInterval
    private let fileHandle: FileHandle?

    init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startUptime = ProcessInfo.processInfo.systemUptime

        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DoubaoVoiceLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        let logFile = logDirectory.appendingPathComponent("KeyTiming.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        _ = try? fileHandle?.seekToEnd()
    }

    deinit {
        try? fileHandle?.close()
    }

    func write(_ message: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsedMilliseconds = (uptime - startUptime) * 1_000
        let line = String(
            format: "%@ uptime=%.6f elapsed=%.3fms %@\n",
            formatter.string(from: Date()),
            uptime,
            elapsedMilliseconds,
            message
        )
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }
}

let keyNames: [Int64: String] = [
    0: "A",
    1: "S",
    2: "D",
    3: "F",
    4: "H",
    5: "G",
    6: "Z",
    7: "X",
    8: "C",
    9: "V",
    11: "B",
    12: "Q",
    13: "W",
    14: "E",
    15: "R",
    16: "Y",
    17: "T",
    31: "O",
    32: "U",
    34: "I",
    35: "P",
    36: "Return",
    37: "L",
    38: "J",
    40: "K",
    45: "N",
    46: "M",
    48: "Tab",
    49: "Space",
    51: "Delete",
    53: "Escape",
    54: "RightCommand",
    55: "LeftCommand",
    56: "LeftShift",
    57: "CapsLock",
    58: "LeftOption",
    59: "LeftControl",
    60: "RightShift",
    61: "RightOption",
    62: "RightControl",
    63: "Function",
]

func modifierMask(for keyCode: Int64) -> CGEventFlags? {
    switch keyCode {
    case 54, 55:
        return .maskCommand
    case 56, 60:
        return .maskShift
    case 58, 61:
        return .maskAlternate
    case 59, 62:
        return .maskControl
    case 57:
        return .maskAlphaShift
    case 63:
        return .maskSecondaryFn
    default:
        return nil
    }
}

func modifierSummary(_ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskCommand) {
        parts.append("cmd")
    }
    if flags.contains(.maskShift) {
        parts.append("shift")
    }
    if flags.contains(.maskAlternate) {
        parts.append("option")
    }
    if flags.contains(.maskControl) {
        parts.append("control")
    }
    if flags.contains(.maskAlphaShift) {
        parts.append("caps")
    }
    if flags.contains(.maskSecondaryFn) {
        parts.append("fn")
    }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func eventTypeName(_ type: CGEventType) -> String {
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

let logger = KeyTimingLogger()
var eventTap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        logger.write("eventTapDisabled type=\(eventTypeName(type))")
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            logger.write("eventTapReenabled")
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let keyName = keyNames[keyCode] ?? "Unknown"
    let action: String
    if type == .keyDown {
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
        action = autorepeat == 0 ? "down" : "repeat"
    } else if type == .keyUp {
        action = "up"
    } else if type == .flagsChanged, let mask = modifierMask(for: keyCode) {
        action = flags.contains(mask) ? "down" : "up"
    } else {
        action = "changed"
    }

    logger.write(
        String(
            format: "event=%@ action=%@ keyCode=%lld key=%@ flags=0x%016llx mods=%@",
            eventTypeName(type),
            action,
            keyCode,
            keyName,
            flags.rawValue,
            modifierSummary(flags)
        )
    )
    return Unmanaged.passUnretained(event)
}

let eventMask =
    CGEventMask(1 << CGEventType.keyDown.rawValue)
    | CGEventMask(1 << CGEventType.keyUp.rawValue)
    | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
)

guard let eventTap else {
    logger.write("failedToCreateEventTap")
    logger.write("grant Input Monitoring or Accessibility permission to the terminal host, then rerun")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

logger.write("started log=~/Library/Logs/DoubaoVoiceLauncher/KeyTiming.log")
logger.write("press Control-C to stop")
CFRunLoopRun()
