import XCTest
@testable import DoubaoVoiceLauncherCore

final class ModifierKeyStateTests: XCTestCase {
    private let commandFlag: UInt64 = 1 << 20
    private let optionFlag: UInt64 = 1 << 19

    func testFindsStaleNonCurrentModifierWhenFlagIsAbsent() {
        let staleKeyCodes = ModifierKeyState.staleKeyCodes(
            activeKeyCodes: [54, 61],
            currentKeyCode: 54,
            activeFlagsRawValue: commandFlag,
            flagRawValueForKeyCode: flagRawValue
        )

        XCTAssertEqual(staleKeyCodes, [61])
    }

    func testDoesNotMarkCurrentModifierAsStaleOnRelease() {
        let staleKeyCodes = ModifierKeyState.staleKeyCodes(
            activeKeyCodes: [54],
            currentKeyCode: 54,
            activeFlagsRawValue: 0,
            flagRawValueForKeyCode: flagRawValue
        )

        XCTAssertTrue(staleKeyCodes.isEmpty)
    }

    func testKeepsSameFlagSideSpecificModifiersWhenFlagIsStillPresent() {
        let staleKeyCodes = ModifierKeyState.staleKeyCodes(
            activeKeyCodes: [54, 55],
            currentKeyCode: 54,
            activeFlagsRawValue: commandFlag,
            flagRawValueForKeyCode: flagRawValue
        )

        XCTAssertTrue(staleKeyCodes.isEmpty)
    }

    private func flagRawValue(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 54, 55:
            return commandFlag
        case 58, 61:
            return optionFlag
        default:
            return nil
        }
    }
}
