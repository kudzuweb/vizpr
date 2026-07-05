import CoreGraphics

/// Pure §13 geometry: fixed lower-center, growth in height only — upward from
/// a fixed bottom edge — capped at the middle 50% of the screen, with
/// tail-scroll past the cap. All decisions are functions of (screen, content
/// height), so the growth → cap → tail-scroll acceptance runs against
/// scripted sequences with no window involved.
struct OverlayLayout: Sendable, Equatable {
    /// Visible frame of the display holding the active app.
    let screen: CGRect

    /// Fixed reading width (§13: grow in height, not width).
    static let readingWidth: CGFloat = 560
    /// Resting capsule shown on activation before text arrives.
    static let restingSize = CGSize(width: 220, height: 44)

    /// The fixed bottom edge: ~25% of screen height up from the bottom.
    var bottomEdgeY: CGFloat { screen.minY + screen.height * 0.25 }
    /// Cap: top edge stops 25% inset from the top → max height 50% of screen.
    var maxHeight: CGFloat { screen.height * 0.50 }

    /// Panel frame for a given measured content height. The bottom edge never
    /// moves; only the top edge rises (newest words stay at the bottom).
    func frame(contentHeight: CGFloat) -> CGRect {
        let height = min(max(contentHeight, Self.restingSize.height), maxHeight)
        let width = contentHeight <= Self.restingSize.height
            ? Self.restingSize.width : Self.readingWidth
        return CGRect(
            x: screen.midX - width / 2,
            y: bottomEdgeY,
            width: width,
            height: height
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
