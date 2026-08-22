import Foundation

struct PlatformReadinessProbe {
  private let inputSourceService = InputSourceService()

  func isDoubaoInputSourceAvailable() -> Bool {
    inputSourceService.isDoubaoInputSourceAvailable()
  }
}
