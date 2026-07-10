import Carbon
import DoubaoVoiceSwitchCore
import Foundation

struct InputSourceService {
  func currentInputSource() -> InputSourceIdentity {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return .other("")
    }

    if isDoubao(source) {
      return .doubao
    }

    return .other(inputSourceProperty(source, key: kTISPropertyInputSourceID))
  }

  func isDoubaoInputSourceAvailable() -> Bool {
    doubaoInputSource() != nil
  }

  func isInputSourceAvailable(id: String) -> Bool {
    inputSource(withID: id) != nil
  }

  func restoreInputSource(id: String) throws {
    guard let source = inputSource(withID: id) else {
      throw PlatformServiceError.inputSourceNotFound(id)
    }

    let status = TISSelectInputSource(source)
    if status != noErr {
      throw PlatformServiceError.inputSourceSelectionFailed(status)
    }
  }

  private func doubaoInputSource() -> TISInputSource? {
    inputSources().first(where: isDoubao)
  }

  private func inputSource(withID id: String) -> TISInputSource? {
    inputSources().first {
      inputSourceProperty($0, key: kTISPropertyInputSourceID) == id
    }
  }

  private func inputSources() -> [TISInputSource] {
    guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
      return []
    }
    return sources
  }

  private func isDoubao(_ source: TISInputSource) -> Bool {
    let name = inputSourceProperty(source, key: kTISPropertyLocalizedName)
    let id = inputSourceProperty(source, key: kTISPropertyInputSourceID)

    return name.localizedCaseInsensitiveContains("doubao")
      || name.contains("豆包")
      || id.localizedCaseInsensitiveContains("doubao")
  }

  private func inputSourceProperty(_ source: TISInputSource, key: CFString) -> String {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
      return ""
    }

    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }
}

enum PlatformServiceError: Error, CustomStringConvertible {
  case inputSourceNotFound(String)
  case inputSourceSelectionFailed(OSStatus)

  var description: String {
    switch self {
    case let .inputSourceNotFound(id):
      return "Input source not found: \(id)"
    case let .inputSourceSelectionFailed(status):
      return "Input source selection failed: \(status)"
    }
  }
}
