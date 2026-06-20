import ApplicationServices
import Foundation

struct PlatformReadinessProbe {
  private let inputSourceService = InputSourceService()

  func isAccessibilityTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  func requestAccessibilityTrustPrompt() {
    let options = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  func isDoubaoInputSourceAvailable() -> Bool {
    inputSourceService.isDoubaoInputSourceAvailable()
  }
}
