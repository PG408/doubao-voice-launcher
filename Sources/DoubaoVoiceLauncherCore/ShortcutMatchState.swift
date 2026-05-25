public enum ShortcutMatchState {
    public static func isPressed(
        changedKeyCode: UInt16,
        activeModifierKeyCodes: Set<UInt16>,
        shortcutKeyCodes: Set<UInt16>
    ) -> Bool {
        shortcutKeyCodes.contains(changedKeyCode)
            && activeModifierKeyCodes.intersection(shortcutKeyCodes) == shortcutKeyCodes
    }

    public static func isReleased(
        changedKeyCode: UInt16,
        activeModifierKeyCodes: Set<UInt16>,
        shortcutKeyCodes: Set<UInt16>
    ) -> Bool {
        shortcutKeyCodes.contains(changedKeyCode)
            && activeModifierKeyCodes.intersection(shortcutKeyCodes) != shortcutKeyCodes
    }
}
