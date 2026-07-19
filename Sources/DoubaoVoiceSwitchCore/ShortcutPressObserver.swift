public struct ShortcutPressObserver: Sendable {
  private let shortcut: DoubaoShortcut
  private var activeKeys: Set<DoubaoShortcutKey> = []
  private var isShortcutPressed = false

  public init(shortcut: DoubaoShortcut) {
    self.shortcut = shortcut
  }

  public mutating func observe(
    key: DoubaoShortcutKey,
    activeModifiers: ShortcutModifiers,
    isFunctionActive: Bool
  ) -> Bool {
    guard shortcut.keys.contains(key) else {
      return false
    }

    updateActiveKeys(
      key: key,
      activeModifiers: activeModifiers,
      isFunctionActive: isFunctionActive
    )
    let matchesShortcut = shortcut.matches(activeKeys: activeKeys)
      && activeModifiers == shortcut.modifiers

    if matchesShortcut, !isShortcutPressed {
      isShortcutPressed = true
      return true
    }
    if !matchesShortcut {
      isShortcutPressed = false
    }
    return false
  }

  public mutating func reset() {
    activeKeys.removeAll()
    isShortcutPressed = false
  }

  private mutating func updateActiveKeys(
    key: DoubaoShortcutKey,
    activeModifiers: ShortcutModifiers,
    isFunctionActive: Bool
  ) {
    if key == .function {
      updateActiveKey(key, isActive: isFunctionActive)
    } else if activeKeys.contains(key) {
      activeKeys.remove(key)
    } else if let modifier = key.modifier, activeModifiers.contains(modifier) {
      activeKeys.insert(key)
    }
  }

  private mutating func updateActiveKey(_ key: DoubaoShortcutKey, isActive: Bool) {
    if isActive {
      activeKeys.insert(key)
    } else {
      activeKeys.remove(key)
    }
  }
}
