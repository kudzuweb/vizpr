import AppKit
import SwiftUI

/// Owns the PreviewPanel lifecycle (§13): show on session start, live-update
/// from DisplaySnapshots, grow per OverlayLayout, dismiss ephemerally on
/// commit/cancel. Never activates anything — ordering uses
/// orderFrontRegardless on a non-activating panel.
@MainActor
final class OverlayController {
    private let panel = PreviewPanel()
    private var hosting: NSHostingView<OverlayView>?
    private var layout: OverlayLayout?
    private var recording = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func show() {
        // §13: the display holding the active app. NSScreen.main is the
        // screen with the key window — the field being dictated into.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let layout = OverlayLayout(screen: screen.visibleFrame)
        self.layout = layout
        recording = true
        panel.alphaValue = 1
        // The panel is a FIXED transparent stage spanning bottom edge to cap;
        // only the SwiftUI capsule inside animates (field catch: animating
        // the window frame lagged the text and clipped it mid-growth).
        panel.setFrame(layout.frame(contentHeight: layout.maxHeight), display: true)
        render(.empty)
        panel.orderFrontRegardless()
    }

    func apply(_ snapshot: DisplaySnapshot) {
        guard panel.isVisible else { return }
        render(snapshot)
    }

    /// Ephemeral dismissal (§13): clear → shrink → fade. Reduce Motion →
    /// instant.
    func dismiss() {
        recording = false
        guard panel.isVisible else { return }
        if reduceMotion {
            panel.orderOut(nil)
            return
        }
        render(.empty)   // capsule shrinks to resting inside the fixed stage
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func render(_ snapshot: DisplaySnapshot) {
        let view = OverlayView(
            snapshot: snapshot,
            recording: recording,
            capsuleHeight: capsuleHeight(for: snapshot),
            animated: !reduceMotion
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let fresh = NSHostingView(rootView: view)
            hosting = fresh
            panel.contentView = fresh
        }
    }

    /// Measured text height at the reading width, clamped to layout bounds.
    /// Measures with the ROUNDED design the view renders in — measuring with
    /// the plain system font undersized the capsule and clipped text (field
    /// catch).
    private func capsuleHeight(for snapshot: DisplaySnapshot) -> CGFloat {
        guard let layout else { return OverlayLayout.restingSize.height }
        let text = snapshot.displayed
        guard !text.isEmpty else { return OverlayLayout.restingSize.height }
        let width = OverlayLayout.readingWidth - 36
        let base = NSFont.systemFont(ofSize: 16, weight: .regular)
        let font = base.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 16) } ?? base
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        // Extra line of headroom: growth leads the text instead of trailing
        // it, so a wrapping word never renders against the clipped edge.
        let measured = ceil(bounds.height) + 24 + ceil(font.ascender - font.descender)
        return min(max(measured, OverlayLayout.restingSize.height), layout.maxHeight)
    }
}
