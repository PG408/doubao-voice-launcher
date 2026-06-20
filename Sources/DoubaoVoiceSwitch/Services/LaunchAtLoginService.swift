import Foundation
import ServiceManagement

struct LaunchAtLoginService {
  func setEnabled(_ isEnabled: Bool) throws {
    if isEnabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  func isEnabled() -> Bool {
    SMAppService.mainApp.status == .enabled
  }
}
