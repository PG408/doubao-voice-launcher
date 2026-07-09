import DoubaoVoiceSwitchCore
import Foundation

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
  if actual != expected {
    throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
  }
}

func testStartsPreparing() throws {
  let state = AppReadinessState()
  try expectEqual(state.status, .preparing, "启动时应进入准备中")
}

func testBecomesRunningWhenRequiredPrerequisitesAreReady() throws {
  var state = AppReadinessState()
  state.setAccessibilityTrusted(true)
  state.setDoubaoInputSourceAvailable(true)
  try expectEqual(state.status, .running, "辅助功能和豆包输入法满足后应进入运行中")
}

func testPauseAndResume() throws {
  var state = AppReadinessState(accessibilityTrusted: true, doubaoInputSourceAvailable: true)
  state.pause()
  try expectEqual(state.status, .paused, "暂停后应进入暂停中")
  state.resume()
  try expectEqual(state.status, .running, "继续后应回到运行中")
}

func testMissingPrerequisiteOverridesPausedStatus() throws {
  var state = AppReadinessState(accessibilityTrusted: true, doubaoInputSourceAvailable: true)
  state.pause()
  state.setAccessibilityTrusted(false)
  try expectEqual(state.status, .preparing, "前置条件缺失时应显示准备中")
  state.setAccessibilityTrusted(true)
  try expectEqual(state.status, .paused, "前置条件恢复后仍应保持用户暂停")
}

func testRemainsPreparingWhenAnyRequiredPrerequisiteIsMissing() throws {
  var state = AppReadinessState(accessibilityTrusted: true, doubaoInputSourceAvailable: true)
  state.setDoubaoInputSourceAvailable(false)
  try expectEqual(state.status, .preparing, "必要前置条件缺失时应保持准备中")
}

func testDiagnosticLoggerWritesDailyLogAndPrunesExpiredFiles() throws {
  let fileManager = FileManager.default
  let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directory) }

  let oldLog = directory.appendingPathComponent("2026-06-10.log")
  try "old".write(to: oldLog, atomically: true, encoding: .utf8)

  let now = Date(timeIntervalSince1970: 1_781_950_800)
  let logger = DiagnosticLogger(logDirectory: directory, retentionDays: 7)
  try logger.record(DiagnosticLogEntry(timestamp: now, category: .shortcut, message: "handled handoff trigger"))
  try logger.pruneLogs(now: now)

  let todayLog = directory.appendingPathComponent("2026-06-20.log")
  let contents = try String(contentsOf: todayLog, encoding: .utf8)
  try expectEqual(fileManager.fileExists(atPath: oldLog.path), false, "过期日志应被清理")
  if !contents.contains("handled handoff trigger") {
    throw TestFailure(description: "当天日志应包含写入事件")
  }
}

func testDoubaoShortcutDisplaysSelectedPhysicalKeysInStableOrder() throws {
  let shortcut = DoubaoShortcut(keys: [.rightCommand, .function, .leftControl])
  try expectEqual(shortcut.displayText, "L⌃ + R⌘ + Fn", "豆包快捷键应按稳定顺序显示已选择物理键")
}

func testDoubaoShortcutRejectsEmptySelection() throws {
  let shortcut = DoubaoShortcut(keys: [])
  try expectEqual(shortcut.keys, [.rightCommand], "豆包快捷键为空时应回退到默认右 Command")
}

func testDoubaoShortcutMatchesOnlyExactSelectedKeySet() throws {
  let shortcut = DoubaoShortcut(keys: [.rightCommand, .function])

  try expectEqual(
    shortcut.matches(activeKeys: [.rightCommand, .function]),
    true,
    "豆包快捷键应匹配完全一致的物理键集合"
  )
  try expectEqual(
    shortcut.matches(activeKeys: [.leftCommand, .function]),
    false,
    "豆包快捷键不应把左 Command 当成右 Command"
  )
  try expectEqual(
    shortcut.matches(activeKeys: [.rightCommand]),
    false,
    "豆包快捷键不应匹配缺失按键的集合"
  )
  try expectEqual(
    shortcut.matches(activeKeys: [.rightCommand, .function, .leftOption]),
    false,
    "豆包快捷键不应匹配额外按键的集合"
  )
}

func testDoubaoShortcutRoundTripsStorageValue() throws {
  let shortcut = DoubaoShortcut(keys: [.leftOption, .rightCommand, .function])
  let restored = DoubaoShortcut(storageValue: shortcut.storageValue)
  try expectEqual(restored, shortcut, "豆包快捷键应能从持久化字符串恢复")
}

func testObservedShortcutFromOtherInputSourceRestoresAfterRunningInputStops() throws {
  let controller = VoiceInputRestoreController(configuration: .test)
  let originalInputSourceID = "com.apple.inputmethod.SCIM.ITABC"

  try expectEqual(
    controller.shortcutObserved(currentInputSource: .other(originalInputSourceID), elapsedMilliseconds: 0),
    [.scheduleInputSourceChangeTimeout(delayMilliseconds: 1_000)],
    "非豆包输入法下观察到快捷键后，只应等待豆包自己切换输入法"
  )
  try expectEqual(controller.stateDescription, "waitingForDoubao", "观察快捷键后应等待切换到豆包输入法")

  try expectEqual(
    controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 120),
    [.scheduleRunningInputStartTimeout(delayMilliseconds: 1_500)],
    "切到豆包后应等待 runningInput=true"
  )
  try expectEqual(controller.stateDescription, "waitingForRunningInput", "切到豆包后应等待语音输入开始")

  try expectEqual(
    controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 320),
    [],
    "runningInput=true 只确认链路成立，不应恢复输入法"
  )
  try expectEqual(controller.stateDescription, "voiceActive", "runningInput=true 后应进入语音活动状态")

  try expectEqual(
    controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 820),
    [
      .scheduleRestore(
        originalInputSourceID: originalInputSourceID,
        delayMilliseconds: 500,
        maximumDelayMilliseconds: 1_000
      )
    ],
    "runningInput=false 后应安排稳定期恢复"
  )
  try expectEqual(controller.stateDescription, "restoring", "runningInput=false 后应进入恢复等待状态")

  try expectEqual(
    controller.restoreWindowElapsed(
      currentInputSource: .doubao,
      isOriginalInputSourceAvailable: true,
      elapsedMilliseconds: 1_320
    ),
    [.restoreInputSource(originalInputSourceID: originalInputSourceID)],
    "稳定期后若当前仍为豆包，应恢复快捷键发生前的原输入法"
  )
  try expectEqual(controller.stateDescription, "idle", "恢复决策完成后应回到 idle")
}

func testShortcutEventsAreAlwaysPassThrough() throws {
  let policy = ShortcutEventForwardingPolicy()

  try expectEqual(policy.keyDownForwarding(), .passThrough, "快捷键 keyDown 必须透传")
  try expectEqual(policy.keyUpForwarding(), .passThrough, "快捷键 keyUp 必须透传")
}

func testShortcutFromDoubaoInputSourceDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  try expectEqual(
    controller.shortcutObserved(currentInputSource: .doubao, elapsedMilliseconds: 0),
    [.skipRestore(reason: .shortcutStartedFromDoubao)],
    "用户本来就在豆包输入法时按快捷键不得恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "豆包输入法内触发不应创建链路")
}

func testManualSwitchToDoubaoWithoutShortcutDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  try expectEqual(
    controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 200),
    [],
    "未先观察到快捷键时，手动切到豆包不得恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "手动切换不得创建恢复链路")
}

func testRunningInputNeverStartsBeforeTimeoutDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  try expectEqual(
    controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 400),
    [],
    "切到豆包后 runningInput 从未为 true 时不得恢复"
  )
  try expectEqual(
    controller.timeoutElapsed(reason: .runningInputStart, elapsedMilliseconds: 1_600),
    [.skipRestore(reason: .runningInputStartTimedOut)],
    "切到豆包后超时未进入 runningInput=true 应放弃"
  )
  try expectEqual(controller.stateDescription, "idle", "runningInput 超时后应回到 idle")
}

func testRestoreWaitsForStabilityDelay() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  _ = controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 200)
  _ = controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 500)

  try expectEqual(
    controller.restoreWindowElapsed(
      currentInputSource: .doubao,
      isOriginalInputSourceAvailable: true,
      elapsedMilliseconds: 900
    ),
    [],
    "runningInput=false 后稳定期未到时不得恢复"
  )
  try expectEqual(controller.stateDescription, "restoring", "稳定期未到应继续保持 restoring")
}

func testUserSwitchesAwayBeforeRestoreDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  _ = controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 200)
  _ = controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 500)

  try expectEqual(
    controller.restoreWindowElapsed(
      currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"),
      isOriginalInputSourceAvailable: true,
      elapsedMilliseconds: 1_000
    ),
    [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)],
    "恢复前用户已经手动切走输入法时不得恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "放弃恢复后应回到 idle")
}

func testShortcutTimeoutBeforeDoubaoInputSourceDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 0)
  try expectEqual(
    controller.timeoutElapsed(reason: .doubaoInputSource, elapsedMilliseconds: 1_100),
    [.skipRestore(reason: .doubaoInputSourceTimedOut)],
    "快捷键后超时未切到豆包应放弃"
  )
  try expectEqual(controller.stateDescription, "idle", "输入法切换超时后应回到 idle")
}

func testUnavailableOriginalInputSourceDoesNotRestore() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  _ = controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 200)
  _ = controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 500)

  try expectEqual(
    controller.restoreWindowElapsed(
      currentInputSource: .doubao,
      isOriginalInputSourceAvailable: false,
      elapsedMilliseconds: 1_000
    ),
    [.skipRestore(reason: .originalInputSourceUnavailable)],
    "原输入法为空或不可用时不得恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "原输入法不可用后应回到 idle")
}

private extension VoiceInputRestoreConfiguration {
  static let test = VoiceInputRestoreConfiguration(
    doubaoInputSourceTimeoutMilliseconds: 1_000,
    runningInputStartTimeoutMilliseconds: 1_500,
    restoreStabilityDelayMilliseconds: 500,
    restoreMaximumDelayMilliseconds: 1_000
  )
}

let tests: [(String, () throws -> Void)] = [
  ("testStartsPreparing", testStartsPreparing),
  ("testBecomesRunningWhenRequiredPrerequisitesAreReady", testBecomesRunningWhenRequiredPrerequisitesAreReady),
  ("testPauseAndResume", testPauseAndResume),
  ("testMissingPrerequisiteOverridesPausedStatus", testMissingPrerequisiteOverridesPausedStatus),
  ("testRemainsPreparingWhenAnyRequiredPrerequisiteIsMissing", testRemainsPreparingWhenAnyRequiredPrerequisiteIsMissing),
  ("testDiagnosticLoggerWritesDailyLogAndPrunesExpiredFiles", testDiagnosticLoggerWritesDailyLogAndPrunesExpiredFiles),
  ("testDoubaoShortcutDisplaysSelectedPhysicalKeysInStableOrder", testDoubaoShortcutDisplaysSelectedPhysicalKeysInStableOrder),
  ("testDoubaoShortcutRejectsEmptySelection", testDoubaoShortcutRejectsEmptySelection),
  ("testDoubaoShortcutMatchesOnlyExactSelectedKeySet", testDoubaoShortcutMatchesOnlyExactSelectedKeySet),
  ("testDoubaoShortcutRoundTripsStorageValue", testDoubaoShortcutRoundTripsStorageValue),
  (
    "testObservedShortcutFromOtherInputSourceRestoresAfterRunningInputStops",
    testObservedShortcutFromOtherInputSourceRestoresAfterRunningInputStops
  ),
  ("testShortcutEventsAreAlwaysPassThrough", testShortcutEventsAreAlwaysPassThrough),
  ("testShortcutFromDoubaoInputSourceDoesNotRestore", testShortcutFromDoubaoInputSourceDoesNotRestore),
  ("testManualSwitchToDoubaoWithoutShortcutDoesNotRestore", testManualSwitchToDoubaoWithoutShortcutDoesNotRestore),
  ("testRunningInputNeverStartsBeforeTimeoutDoesNotRestore", testRunningInputNeverStartsBeforeTimeoutDoesNotRestore),
  ("testRestoreWaitsForStabilityDelay", testRestoreWaitsForStabilityDelay),
  ("testUserSwitchesAwayBeforeRestoreDoesNotRestore", testUserSwitchesAwayBeforeRestoreDoesNotRestore),
  ("testShortcutTimeoutBeforeDoubaoInputSourceDoesNotRestore", testShortcutTimeoutBeforeDoubaoInputSourceDoesNotRestore),
  ("testUnavailableOriginalInputSourceDoesNotRestore", testUnavailableOriginalInputSourceDoesNotRestore),
]

do {
  for (name, test) in tests {
    try test()
    print("PASS \(name)")
  }
} catch {
  print("FAIL \(error)")
  exit(1)
}
