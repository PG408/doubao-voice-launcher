import DoubaoVoiceLauncherCore
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

func testInputSourceHandoffSelectsDoubaoAndRestoresOriginalInputSource() throws {
  let controller = InputSourceHandoffController(
    longPressThresholdMilliseconds: 900,
    longPressRestoreDelayMilliseconds: 180
  )

  try expectEqual(
    controller.shortcutBecameActive(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC")),
    [.selectDoubaoInputSource],
    "快捷键按下时只应切换到豆包输入法"
  )
  try expectEqual(
    controller.shortcutLongPressThresholdReached(),
    true,
    "长按应由 keyDown 后的 timer 命中触发，而不是 keyUp 时按时长推断"
  )
  try expectEqual(
    controller.shortcutBecameInactive(),
    [
      .scheduleRestoreInputSource(
        "com.apple.inputmethod.SCIM.ITABC",
        delayMilliseconds: 180,
        reason: .longPressRelease
      )
    ],
    "长按释放后应快速恢复原输入法"
  )
}

func testInputSourceHandoffKeepsDoubaoInputSourceAfterFirstShortPress() throws {
  let controller = InputSourceHandoffController(
    longPressThresholdMilliseconds: 900,
    longPressRestoreDelayMilliseconds: 180
  )

  _ = controller.shortcutBecameActive(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"))
  try expectEqual(
    controller.shortcutBecameInactive(),
    [],
    "第一次短按释放后不应恢复原输入法，应等待豆包单击语音的结束意图"
  )
}

func testInputSourceHandoffRestoresOriginalInputSourceAfterSecondShortPress() throws {
  let controller = InputSourceHandoffController(
    longPressThresholdMilliseconds: 900,
    longPressRestoreDelayMilliseconds: 180
  )

  _ = controller.shortcutBecameActive(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"))
  _ = controller.shortcutBecameInactive()
  try expectEqual(
    controller.stateDescription,
    "shortClickSyntheticHoldActive",
    "第一次短按释放后应进入合成持有状态"
  )
  _ = controller.shortcutBecameActive(currentInputSource: .doubao)

  try expectEqual(
    controller.shortcutBecameInactive(),
    [
      .scheduleRestoreInputSource(
        "com.apple.inputmethod.SCIM.ITABC",
        delayMilliseconds: 180,
        reason: .secondShortClickRelease
      )
    ],
    "第二次短按释放后应恢复第一次触发前的原输入法"
  )
}

func testInputSourceHandoffUsesFallbackOriginalInputSourceWhenAlreadyUsingDoubao() throws {
  let controller = InputSourceHandoffController(
    longPressThresholdMilliseconds: 500,
    longPressRestoreDelayMilliseconds: 180
  )

  try expectEqual(
    controller.shortcutBecameActive(
      currentInputSource: .doubao,
      fallbackOriginalInputSourceID: "com.apple.inputmethod.SCIM.ITABC"
    ),
    [],
    "当前已经是豆包输入法时不应重复切换"
  )
  try expectEqual(
    controller.shortcutLongPressThresholdReached(),
    true,
    "fallback 接力也应通过 timer 进入长按状态"
  )
  try expectEqual(
    controller.shortcutBecameInactive(),
    [
      .scheduleRestoreInputSource(
        "com.apple.inputmethod.SCIM.ITABC",
        delayMilliseconds: 180,
        reason: .longPressRelease
      )
    ],
    "当前已经停在豆包输入法时，应使用最近一次非豆包输入法作为恢复目标"
  )
}

func testInputSourceHandoffDoesNotInferLongPressFromReleaseDuration() throws {
  let controller = InputSourceHandoffController(longPressRestoreDelayMilliseconds: 180)

  _ = controller.shortcutBecameActive(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"))
  try expectEqual(
    controller.shortcutBecameInactive(),
    [],
    "未收到 longPress timer 命中前，释放不应被推断为长按"
  )
}

func testLongPressThresholdPreferenceClampsToSupportedRange() throws {
  try expectEqual(
    LongPressThresholdPreference.defaultMilliseconds,
    100,
    "长按判定时间默认值应保持当前体感较好的 100ms"
  )
  try expectEqual(
    LongPressThresholdPreference.clamped(20),
    50,
    "长按判定时间不应低于 50ms"
  )
  try expectEqual(
    LongPressThresholdPreference.clamped(640),
    500,
    "长按判定时间不应高于 500ms"
  )
  try expectEqual(
    LongPressThresholdPreference.clamped(130),
    130,
    "长按判定时间范围内数值应保持不变"
  )
}

func testInputSourceHandoffUpdatesLongPressThreshold() throws {
  let controller = InputSourceHandoffController()

  controller.updateLongPressThresholdMilliseconds(180)

  try expectEqual(
    controller.longPressThresholdMilliseconds,
    180,
    "设置页更新后状态机应使用新的长按判定时间"
  )
}

func testShortcutForwardingCapturesHandoffKeyDownAndSynthesizesDoubaoActions() throws {
  let policy = ShortcutEventForwardingPolicy()

  try expectEqual(
    policy.keyDownForwarding(
      startedFromInputSourceHandoff: true,
      releasePressKind: .short,
      isSuppressionWindowActive: false
    ),
    .captureForSyntheticForwarding,
    "从非豆包切换时，首次 keyDown 应只捕获，不应按固定 500ms 自动转发"
  )
  try expectEqual(
    policy.keyDownForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: .short,
      isSuppressionWindowActive: false
    ),
    .passThrough,
    "非输入法接力的 keyDown 应直接放行"
  )
  try expectEqual(
    policy.keyDownForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: .syntheticHoldRelease,
      isSuppressionWindowActive: false
    ),
    .suppress,
    "第二次短按用于释放合成持有，物理 keyDown 不应透传给豆包"
  )
  try expectEqual(
    policy.keyDownForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: nil,
      isSuppressionWindowActive: true
    ),
    .suppress,
    "兜底窗口内的新快捷键 keyDown 应被完全忽略"
  )
  try expectEqual(
    policy.keyUpForwarding(
      startedFromInputSourceHandoff: true,
      releasePressKind: .short,
      pressDurationMilliseconds: 75,
      isSuppressionWindowActive: false
    ),
    .startSyntheticHold,
    "从非豆包切换后的第一次短按应启动合成持有，不应立即补发 keyUp"
  )
  try expectEqual(
    policy.keyUpForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: .syntheticHoldRelease,
      pressDurationMilliseconds: 75,
      isSuppressionWindowActive: false
    ),
    .releaseSyntheticHold,
    "第二次短按释放应补发 synthetic keyUp 结束合成持有"
  )
  try expectEqual(
    policy.keyUpForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: nil,
      pressDurationMilliseconds: 75,
      isSuppressionWindowActive: true
    ),
    .suppress,
    "兜底窗口内的新快捷键 keyUp 应被完全忽略"
  )
  try expectEqual(
    policy.keyUpForwarding(
      startedFromInputSourceHandoff: true,
      releasePressKind: .long,
      pressDurationMilliseconds: 75,
      isSuppressionWindowActive: true
    ),
    .forwardSyntheticKeyUp,
    "长按本次真实释放不能被兜底窗口拦截，否则会造成合成按键卡住"
  )
  try expectEqual(
    policy.keyUpForwarding(
      startedFromInputSourceHandoff: false,
      releasePressKind: .short,
      pressDurationMilliseconds: 75,
      isSuppressionWindowActive: false
    ),
    .passThrough,
    "非输入法接力产生的短按释放应直接放行"
  )
}

func testInputSourceHandoffBypassesWhenAlreadyUsingDoubaoInputSource() throws {
  let controller = InputSourceHandoffController()

  try expectEqual(
    controller.shortcutBecameActive(currentInputSource: .doubao),
    [],
    "当前已经是豆包输入法时不应切换输入法"
  )
  try expectEqual(
    controller.shortcutBecameInactive(),
    [],
    "没有原输入法记录时不应恢复输入法"
  )
}

func testInputSourceHandoffDoesNotDuplicateSelectionWhileActive() throws {
  let controller = InputSourceHandoffController()

  _ = controller.shortcutBecameActive(currentInputSource: .other("com.apple.inputmethod.SCIM.ITABC"))
  try expectEqual(
    controller.shortcutBecameActive(currentInputSource: .other("com.apple.keylayout.ABC")),
    [],
    "快捷键保持按下期间不应重复切换或覆盖原输入法"
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
  ("testInputSourceHandoffSelectsDoubaoAndRestoresOriginalInputSource", testInputSourceHandoffSelectsDoubaoAndRestoresOriginalInputSource),
  ("testInputSourceHandoffKeepsDoubaoInputSourceAfterFirstShortPress", testInputSourceHandoffKeepsDoubaoInputSourceAfterFirstShortPress),
  ("testInputSourceHandoffRestoresOriginalInputSourceAfterSecondShortPress", testInputSourceHandoffRestoresOriginalInputSourceAfterSecondShortPress),
  ("testInputSourceHandoffUsesFallbackOriginalInputSourceWhenAlreadyUsingDoubao", testInputSourceHandoffUsesFallbackOriginalInputSourceWhenAlreadyUsingDoubao),
  ("testInputSourceHandoffDoesNotInferLongPressFromReleaseDuration", testInputSourceHandoffDoesNotInferLongPressFromReleaseDuration),
  ("testLongPressThresholdPreferenceClampsToSupportedRange", testLongPressThresholdPreferenceClampsToSupportedRange),
  ("testInputSourceHandoffUpdatesLongPressThreshold", testInputSourceHandoffUpdatesLongPressThreshold),
  ("testShortcutForwardingCapturesHandoffKeyDownAndSynthesizesDoubaoActions", testShortcutForwardingCapturesHandoffKeyDownAndSynthesizesDoubaoActions),
  ("testInputSourceHandoffBypassesWhenAlreadyUsingDoubaoInputSource", testInputSourceHandoffBypassesWhenAlreadyUsingDoubaoInputSource),
  ("testInputSourceHandoffDoesNotDuplicateSelectionWhileActive", testInputSourceHandoffDoesNotDuplicateSelectionWhileActive)
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
