import SwiftUI

/// The §13 transcript view: settled text in the primary label color, mutable
/// (live + draft) in SECONDARY — the color IS the trust contract (NOTES,
/// Mauria 2026-07-04): anything secondary can still change; anything primary
/// is guaranteed immutable. Text never changes after it reads as final.
///
/// Bottom-anchored: newest words sit at the fixed bottom edge; past the
/// height cap the oldest lines clip off the top (tail-following scroll) —
/// the same anchoring before and after the cap makes the transition seamless.
struct OverlayView: View {
    let snapshot: DisplaySnapshot
    let recording: Bool
    /// Capsule height, measured by the controller. The PANEL never animates —
    /// it is a fixed transparent stage; the capsule animates here in SwiftUI
    /// so glass, text, and size move as one (field catch: AppKit frame
    /// animation lagged the instantly-rendered text — jerky, and text clipped
    /// at the edge mid-growth).
    let capsuleHeight: CGFloat
    /// False under Reduce Motion — the capsule snaps instead of animating.
    let animated: Bool

    private static let capsuleShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        let resting = snapshot == .empty
        // Bottom-aligned within the fixed panel: the capsule's TOP edge rises.
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                GlassBackground()
                ScrollView(.vertical) {
                    // WYSIWYG: render EXACTLY the decomposition of
                    // snapshot.displayed — the bytes commit injects. Never a
                    // reconstruction with synthetic joiners (review finding:
                    // the user proofread a string with one more space than
                    // the injection).
                    (
                        Text(snapshot.settled).foregroundStyle(.primary)
                        + Text(snapshot.mutableSuffix).foregroundStyle(.secondary)
                    )
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                // Tail-follow must re-pin on BOTH initial layout and every
                // size change, or one settled-off-anchor frame sticks forever
                // (the panel ignores the mouse, so nothing could recover).
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                // Clip scrolled text to the capsule, not the rect — square
                // glyph fragments rendered over the corner curves otherwise.
                .clipShape(Self.capsuleShape)

                if recording {
                    Circle()
                        .fill(GlassBackground.tint)
                        .frame(width: 7, height: 7)
                        .padding(10)
                        .accessibilityLabel("Recording")
                }
            }
            .frame(
                width: resting ? OverlayLayout.restingSize.width : OverlayLayout.readingWidth,
                height: capsuleHeight
            )
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: capsuleHeight)
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: resting)
        }
        .frame(maxWidth: .infinity)
    }
}
