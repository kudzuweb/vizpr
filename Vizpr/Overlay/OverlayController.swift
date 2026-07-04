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
        render(.empty)
        panel.setFrame(layout.restingFrame, display: true)
        panel.orderFrontRegardless()
    }

    func apply(_ snapshot: DisplaySnapshot) {
        guard panel.isVisible, let layout else { return }
        render(snapshot)
        let target = layout.frame(contentHeight: contentHeight(for: snapshot))
        if target != panel.frame {
            panel.setFrame(target, display: true, animate: !reduceMotion)
        }
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
        if let layout { panel.setFrame(layout.restingFrame, display: true, animate: true) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func render(_ snapshot: DisplaySnapshot) {
        let view = OverlayView(snapshot: snapshot, recording: recording)
        if let hosting {
            hosting.rootView = view
        } else {
            let fresh = NSHostingView(rootView: view)
            hosting = fresh
            panel.contentView = fresh
        }
    }

    /// Measured text height at the reading width — drives OverlayLayout.
    /// (Text metrics, not hosting-view fitting: deterministic and cheap.)
    private func contentHeight(for snapshot: DisplaySnapshot) -> CGFloat {
        let text = snapshot.displayed
        guard !text.isEmpty else { return 0 }
        let width = OverlayLayout.readingWidth - 36
        let font = NSFont.systemFont(ofSize: 16, weight: .regular)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height) + 24
    }
}
