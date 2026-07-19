import AppKit
import CoreAudio
import Darwin

final class DoubaoAudioInputProbe {
  private static let doubaoImeBundleID = "com.bytedance.inputmethod.doubaoime"
  private static let doubaoImeExecutablePath = "/Library/Input Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme"
  private static let processPathBufferSize = 4_096

  var onRunningInputChanged: ((Bool) -> Void)?

  private let pollingQueue = DispatchQueue(label: "com.bytedance.DoubaoVoiceSwitch.runningInput")
  private var pollingTimer: DispatchSourceTimer?
  private var observedProcessObjectID: AudioObjectID?
  private var lastObservedRunningInput: Bool?

  deinit {
    stopObserving()
  }

  func isRunningInput() -> Bool {
    guard let processID = doubaoProcessID(),
          let processObjectID = processObjectID(for: processID) else {
      return false
    }

    return isRunningInput(processObjectID: processObjectID)
  }

  func startObserving() {
    guard let processID = doubaoProcessID(),
          let processObjectID = processObjectID(for: processID) else {
      stopObserving()
      return
    }

    pollingQueue.sync {
      guard pollingTimer == nil || observedProcessObjectID != processObjectID else {
        return
      }

      stopObservingLocked()
      observedProcessObjectID = processObjectID
      lastObservedRunningInput = nil

      let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
      timer.schedule(
        deadline: .now(),
        repeating: .milliseconds(10),
        leeway: .milliseconds(1)
      )
      timer.setEventHandler { [weak self] in
        self?.pollRunningInput()
      }
      pollingTimer = timer
      timer.resume()
    }
  }

  func stopObserving() {
    pollingQueue.sync {
      stopObservingLocked()
    }
  }

  private func stopObservingLocked() {
    pollingTimer?.setEventHandler {}
    pollingTimer?.cancel()
    pollingTimer = nil
    observedProcessObjectID = nil
    lastObservedRunningInput = nil
  }

  private func pollRunningInput() {
    guard let processObjectID = observedProcessObjectID else {
      return
    }

    let runningInput = isRunningInput(processObjectID: processObjectID)
    guard lastObservedRunningInput != runningInput else {
      return
    }

    lastObservedRunningInput = runningInput
    onRunningInputChanged?(runningInput)
  }

  private var runningInputAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func isRunningInput(processObjectID: AudioObjectID) -> Bool {
    var address = runningInputAddress
    var isRunningInput = UInt32(0)
    var isRunningInputSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      processObjectID,
      &address,
      0,
      nil,
      &isRunningInputSize,
      &isRunningInput
    )
    return status == noErr && isRunningInput == 1
  }

  private func processObjectID(for processID: pid_t) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var processObjectID = AudioObjectID(kAudioObjectUnknown)
    var processObjectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
    var pidValue = processID
    let pidSize = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      pidSize,
      &pidValue,
      &processObjectIDSize,
      &processObjectID
    )
    guard status == noErr, processObjectID != kAudioObjectUnknown else {
      return nil
    }
    return processObjectID
  }

  private func doubaoProcessID() -> pid_t? {
    if let runningApplicationPID = NSWorkspace.shared.runningApplications.first(where: { application in
      application.bundleIdentifier == Self.doubaoImeBundleID
        || application.executableURL?.path == Self.doubaoImeExecutablePath
        || application.bundleURL?.path.hasSuffix("DoubaoIme.app") == true
    })?.processIdentifier {
      return runningApplicationPID
    }

    return processIDFromProcessList()
  }

  private func processIDFromProcessList() -> pid_t? {
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
      var pathBuffer = [CChar](repeating: 0, count: Self.processPathBufferSize)
      let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
      }
      guard pathLength > 0 else {
        continue
      }
      if String(cString: pathBuffer) == Self.doubaoImeExecutablePath {
        return pid
      }
    }
    return nil
  }
}
