import Foundation

struct PrerequisiteItem: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let isReady: Bool
  let actionTitle: String?
}
