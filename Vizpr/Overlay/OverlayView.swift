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
    var theme: OverlayTheme = .standard
    /// Inviz mode: render the minimal indicator instead of the transcript.
    var inviz: Bool = false

    /// Trust-contract styles: system labels by default; a custom base keeps
    /// the LOCKED settled:mutable opacity ratio (only the hue is the user's).
    private var settledStyle: AnyShapeStyle {
        theme.textBase.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)
    }
    private var mutableStyle: AnyShapeStyle {
        theme.textBase.map {
            AnyShapeStyle($0.opacity(VizprSettings.mutableOpacityRatio))
        } ?? AnyShapeStyle(.secondary)
    }

    private static let capsuleShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        if inviz {
            indicator
        } else {
            transcript
        }
    }

    /// The inviz-mode "talking is happening" pill: mid-stage, theme-tinted,
    /// pulsing while recording. No text — that's the point.
    private var indicator: some View {
        VStack {
            Spacer(minLength: 0)
            ZStack {
                GlassBackground(theme: theme)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(theme.tint)
                            .frame(width: 8, height: 8)
                            .opacity(recording ? 1 : 0.3)
                            .scaleEffect(recording ? 1 : 0.7)
                            .animation(
                                animated && recording
                                    ? .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2)
                                    : .default,
                                value: recording
                            )
                    }
                }
                .accessibilityLabel(recording ? "Dictating" : "Idle")
            }
            .frame(width: 84, height: 36)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var transcript: some View {
        let resting = snapshot == .empty
        // Bottom-aligned within the fixed panel: the capsule's TOP edge rises.
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                GlassBackground(theme: theme)
                ScrollView(.vertical) {
                    // WYSIWYG: render EXACTLY the decomposition of
                    // snapshot.displayed — the bytes commit injects. Never a
                    // reconstruction with synthetic joiners (review finding:
                    // the user proofread a string with one more space than
                    // the injection).
                    (
                        Text(snapshot.settled).foregroundStyle(settledStyle)
                        + Text(snapshot.mutableSuffix).foregroundStyle(mutableStyle)
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
                        .fill(theme.tint)
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
