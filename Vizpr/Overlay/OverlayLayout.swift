import CoreGraphics

/// Where the user dragged the pane's bottom-center to, as fractions (0...1) of
/// a display's visible frame, so the spot survives resolution changes.
struct OverlayAnchor: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    /// Today's fixed placement: horizontally centered, 25% up from the bottom.
    static let `default` = OverlayAnchor(x: 0.5, y: 0.25)

    func clamped() -> OverlayAnchor {
        OverlayAnchor(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// Pure §13 geometry: lower-center by default or at the user's anchor, growth
/// in height only — upward from a fixed bottom edge — capped at the middle 50%
/// of the screen (less when the anchor is high), with tail-scroll past the
/// cap. All decisions are functions of (screen, anchor, content height), so the
/// growth → cap → tail-scroll acceptance runs against scripted sequences with
/// no window involved.
struct OverlayLayout: Sendable, Equatable {
    /// Visible frame of the display holding the active app.
    let screen: CGRect
    /// The pane's bottom-center; nil is the default lower-center.
    var anchor: OverlayAnchor?

    /// Default reading width (§13: grow in height, not width); a look sets its own in `PaneShape.width`.
    static let readingWidth: CGFloat = 560
    /// Resting capsule shown on activation before text arrives.
    static let restingSize = CGSize(width: 220, height: 44)

    /// Gap kept between the pane's top edge and the top of the screen.
    static let topInset: CGFloat = 12

    private var effectiveAnchor: OverlayAnchor { anchor?.clamped() ?? .default }

    /// The fixed bottom edge: ~25% of screen height up from the bottom by default.
    var bottomEdgeY: CGFloat { screen.minY + screen.height * effectiveAnchor.y }
    /// The fixed horizontal center: the screen's center by default.
    var centerX: CGFloat { screen.minX + screen.width * effectiveAnchor.x }
    /// Cap: at most 50% of the screen, and never past the top of the screen
    /// (so a high anchor shrinks the cap instead of pushing the pane off).
    var maxHeight: CGFloat {
        min(screen.height * 0.50, max(screen.maxY - bottomEdgeY - Self.topInset, Self.restingSize.height))
    }

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
        let paneX = min(max(centerX - width / 2, screen.minX), max(screen.maxX - width, screen.minX))
        return CGRect(
            x: paneX - margin,
            y: bottomEdgeY - margin,
            width: width + 2 * margin,
            height: height + 2 * margin
        )
    }

    /// The anchor for a pane dragged to `paneFrame`: the frame is first moved
    /// the least distance that keeps it fully on the screen, then its
    /// bottom-center becomes fractions of the screen.
    func anchor(forPaneFrame paneFrame: CGRect) -> OverlayAnchor {
        let x = min(max(paneFrame.minX, screen.minX), max(screen.maxX - paneFrame.width, screen.minX))
        let y = min(max(paneFrame.minY, screen.minY), max(screen.maxY - paneFrame.height, screen.minY))
        return OverlayAnchor(
            x: (x + paneFrame.width / 2 - screen.minX) / screen.width,
            y: (y - screen.minY) / screen.height
        ).clamped()
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
