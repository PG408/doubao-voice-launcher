import XCTest
@testable import DoubaoVoiceLauncherCore

final class EventTapHealthPolicyTests: XCTestCase {
    func testDisabledTapIsReenabledBeforeRepeatedFailureRecreatesIt() {
        var policy = EventTapHealthPolicy(recreateAfterDisabledChecks: 2)

        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: false,
                isForwardingShortcut: false
            ),
            .reenable
        )
        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: false,
                isForwardingShortcut: false
            ),
            .recreate
        )
    }

    func testEnabledTapResetsDisabledCount() {
        var policy = EventTapHealthPolicy(recreateAfterDisabledChecks: 2)

        _ = policy.nextAction(
            isTapPresent: true,
            isTapEnabled: false,
            isForwardingShortcut: false
        )

        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: true,
                isForwardingShortcut: false
            ),
            .none
        )
        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: false,
                isForwardingShortcut: false
            ),
            .reenable
        )
    }

    func testForwardingShortcutSuppressesRecoveryAndResetsCounts() {
        var policy = EventTapHealthPolicy(recreateAfterDisabledChecks: 2)

        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: false,
                isForwardingShortcut: true
            ),
            .none
        )
        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: false,
                isForwardingShortcut: false
            ),
            .reenable
        )
    }

    func testEnabledTapIsNotPeriodicallyRecreated() {
        var policy = EventTapHealthPolicy(
            recreateAfterDisabledChecks: 2,
            recreateEnabledTapAfterHealthyChecks: 2
        )

        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: true,
                isForwardingShortcut: false,
                canRecreateEnabledTap: true
            ),
            .none
        )
        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: true,
                isTapEnabled: true,
                isForwardingShortcut: false,
                canRecreateEnabledTap: true
            ),
            .none
        )
    }

    func testMissingTapRequiresNoRecovery() {
        var policy = EventTapHealthPolicy(recreateAfterDisabledChecks: 1)

        XCTAssertEqual(
            policy.nextAction(
                isTapPresent: false,
                isTapEnabled: false,
                isForwardingShortcut: false
            ),
            .none
        )
    }
}
