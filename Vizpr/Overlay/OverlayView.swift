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

    private var mutableText: String {
        let joined = [snapshot.live, snapshot.draft]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Visual seam only — the injected string comes from commit(), never
        // from this rendering.
        return snapshot.settled.isEmpty || joined.isEmpty ? joined : " " + joined
    }

    var body: some View {
        // Bottom-aligned within the fixed panel: the capsule's TOP edge rises.
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                GlassBackground()
                ScrollView(.vertical) {
                    (
                        Text(snapshot.settled).foregroundStyle(.primary)
                        + Text(mutableText).foregroundStyle(.secondary)
                    )
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    // Bottom-anchored growth: content pins to the bottom;
                    // past the cap the top clips (tail-follow).
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)

                if recording {
                    Circle()
                        .fill(GlassBackground.tint)
                        .frame(width: 7, height: 7)
                        .padding(10)
                        .accessibilityLabel("Recording")
                }
            }
            .frame(height: capsuleHeight)
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: capsuleHeight)
        }
    }
}
