import CoreGraphics

/// Pure §13 geometry: fixed lower-center, growth in height only — upward from
/// a fixed bottom edge — capped at the middle 50% of the screen, with
/// tail-scroll past the cap. All decisions are functions of (screen, content
/// height), so the growth → cap → tail-scroll acceptance runs against
/// scripted sequences with no window involved.
struct OverlayLayout: Sendable, Equatable {
    /// Visible frame of the display holding the active app.
    let screen: CGRect

    /// Default reading width (§13: grow in height, not width); a look sets its own in `PaneShape.width`.
    static let readingWidth: CGFloat = 560
    /// Resting capsule shown on activation before text arrives.
    static let restingSize = CGSize(width: 220, height: 44)

    /// The fixed bottom edge: ~25% of screen height up from the bottom.
    var bottomEdgeY: CGFloat { screen.minY + screen.height * 0.25 }
    /// Cap: top edge stops 25% inset from the top → max height 50% of screen.
    var maxHeight: CGFloat { screen.height * 0.50 }

    /// Panel frame for a given measured content height. The pane's bottom edge
    /// never moves; only the top edge rises (newest words stay at the bottom).
    /// `margin` is extra room on every side for effects that draw beyond the
    /// pane (glow, shadow): the panel grows around the pane, so the pane's
    /// frame inside it is the same with or without a margin.
    func frame(
        contentHeight: CGFloat,
        paneWidth: CGFloat = Self.readingWidth,
        margin: CGFloat = 0
    ) -> CGRect {
        let height = min(max(contentHeight, Self.restingSize.height), maxHeight)
        let width = contentHeight <= Self.restingSize.height ? Self.restingSize.width : paneWidth
        return CGRect(
            x: screen.midX - width / 2 - margin,
            y: bottomEdgeY - margin,
            width: width + 2 * margin,
            height: height + 2 * margin
        )
    }

    /// Past the cap the frame stops growing and the text tail-follows
    /// (newest pinned in view, oldest clips off the top).
    func scrollsTail(contentHeight: CGFloat) -> Bool {
        contentHeight > maxHeight
    }

    var restingFrame: CGRect { frame(contentHeight: 0) }

    /// Pick the screen holding the dictation target (§13 multi-display,
    /// PR 10): convert the AX window frame (top-left origin, primary-relative)
    /// to Cocoa coordinates and choose the screen containing its center.
    /// Pure so it's table-testable; nil axFrame → nil (caller falls back).
    static func targetScreenFrame(
        axFrame: CGRect?,
        screenFrames: [CGRect],
        primaryHeight: CGFloat
    ) -> CGRect? {
        guard let axFrame, !screenFrames.isEmpty else { return nil }
        let center = CGPoint(
            x: axFrame.midX,
            y: primaryHeight - axFrame.midY   // flip AX top-left to Cocoa
        )
        return screenFrames.first { $0.contains(center) }
    }
}
