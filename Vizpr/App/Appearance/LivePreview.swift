import SwiftUI

/// The real overlay, rendered with the active look over a gray checkerboard so
/// transparency reads, with sample text typing itself. The typing runs in a
/// `.task`, so it stops when the pane leaves the screen or the Settings
/// window closes.
struct LivePreview: View {
    let look: OverlayLook

    @StateObject private var transcript = PreviewTranscript()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 180
    /// Room around the pane for its glow and shadow.
    private static let bleed: CGFloat = 48
    private static let capsuleHeight: CGFloat = 130

    var body: some View {
        GeometryReader { proxy in
            let stageWidth = look.style.pane.width + Self.bleed
            let scale = min(1, proxy.size.width / stageWidth)
            OverlayView(
                snapshot: transcript.snapshot,
                recording: true,
                capsuleHeight: Self.capsuleHeight,
                animated: !reduceMotion,
                look: look
            )
            .frame(width: stageWidth, height: Self.height)
            .scaleEffect(scale)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.height)
        .background(Checkerboard())
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .task { await transcript.run() }
        .accessibilityHidden(true)
    }
}

/// A mid-gray checkerboard.
private struct Checkerboard: View {
    private let cell: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.5)))
            let light = Color(white: 0.58)
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(light))
                }
            }
        }
    }
}
