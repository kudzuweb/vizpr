import CoreGraphics

/// One keyboard event as the trigger logic sees it: a plain value with no
/// CoreGraphics objects, so the tracker and the per-event router are testable
/// with synthetic sequences. The event's own timestamp travels separately, as
/// the `MonotonicTime` handed to `HotkeyEventRouter.route`.
struct HotkeyKeyEvent: Equatable, Sendable {
    enum Kind: Sendable {
        case flagsChanged, keyDown, keyUp
    }

    let kind: Kind
    let keyCode: UInt16
    /// The raw flags, including the per-side device bits.
    let flags: CGEventFlags
    /// True for a repeat of a key-down (`kCGKeyboardEventAutorepeat`).
    let isAutorepeat: Bool

    init(kind: Kind, keyCode: UInt16, flags: CGEventFlags, isAutorepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isAutorepeat = isAutorepeat
    }
}
