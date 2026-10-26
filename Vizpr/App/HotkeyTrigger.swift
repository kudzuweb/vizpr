import CoreGraphics

/// The key that starts and stops dictation: one physical key, named by its
/// virtual keycode, plus the modifier families (control, option, shift,
/// command) that must be held when it goes down. Fn is keycode 63 with no
/// modifiers and is the default.
///
/// A key in `modifierKeys` (or Fn) is a modifier-key trigger and is tracked on
/// `flagsChanged`; any other keycode is a regular-key trigger and is tracked on
/// `keyDown` and `keyUp`.
struct HotkeyTrigger: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: [String]

    init(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let fn = HotkeyTrigger(keyCode: 63, modifiers: [])

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    /// Any type or range failure yields Fn instead of throwing, so no trigger
    /// value can make the whole settings file undecodable (a decode failure
    /// replaces every setting with defaults).
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let keyCode = try? container.decode(UInt16.self, forKey: .keyCode),
              let modifiers = try? container.decode([String].self, forKey: .modifiers)
        else {
            self = .fn
            return
        }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - Keys

extension HotkeyTrigger {
    static let fnKeyCode: UInt16 = 63
    static let capsLockKeyCode: UInt16 = 57
    static let escapeKeyCode: UInt16 = 53
    /// Carbon virtual keycodes the recorder and `clamped` accept.
    static let keyCodeRange = 0...127

    /// A sided modifier key: the family it belongs to and its own bit in the
    /// event flags (`NX_DEVICE*KEYMASK`, IOLLEvent.h). Fn has no device bit.
    struct ModifierKey: Sendable {
        let family: String
        let deviceBit: UInt64
    }

    static let modifierKeys: [UInt16: ModifierKey] = [
        54: ModifierKey(family: "command", deviceBit: 0x10),    // right command
        55: ModifierKey(family: "command", deviceBit: 0x08),    // left command
        56: ModifierKey(family: "shift", deviceBit: 0x02),      // left shift
        60: ModifierKey(family: "shift", deviceBit: 0x04),      // right shift
        58: ModifierKey(family: "option", deviceBit: 0x20),     // left option
        61: ModifierKey(family: "option", deviceBit: 0x40),     // right option
        59: ModifierKey(family: "control", deviceBit: 0x01),    // left control
        62: ModifierKey(family: "control", deviceBit: 0x2000)   // right control
    ]

    /// The four modifier families and the flag each one sets.
    static let familyFlags: [String: CGEventFlags] = [
        "control": .maskControl,
        "option": .maskAlternate,
        "shift": .maskShift,
        "command": .maskCommand
    ]

    static let allFamilyFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// The combined flag for a list of family names; unknown names add nothing.
    static func mask(forFamilies names: [String]) -> CGEventFlags {
        names.reduce(into: CGEventFlags()) { mask, name in
            if let flag = familyFlags[name] { mask.insert(flag) }
        }
    }

    /// Fn cannot be combined with another key: it is detected by its flag, which
    /// arrow and function keys also set.
    static let fnAloneReason = "Fn can't be combined with other keys."

    var isFn: Bool { keyCode == Self.fnKeyCode }

    /// Non-nil for a sided modifier key such as Right Option.
    var sidedKey: ModifierKey? { Self.modifierKeys[keyCode] }

    var isModifierKey: Bool { isFn || sidedKey != nil }

    /// The families that must be held, as flags.
    var modifierMask: CGEventFlags { Self.mask(forFamilies: modifiers) }
}

// MARK: - Validity

extension HotkeyTrigger {
    /// Sorted and deduplicated, because array equality is ordered and
    /// `VizprSettings.clamped() == self` must hold for a valid value.
    func normalized() -> HotkeyTrigger {
        HotkeyTrigger(keyCode: keyCode, modifiers: Array(Set(modifiers)).sorted())
    }

    /// Why this trigger cannot be used, or nil when it can. The recorder shows
    /// the reason; `clamped` resets any refused trigger to Fn.
    func refusal(secondaryModifiers: [String]) -> String? {
        if !Self.keyCodeRange.contains(Int(keyCode)) {
            return "That key can't be used as a trigger."
        }
        if keyCode == Self.capsLockKeyCode {
            return "Caps Lock toggles instead of being pressed, so it can't be the trigger."
        }
        if keyCode == Self.escapeKeyCode {
            return "Esc cancels dictation, so it can't be the trigger."
        }
        if modifiers.contains(where: { Self.familyFlags[$0] == nil }) {
            return "That modifier isn't one Vizpr recognizes."
        }
        if isFn, !modifiers.isEmpty {
            return Self.fnAloneReason
        }
        if let family = sidedKey?.family, modifiers.contains(family) {
            return "The trigger key already is that modifier."
        }
        if !secondaryModifiers.isEmpty, Set(secondaryModifiers).isSubset(of: modifiers) {
            return "That combination is the chord that also starts dictation, so it could never fire."
        }
        return nil
    }

    /// This trigger when valid, otherwise Fn.
    func clamped(secondaryModifiers: [String]) -> HotkeyTrigger {
        let candidate = normalized()
        return candidate.refusal(secondaryModifiers: secondaryModifiers) == nil ? candidate : .fn
    }
}
