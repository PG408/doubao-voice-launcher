public enum ModifierKeyState {
    public static func staleKeyCodes(
        activeKeyCodes: Set<UInt16>,
        currentKeyCode: UInt16,
        activeFlagsRawValue: UInt64,
        flagRawValueForKeyCode: (UInt16) -> UInt64?
    ) -> Set<UInt16> {
        Set(activeKeyCodes.filter { keyCode in
            guard keyCode != currentKeyCode,
                  let flagRawValue = flagRawValueForKeyCode(keyCode) else {
                return false
            }
            return activeFlagsRawValue & flagRawValue == 0
        })
    }
}
