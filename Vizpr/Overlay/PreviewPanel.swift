import AppKit

/// The overlay window (§13): a non-activating panel that must NEVER steal
/// focus from the field being dictated into — the one functional
/// non-negotiable, since injection targets the focused field. It takes mouse
/// events so the pane can be dragged out of the way (Mauria, 2026-10-21), which
/// means a click on the pane no longer reaches the app behind it.
final class PreviewPanel: NSPanel {
    /// Called with the panel's new frame when a drag that moved it ends.
    var onDragEnd: ((CGRect) -> Void)?

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
        hidesOnDeactivate = false
        isMovable = true
        // Never participate in window restoration or cycling.
        isRestorable = false
        animationBehavior = .none
    }

    /// Runs the system window drag for a mouse-down (it returns when the
    /// button is released) and reports where the panel ended up.
    func drag(with event: NSEvent) {
        let start = frame
        performDrag(with: event)
        if frame != start { onDragEnd?(frame) }
    }

    // The focus invariant, enforced at the AppKit level: this window can
    // never become key or main no matter what a future content view asks.
    // Click-through was dropped on purpose (Mauria, 2026-10-21) so the pane
    // can be dragged; focus is still never taken, and `.nonactivatingPanel`
    // keeps a click from activating Vizpr.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
