public enum EventTapHealthAction: Equatable {
    case none
    case reenable
    case recreate
}

public struct EventTapHealthPolicy {
    private let recreateAfterDisabledChecks: Int
    private var disabledCheckCount = 0

    public init(
        recreateAfterDisabledChecks: Int = 2,
        recreateEnabledTapAfterHealthyChecks: Int = 30
    ) {
        self.recreateAfterDisabledChecks = max(1, recreateAfterDisabledChecks)
    }

    public mutating func nextAction(
        isTapPresent: Bool,
        isTapEnabled: Bool,
        isForwardingShortcut: Bool,
        canRecreateEnabledTap: Bool = false
    ) -> EventTapHealthAction {
        guard isTapPresent, !isForwardingShortcut else {
            reset()
            return .none
        }

        if isTapEnabled {
            disabledCheckCount = 0
            return .none
        }

        disabledCheckCount += 1
        if disabledCheckCount >= recreateAfterDisabledChecks {
            disabledCheckCount = 0
            return .recreate
        }

        return .reenable
    }

    public mutating func reset() {
        disabledCheckCount = 0
    }
}
