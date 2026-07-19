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

func testShortcutPressObserverIgnoresUnconfiguredBridgeModifiers() throws {
  var observer = ShortcutPressObserver(shortcut: DoubaoShortcut(keys: [.rightCommand]))

  try expectEqual(
    observer.observe(
      key: .rightCommand,
      activeModifiers: [.command],
      isFunctionActive: false
    ),
    true,
    "右 Command 按下时应观察到一次配置快捷键"
  )
  try expectEqual(
    observer.observe(
      key: .leftControl,
      activeModifiers: [.control, .command],
      isFunctionActive: false
    ),
    false,
    "豆包桥接产生的非配置 Control 不应改变快捷键观察状态"
  )
  try expectEqual(
    observer.observe(
      key: .rightCommand,
      activeModifiers: [],
      isFunctionActive: false
    ),
    false,
    "右 Command 松开时不应产生新的快捷键观察"
  )
  try expectEqual(
    observer.observe(
      key: .rightCommand,
      activeModifiers: [.command],
      isFunctionActive: false
    ),
    true,
    "完整松开后再次按下右 Command 应产生新的快捷键观察"
  )
}

func testShortcutPressObserverRejectsExtraPhysicalModifiers() throws {
  var observer = ShortcutPressObserver(shortcut: DoubaoShortcut(keys: [.rightCommand]))

  _ = observer.observe(
    key: .leftControl,
    activeModifiers: [.control],
    isFunctionActive: false
  )
  try expectEqual(
    observer.observe(
      key: .rightCommand,
      activeModifiers: [.control, .command],
      isFunctionActive: false
    ),
    false,
    "存在额外物理修饰键时不得匹配右 Command 单键快捷键"
  )
}

func testDefaultDoubaoInputSourceTimeoutIsTwoSeconds() throws {
  let controller = VoiceInputRestoreController()

  try expectEqual(
    controller.shortcutObserved(
      currentInputSource: .other("com.sogou.inputmethod.sogou.pinyin"),
      elapsedMilliseconds: 0
    ),
    [.scheduleInputSourceChangeTimeout(delayMilliseconds: 2_000)],
    "默认应等待豆包输入法两秒后再超时"
  )
}

func testDefaultRunningInputStartTimeoutIsTwoSeconds() throws {
  let controller = VoiceInputRestoreController()

  _ = controller.shortcutObserved(
    currentInputSource: .other("com.sogou.inputmethod.sogou.pinyin"),
    elapsedMilliseconds: 0
  )
  try expectEqual(
    controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 200),
    [.scheduleRunningInputStartTimeout(delayMilliseconds: 2_000)],
    "切到豆包后默认应等待 runningInput 两秒"
  )
}

func testShortcutDuringExistingVoiceDoesNotStartRestoreChain() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  try expectEqual(
    controller.shortcutObserved(
      currentInputSource: .other("com.sogou.inputmethod.sogou.pinyin"),
      isDoubaoRunningInput: true,
      elapsedMilliseconds: 0
    ),
    [.skipRestore(reason: .shortcutObservedDuringActiveVoice)],
    "豆包旧语音仍活动时的快捷键只应停止旧语音，不得创建新链路"
  )
  try expectEqual(controller.stateDescription, "idle", "停止旧语音的快捷键不应改变空闲状态")
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
    [.cancelRunningInputStartTimeout],
    "runningInput=true 后应取消语音启动超时，不应继续保留无效定时器"
  )
  try expectEqual(controller.stateDescription, "voiceActive", "runningInput=true 后应进入语音活动状态")

  try expectEqual(
    controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 820),
    [
      .scheduleRestore(
        originalInputSourceID: originalInputSourceID,
        delayMilliseconds: 500
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

func testRepeatedShortcutDuringStartupPreservesOriginalInputSource() throws {
  let controller = VoiceInputRestoreController(configuration: .test)
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"

  _ = controller.shortcutObserved(
    currentInputSource: .other(originalInputSourceID),
    elapsedMilliseconds: 0
  )
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 120)

  try expectEqual(
    controller.shortcutObserved(currentInputSource: .doubao, elapsedMilliseconds: 180),
    [],
    "语音启动期间的重复快捷键不得重启或清除恢复链路"
  )
  try expectEqual(
    controller.originalInputSourceID,
    originalInputSourceID,
    "重复快捷键不得覆盖最初记录的原输入法"
  )

  _ = controller.runningInputChanged(
    isRunningInput: true,
    currentInputSource: .doubao,
    elapsedMilliseconds: 220
  )
  try expectEqual(
    controller.runningInputChanged(
      isRunningInput: false,
      currentInputSource: .doubao,
      elapsedMilliseconds: 260
    ),
    [
      .scheduleRestore(
        originalInputSourceID: originalInputSourceID,
        delayMilliseconds: 500
      )
    ],
    "重复快捷键结束短语音后仍应恢复最初输入法"
  )
}

func testRunningInputObservationStartsOnlyAfterDoubaoSelection() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  try expectEqual(controller.shouldObserveRunningInput, false, "空闲状态不得探测 runningInput")
  _ = controller.shortcutObserved(
    currentInputSource: .other("com.sogou.inputmethod.sogou.pinyin"),
    elapsedMilliseconds: 0
  )
  try expectEqual(
    controller.shouldObserveRunningInput,
    false,
    "等待豆包切换输入法期间不得探测 runningInput"
  )
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 120)
  try expectEqual(
    controller.shouldObserveRunningInput,
    true,
    "观察到豆包输入法后才应开始探测 runningInput"
  )
  _ = controller.timeoutElapsed(reason: .runningInputStart, elapsedMilliseconds: 1_700)
  try expectEqual(controller.shouldObserveRunningInput, false, "链路超时回到空闲后应停止探测 runningInput")
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

func testTransientInputSourceDuringRunningInputWaitDoesNotLoseOriginalSource() throws {
  let controller = VoiceInputRestoreController(configuration: .test)
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"

  _ = controller.shortcutObserved(currentInputSource: .other(originalInputSourceID), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 180)

  try expectEqual(
    controller.currentInputSourceChanged(to: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 520),
    [],
    "等待 runningInput=true 期间短暂切到 ABC 不应放弃恢复链路"
  )
  try expectEqual(
    controller.stateDescription,
    "waitingForRunningInput",
    "短暂输入法抖动后仍应等待 runningInput=true"
  )
  try expectEqual(
    controller.originalInputSourceID,
    originalInputSourceID,
    "原输入法应保持为快捷键发生前记录的输入法"
  )

  try expectEqual(
    controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 620),
    [],
    "短暂输入法抖动后回到豆包不应重新开始链路"
  )
  _ = controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 760)
  _ = controller.runningInputChanged(isRunningInput: false, currentInputSource: .doubao, elapsedMilliseconds: 1_200)

  try expectEqual(
    controller.restoreWindowElapsed(
      currentInputSource: .doubao,
      isOriginalInputSourceAvailable: true,
      elapsedMilliseconds: 1_800
    ),
    [.restoreInputSource(originalInputSourceID: originalInputSourceID)],
    "语音结束后应恢复到最初记录的原输入法，而不是中途经过的 ABC"
  )
}

func testTransientInputSourceStillTimesOutWhenRunningInputNeverStarts() throws {
  let controller = VoiceInputRestoreController(configuration: .test)

  _ = controller.shortcutObserved(currentInputSource: .other("com.sogou.inputmethod.sogou.pinyin"), elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 180)
  _ = controller.currentInputSourceChanged(to: .other("com.apple.keylayout.ABC"), elapsedMilliseconds: 520)

  try expectEqual(
    controller.timeoutElapsed(reason: .runningInputStart, elapsedMilliseconds: 1_700),
    [.skipRestore(reason: .runningInputStartTimedOut)],
    "短暂输入法抖动后若 runningInput 从未为 true，仍应按超时放弃"
  )
  try expectEqual(controller.stateDescription, "idle", "runningInput 超时后应回到 idle")
}

func testVoiceStopsTrackingAfterInputSourceLeavesDoubao() throws {
  let controller = VoiceInputRestoreController(configuration: .test)
  let originalInputSource = InputSourceIdentity.other("com.sogou.inputmethod.sogou.pinyin")

  _ = controller.shortcutObserved(currentInputSource: originalInputSource, elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  _ = controller.runningInputChanged(isRunningInput: true, currentInputSource: .doubao, elapsedMilliseconds: 300)

  try expectEqual(
    controller.currentInputSourceChanged(to: originalInputSource, elapsedMilliseconds: 600),
    [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)],
    "语音活动期间输入法离开豆包时应立即取消恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "取消恢复后应立即回到 idle")
  try expectEqual(controller.shouldObserveRunningInput, false, "取消恢复后应停止采样 runningInput")
}

func testRunningInputAfterSourceRollbackCancelsRestoreChain() throws {
  let controller = VoiceInputRestoreController(configuration: .test)
  let originalInputSource = InputSourceIdentity.other("com.sogou.inputmethod.sogou.pinyin")

  _ = controller.shortcutObserved(currentInputSource: originalInputSource, elapsedMilliseconds: 0)
  _ = controller.currentInputSourceChanged(to: .doubao, elapsedMilliseconds: 100)
  _ = controller.currentInputSourceChanged(to: originalInputSource, elapsedMilliseconds: 500)

  try expectEqual(
    controller.runningInputChanged(
      isRunningInput: true,
      currentInputSource: originalInputSource,
      elapsedMilliseconds: 1_600
    ),
    [.skipRestore(reason: .currentInputSourceChangedBeforeRestore)],
    "runningInput=true 时当前已不是豆包应取消恢复链路"
  )
  try expectEqual(controller.stateDescription, "idle", "输入法已离开豆包时应回到 idle")
  try expectEqual(controller.shouldObserveRunningInput, false, "取消链路后应停止采样 runningInput")
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
    restoreStabilityDelayMilliseconds: 500
  )
}

let tests: [(String, () throws -> Void)] = [
  ("testStartsPreparing", testStartsPreparing),
  ("testBecomesRunningWhenRequiredPrerequisitesAreReady", testBecomesRunningWhenRequiredPrerequisitesAreReady),
  ("testPauseAndResume", testPauseAndResume),
  ("testMissingPrerequisiteOverridesPausedStatus", testMissingPrerequisiteOverridesPausedStatus),
  ("testRemainsPreparingWhenAnyRequiredPrerequisiteIsMissing", testRemainsPreparingWhenAnyRequiredPrerequisiteIsMissing),
  ("testDoubaoShortcutDisplaysSelectedPhysicalKeysInStableOrder", testDoubaoShortcutDisplaysSelectedPhysicalKeysInStableOrder),
  ("testDoubaoShortcutRejectsEmptySelection", testDoubaoShortcutRejectsEmptySelection),
  ("testDoubaoShortcutMatchesOnlyExactSelectedKeySet", testDoubaoShortcutMatchesOnlyExactSelectedKeySet),
  ("testDoubaoShortcutRoundTripsStorageValue", testDoubaoShortcutRoundTripsStorageValue),
  (
    "testShortcutPressObserverIgnoresUnconfiguredBridgeModifiers",
    testShortcutPressObserverIgnoresUnconfiguredBridgeModifiers
  ),
  (
    "testShortcutPressObserverRejectsExtraPhysicalModifiers",
    testShortcutPressObserverRejectsExtraPhysicalModifiers
  ),
  (
    "testDefaultDoubaoInputSourceTimeoutIsTwoSeconds",
    testDefaultDoubaoInputSourceTimeoutIsTwoSeconds
  ),
  (
    "testDefaultRunningInputStartTimeoutIsTwoSeconds",
    testDefaultRunningInputStartTimeoutIsTwoSeconds
  ),
  (
    "testShortcutDuringExistingVoiceDoesNotStartRestoreChain",
    testShortcutDuringExistingVoiceDoesNotStartRestoreChain
  ),
  (
    "testObservedShortcutFromOtherInputSourceRestoresAfterRunningInputStops",
    testObservedShortcutFromOtherInputSourceRestoresAfterRunningInputStops
  ),
  (
    "testRepeatedShortcutDuringStartupPreservesOriginalInputSource",
    testRepeatedShortcutDuringStartupPreservesOriginalInputSource
  ),
  (
    "testRunningInputObservationStartsOnlyAfterDoubaoSelection",
    testRunningInputObservationStartsOnlyAfterDoubaoSelection
  ),
  ("testShortcutFromDoubaoInputSourceDoesNotRestore", testShortcutFromDoubaoInputSourceDoesNotRestore),
  ("testManualSwitchToDoubaoWithoutShortcutDoesNotRestore", testManualSwitchToDoubaoWithoutShortcutDoesNotRestore),
  ("testRunningInputNeverStartsBeforeTimeoutDoesNotRestore", testRunningInputNeverStartsBeforeTimeoutDoesNotRestore),
  (
    "testTransientInputSourceDuringRunningInputWaitDoesNotLoseOriginalSource",
    testTransientInputSourceDuringRunningInputWaitDoesNotLoseOriginalSource
  ),
  (
    "testTransientInputSourceStillTimesOutWhenRunningInputNeverStarts",
    testTransientInputSourceStillTimesOutWhenRunningInputNeverStarts
  ),
  (
    "testVoiceStopsTrackingAfterInputSourceLeavesDoubao",
    testVoiceStopsTrackingAfterInputSourceLeavesDoubao
  ),
  (
    "testRunningInputAfterSourceRollbackCancelsRestoreChain",
    testRunningInputAfterSourceRollbackCancelsRestoreChain
  ),
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
