import AppKit
import SwiftUI

/// Owns the PreviewPanel lifecycle (§13): show on session start, live-update
/// from DisplaySnapshots, grow per OverlayLayout, dismiss ephemerally on
/// commit/cancel. Never activates anything — ordering uses
/// orderFrontRegardless on a non-activating panel.
@MainActor
final class OverlayController {
    private let panel = PreviewPanel()
    private var hosting: DragHostingView<OverlayView>?
    /// The screen the pane sits on: its visible frame and stable display id.
    private var placement: (visibleFrame: CGRect, displayID: String?)?
    private var anchors: [String: OverlayAnchor] = [:]
    /// Called with the display id and the new anchor when a drag ends.
    var onAnchorChange: ((String, OverlayAnchor) -> Void)?
    private var layout: OverlayLayout? {
        placement.map { OverlayLayout(screen: $0.visibleFrame, anchor: $0.displayID.flatMap { anchors[$0] }) }
    }
    private var recording = false
    /// Once the capsule caps, stop measuring: the O(session-length)
    /// boundingRect result is clamped anyway (review finding).
    private var hitCap = false
    private var look = OverlayLook.glass
    private var lastSnapshot = DisplaySnapshot.empty

    private var inviz = false

    init() {
        panel.onDragEnd = { [weak self] frame in self?.dragEnded(panelFrame: frame) }
    }

    /// Live setting: the saved positions per display. Takes effect on the
    /// next placement (`setLook` runs with every settings change and places
    /// the panel again).
    func setAnchors(_ newAnchors: [String: OverlayAnchor]) {
        anchors = newAnchors
    }

    /// Live setting (PR 11): inviz mode swaps the transcript for the
    /// indicator; applies to the next render.
    func setInviz(_ enabled: Bool) {
        inviz = enabled
        if panel.isVisible { render(lastSnapshot) }
    }

    /// Live setting (PR 11): re-renders immediately so the picker previews.
    func setLook(_ newLook: OverlayLook) {
        look = newLook
        // Font size and design change the measured height.
        hitCap = false
        if panel.isVisible {
            // Glow, shadow and width change how much room the panel needs.
            positionPanel()
            render(lastSnapshot)
        }
    }

    /// The panel spans the pane's fixed bottom edge to the cap, plus the look's
    /// effect margin on every side; only the SwiftUI capsule inside animates.
    private func positionPanel() {
        guard let layout else { return }
        panel.setFrame(
            layout.frame(
                contentHeight: layout.maxHeight,
                paneWidth: look.style.pane.width,
                margin: PaneEffects.margin(for: look.style)
            ),
            display: true
        )
    }

    /// A drag moved the panel: the pane's bottom-center, on whichever screen
    /// it now sits, becomes that display's anchor. The pane then grows from
    /// that point.
    private func dragEnded(panelFrame: CGRect) {
        let margin = PaneEffects.margin(for: look.style)
        let paneFrame = CGRect(
            x: panelFrame.minX + margin,
            y: panelFrame.minY + margin,
            width: panelFrame.width - 2 * margin,
            height: OverlayLayout.restingSize.height
        )
        let screens = NSScreen.screens
        let landed = screens.first { $0.frame.contains(CGPoint(x: paneFrame.midX, y: paneFrame.midY)) }
        guard let screen = landed ?? screens.first(where: { $0.visibleFrame == placement?.visibleFrame }) else {
            return
        }
        let displayID = screen.displayUUID
        placement = (screen.visibleFrame, displayID)
        guard let displayID, let layout else { positionPanel(); return }
        let anchor = layout.anchor(forPaneFrame: paneFrame)
        anchors[displayID] = anchor
        // The cap depends on the anchor, so the height is measured again.
        hitCap = false
        positionPanel()
        render(lastSnapshot)
        onAnchorChange?(displayID, anchor)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func show(targetWindowFrame: CGRect? = nil) {
        // §13: the display holding the dictation target. The AX focused-
        // window frame (PR 10) decides; fall back to NSScreen.main (wrong
        // for an LSUIElement app on multi-display, correct on one screen).
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let targetFrame = OverlayLayout.targetScreenFrame(
            axFrame: targetWindowFrame,
            screenFrames: screens.map(\.frame),
            primaryHeight: primaryHeight
        )
        let screen = screens.first { $0.frame == targetFrame }
            ?? NSScreen.main ?? screens.first
        guard let screen else { return }
        placement = (screen.visibleFrame, screen.displayUUID)
        recording = true
        hitCap = false
        panel.alphaValue = 1
        // The panel is a FIXED transparent stage spanning bottom edge to cap;
        // only the SwiftUI capsule inside animates (field catch: animating
        // the window frame lagged the text and clipped it mid-growth).
        positionPanel()
        render(.empty)
        panel.orderFrontRegardless()
    }

    func apply(_ snapshot: DisplaySnapshot) {
        // `recording`, not `isVisible`: post-commit straggler snapshots must
        // not repaint text over an in-flight dismissal (review finding).
        guard recording, panel.isVisible else { return }
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
        }, completionHandler: { [weak self] in
            // A rapid re-dictation can start during the fade; hiding the
            // panel then would blank the NEW session's overlay entirely
            // (review finding — apply() drops snapshots while hidden).
            guard let self, !self.recording else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    private func render(_ snapshot: DisplaySnapshot) {
        lastSnapshot = snapshot
        let view = OverlayView(
            snapshot: snapshot,
            recording: recording,
            capsuleHeight: capsuleHeight(for: snapshot),
            animated: !reduceMotion,
            look: look,
            inviz: inviz
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let fresh = DragHostingView(rootView: view)
            hosting = fresh
            panel.contentView = fresh
        }
    }

    /// Measured text height at the reading width, clamped to layout bounds.
    /// Measures with the look's own font (`measuringFont`, the twin of the
    /// view's): measuring with any other font undersizes the capsule and
    /// clips text (field catch).
    private func capsuleHeight(for snapshot: DisplaySnapshot) -> CGFloat {
        guard let layout else { return OverlayLayout.restingSize.height }
        if hitCap { return layout.maxHeight }
        let text = snapshot.displayed
        guard !text.isEmpty else { return OverlayLayout.restingSize.height }
        let measured = look.paneHeight(fitting: text)
        let clamped = min(max(measured, OverlayLayout.restingSize.height), layout.maxHeight)
        if clamped >= layout.maxHeight { hitCap = true }
        return clamped
    }
}
