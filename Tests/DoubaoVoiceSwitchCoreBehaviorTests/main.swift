import DoubaoVoiceSwitchCore
import Foundation

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
  guard actual == expected else {
    throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
  }
}

func testReadinessRequiresOnlyDoubaoInputSource() throws {
  var state = AppReadinessState()
  try expectEqual(state.status, .preparing, "未检测到豆包输入法时应准备中")

  state.setDoubaoInputSourceAvailable(true)
  try expectEqual(state.status, .running, "检测到豆包输入法后应运行")

  state.pause()
  try expectEqual(state.status, .paused, "用户暂停后应暂停")

  state.resume()
  try expectEqual(state.status, .running, "用户继续后应恢复运行")
}

func testRecognitionWindowPolicy() throws {
  try expectEqual(
    VoiceSessionRecognitionPolicy.windowMilliseconds(for: -0.1),
    0,
    "识别窗口不得小于零秒"
  )
  try expectEqual(
    VoiceSessionRecognitionPolicy.windowMilliseconds(for: 0.5),
    500,
    "识别窗口应支持一秒以内的小数"
  )
  try expectEqual(
    VoiceSessionRecognitionPolicy.windowMilliseconds(for: 2.3),
    2_300,
    "识别窗口应准确换算一位小数"
  )
  try expectEqual(
    VoiceSessionRecognitionPolicy.windowMilliseconds(for: 12),
    10_000,
    "识别窗口不得长于十秒"
  )
}

func testInitialInputSourceOnlyEstablishesBaseline() throws {
  let controller = VoiceInputRestoreController()

  controller.synchronizeCurrentInputSource(.other("com.sogou.inputmethod.sogou.pinyin"))

  try expectEqual(controller.stateDescription, "idle", "初始输入法不得创建候选会话")
  try expectEqual(controller.shouldObserveRunningInput, false, "空闲时不得探测语音状态")
}

func testLeavingInputSourceStartsRecognitionWindow() throws {
  let controller = VoiceInputRestoreController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  controller.synchronizeCurrentInputSource(.other(originalInputSourceID))

  try expectEqual(
    controller.currentInputSourceChanged(
      to: .other("com.apple.keylayout.ABC"),
      recognitionWindowMilliseconds: 3_000
    ),
    [.scheduleDeadline(.recognitionWindow, delayMilliseconds: 3_000)],
    "离开原输入法后应开启一个识别窗口"
  )
  try expectEqual(controller.originalInputSourceID, originalInputSourceID, "应冻结开始时的输入法")
  try expectEqual(controller.stateDescription, "candidate", "应进入候选会话")
  try expectEqual(controller.shouldObserveRunningInput, true, "候选会话应开始探测语音状态")
}

func testIntermediateInputSourcesDoNotReplaceOriginal() throws {
  let controller = VoiceInputRestoreController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  controller.synchronizeCurrentInputSource(.other(originalInputSourceID))

  _ = controller.currentInputSourceChanged(
    to: .other("com.apple.keylayout.ABC"),
    recognitionWindowMilliseconds: 3_000
  )
  _ = controller.currentInputSourceChanged(
    to: .other("com.apple.inputmethod.SCIM.ITABC"),
    recognitionWindowMilliseconds: 3_000
  )
  _ = controller.currentInputSourceChanged(to: .doubao, recognitionWindowMilliseconds: 3_000)

  try expectEqual(controller.originalInputSourceID, originalInputSourceID, "中间输入法不得覆盖起点")
  try expectEqual(
    controller.runningInputChanged(isRunningInput: true),
    [.cancelDeadline],
    "到达豆包并启动语音后应确认会话"
  )
  try expectEqual(controller.stateDescription, "voiceActive", "应进入语音活动状态")
}

func testReturningToOriginalCancelsCandidate() throws {
  let controller = VoiceInputRestoreController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  controller.synchronizeCurrentInputSource(.other(originalInputSourceID))
  _ = controller.currentInputSourceChanged(
    to: .other("com.apple.keylayout.ABC"),
    recognitionWindowMilliseconds: 3_000
  )

  try expectEqual(
    controller.currentInputSourceChanged(
      to: .other(originalInputSourceID),
      recognitionWindowMilliseconds: 3_000
    ),
    [
      .skipRestore(
        reason: .returnedToOriginalBeforeVoice,
        originalInputSourceID: originalInputSourceID
      )
    ],
    "确认语音前返回起点应取消候选会话"
  )
  try expectEqual(controller.stateDescription, "idle", "取消后应回到空闲")
}

func testRunningInputRequiresDoubaoDuringWindow() throws {
  let controller = VoiceInputRestoreController()
  controller.synchronizeCurrentInputSource(.other("com.sogou.inputmethod.sogou.pinyin"))
  _ = controller.currentInputSourceChanged(
    to: .other("com.apple.keylayout.ABC"),
    recognitionWindowMilliseconds: 3_000
  )

  try expectEqual(
    controller.runningInputChanged(isRunningInput: true),
    [],
    "尚未到达豆包时不得确认语音会话"
  )
  try expectEqual(controller.stateDescription, "candidate", "应继续等待豆包")
}

func testRecognitionWindowExpiryDoesNotRestore() throws {
  let controller = VoiceInputRestoreController()
  let originalInputSourceID = "com.apple.keylayout.ABC"
  controller.synchronizeCurrentInputSource(.other(originalInputSourceID))
  _ = controller.currentInputSourceChanged(to: .doubao, recognitionWindowMilliseconds: 3_000)

  try expectEqual(
    controller.deadlineElapsed(.recognitionWindow),
    [
      .skipRestore(
        reason: .recognitionWindowExpired,
        originalInputSourceID: originalInputSourceID
      )
    ],
    "窗口内没有启动语音时不得恢复"
  )
  try expectEqual(controller.stateDescription, "idle", "窗口超时后应回到空闲")
}

func testVoiceEndSchedulesStableRestore() throws {
  let controller = confirmedVoiceController()

  try expectEqual(
    controller.runningInputChanged(isRunningInput: false),
    [
      .scheduleDeadline(
        .restoreWindow,
        delayMilliseconds: VoiceSessionRecognitionPolicy.restoreStabilityDelayMilliseconds
      )
    ],
    "语音结束后应等待稳定期"
  )
  try expectEqual(controller.stateDescription, "restoring", "应进入恢复等待状态")
}

func testVoiceRestartCancelsPendingRestore() throws {
  let controller = confirmedVoiceController()
  _ = controller.runningInputChanged(isRunningInput: false)

  try expectEqual(
    controller.runningInputChanged(isRunningInput: true),
    [.cancelDeadline],
    "稳定期内语音重新开始时应取消恢复"
  )
  try expectEqual(controller.stateDescription, "voiceActive", "应继续跟踪同一语音会话")
}

func testConfirmedVoiceAlwaysRestoresOriginal() throws {
  let controller = confirmedVoiceController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  _ = controller.currentInputSourceChanged(
    to: .other("com.apple.inputmethod.SCIM.ITABC"),
    recognitionWindowMilliseconds: 3_000
  )
  _ = controller.runningInputChanged(isRunningInput: false)

  try expectEqual(
    controller.deadlineElapsed(.restoreWindow),
    [.restoreInputSource(originalInputSourceID: originalInputSourceID)],
    "确认的语音会话结束后应恢复起点，不判断中途输入法"
  )
  try expectEqual(controller.stateDescription, "idle", "恢复决策完成后应回到空闲")
}

func testAlreadyAtOriginalSkipsSelection() throws {
  let controller = confirmedVoiceController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  _ = controller.currentInputSourceChanged(
    to: .other(originalInputSourceID),
    recognitionWindowMilliseconds: 3_000
  )
  _ = controller.runningInputChanged(isRunningInput: false)

  try expectEqual(
    controller.deadlineElapsed(.restoreWindow),
    [
      .skipRestore(
        reason: .alreadyAtOriginalInputSource,
        originalInputSourceID: originalInputSourceID
      )
    ],
    "当前已经是起点时不得重复切换"
  )
}

func testUnavailableOriginalSkipsRestore() throws {
  let controller = confirmedVoiceController()
  let originalInputSourceID = "com.sogou.inputmethod.sogou.pinyin"
  _ = controller.runningInputChanged(isRunningInput: false)

  try expectEqual(
    controller.deadlineElapsed(
      .restoreWindow,
      isOriginalInputSourceAvailable: false
    ),
    [
      .skipRestore(
        reason: .originalInputSourceUnavailable,
        originalInputSourceID: originalInputSourceID
      )
    ],
    "起点输入法不可用时应放弃恢复"
  )
}

func testNextCandidateUsesCurrentSourceAfterExpiry() throws {
  let controller = VoiceInputRestoreController()
  controller.synchronizeCurrentInputSource(.other("input.A"))
  _ = controller.currentInputSourceChanged(
    to: .other("input.B"),
    recognitionWindowMilliseconds: 3_000
  )
  _ = controller.deadlineElapsed(.recognitionWindow)

  _ = controller.currentInputSourceChanged(to: .doubao, recognitionWindowMilliseconds: 3_000)

  try expectEqual(controller.originalInputSourceID, "input.B", "新窗口应使用当前稳定输入法作为起点")
}

private func confirmedVoiceController() -> VoiceInputRestoreController {
  let controller = VoiceInputRestoreController()
  controller.synchronizeCurrentInputSource(.other("com.sogou.inputmethod.sogou.pinyin"))
  _ = controller.currentInputSourceChanged(to: .doubao, recognitionWindowMilliseconds: 3_000)
  _ = controller.runningInputChanged(isRunningInput: true)
  return controller
}

let tests: [(String, () throws -> Void)] = [
  ("testReadinessRequiresOnlyDoubaoInputSource", testReadinessRequiresOnlyDoubaoInputSource),
  ("testRecognitionWindowPolicy", testRecognitionWindowPolicy),
  ("testInitialInputSourceOnlyEstablishesBaseline", testInitialInputSourceOnlyEstablishesBaseline),
  ("testLeavingInputSourceStartsRecognitionWindow", testLeavingInputSourceStartsRecognitionWindow),
  ("testIntermediateInputSourcesDoNotReplaceOriginal", testIntermediateInputSourcesDoNotReplaceOriginal),
  ("testReturningToOriginalCancelsCandidate", testReturningToOriginalCancelsCandidate),
  ("testRunningInputRequiresDoubaoDuringWindow", testRunningInputRequiresDoubaoDuringWindow),
  ("testRecognitionWindowExpiryDoesNotRestore", testRecognitionWindowExpiryDoesNotRestore),
  ("testVoiceEndSchedulesStableRestore", testVoiceEndSchedulesStableRestore),
  ("testVoiceRestartCancelsPendingRestore", testVoiceRestartCancelsPendingRestore),
  ("testConfirmedVoiceAlwaysRestoresOriginal", testConfirmedVoiceAlwaysRestoresOriginal),
  ("testAlreadyAtOriginalSkipsSelection", testAlreadyAtOriginalSkipsSelection),
  ("testUnavailableOriginalSkipsRestore", testUnavailableOriginalSkipsRestore),
  ("testNextCandidateUsesCurrentSourceAfterExpiry", testNextCandidateUsesCurrentSourceAfterExpiry),
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
