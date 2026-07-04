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

    private var mutableText: String {
        let joined = [snapshot.live, snapshot.draft]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Visual seam only — the injected string comes from commit(), never
        // from this rendering.
        return snapshot.settled.isEmpty || joined.isEmpty ? joined : " " + joined
    }

    var body: some View {
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
                // Bottom-anchored growth: content pins to the bottom; when it
                // exceeds the cap the top clips (tail-follow).
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
    }
}
