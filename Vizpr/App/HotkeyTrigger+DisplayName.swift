import Carbon.HIToolbox

/// How a trigger reads in the Behavior pane. Main thread only: the character for
/// a key comes from the current keyboard layout, a Text Input Source call, so
/// the hotkey thread never builds a display name.
extension HotkeyTrigger {
    @MainActor
    var displayName: String {
        let prefix = Self.modifierSymbols(modifiers)
        if isFn { return "Fn" }
        if let key = sidedKey {
            let side = Self.leftKeyCodes.contains(keyCode) ? "Left" : "Right"
            let symbol = Self.modifierSymbols([key.family])
            return (prefix.isEmpty ? "" : prefix + " ") + "\(side) \(symbol)"
        }
        return prefix + Self.keyName(keyCode)
    }

    private static let leftKeyCodes: Set<UInt16> = [55, 56, 58, 59]

    /// In the order macOS writes them in menus: control, option, shift, command.
    private static func modifierSymbols(_ families: [String]) -> String {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
            .filter { families.contains($0.0) }
            .map(\.1)
            .joined()
    }

    private static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Home): "Home", UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]

    @MainActor
    private static func keyName(_ keyCode: UInt16) -> String {
        namedKeys[keyCode] ?? layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
    }

    /// The character the current keyboard layout produces for the key, upper-cased.
    @MainActor
    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
