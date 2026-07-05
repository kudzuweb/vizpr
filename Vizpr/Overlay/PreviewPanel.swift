import AppKit

/// The overlay window (§13): a non-activating panel that must NEVER steal
/// focus from the field being dictated into — the one functional
/// non-negotiable, since injection targets the focused field. Display-only:
/// it also ignores mouse events entirely.
final class PreviewPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The panel is a transparent stage; AppKit's window shadow would
        // stale-halo the old capsule bounds mid-growth (review finding). The
        // capsule carries its own depth via the glass material.
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        // Never participate in window restoration or cycling.
        isRestorable = false
        animationBehavior = .none
    }

    // The focus invariant, enforced at the AppKit level: this window can
    // never become key or main no matter what a future content view asks.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
