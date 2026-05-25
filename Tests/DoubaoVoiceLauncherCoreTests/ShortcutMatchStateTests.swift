import XCTest
@testable import DoubaoVoiceLauncherCore

final class ShortcutMatchStateTests: XCTestCase {
    func testSingleModifierShortcutIgnoresUnconfiguredActiveModifiers() {
        XCTAssertTrue(
            ShortcutMatchState.isPressed(
                changedKeyCode: 54,
                activeModifierKeyCodes: [54, 61],
                shortcutKeyCodes: [54]
            )
        )
    }

    func testCombinationShortcutRequiresAllConfiguredModifiers() {
        XCTAssertFalse(
            ShortcutMatchState.isPressed(
                changedKeyCode: 54,
                activeModifierKeyCodes: [54],
                shortcutKeyCodes: [54, 61]
            )
        )
    }

    func testShortcutReleaseIgnoresUnconfiguredActiveModifiers() {
        XCTAssertTrue(
            ShortcutMatchState.isReleased(
                changedKeyCode: 54,
                activeModifierKeyCodes: [61],
                shortcutKeyCodes: [54]
            )
        )
    }
}
