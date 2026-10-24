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
    /// Capsule size, measured by the controller. The PANEL never animates —
    /// it is a fixed transparent stage; the capsule animates here in SwiftUI
    /// so glass, text, and size move as one (field catch: AppKit frame
    /// animation lagged the instantly-rendered text — jerky, and text clipped
    /// at the edge mid-growth).
    let capsuleHeight: CGFloat
    /// Capsule width, measured by the controller so it grows with the text.
    /// Nil keeps the fixed widths: resting size, then the look's pane width.
    var capsuleWidth: CGFloat?
    /// False under Reduce Motion — the capsule snaps instead of animating.
    let animated: Bool
    var look: OverlayLook = .glass
    /// Inviz mode: render the minimal indicator instead of the transcript.
    var inviz: Bool = false
    /// The app the text will land in, and how much of it to show.
    var targetApp: TargetApp?
    var targetAppDisplay: TargetAppDisplay = .off

    private var app: TargetApp.Info? { targetApp?.current }

    private var capsuleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
    }

    var body: some View {
        if inviz {
            indicator
        } else {
            transcript
        }
    }

    /// The inviz-mode "talking is happening" pill: mid-stage, look-tinted,
    /// pulsing while recording. No text — that's the point.
    private var indicator: some View {
        VStack {
            Spacer(minLength: 0)
            ZStack {
                PaneSurface(look: look, animated: animated)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(look.tintColor)
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
            .targetAppBeside(app, display: targetAppDisplay, look: look)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, stageInset)
        .padding(look.panelMargin)
    }

    /// Room each side of the pane for the indicator beside the inviz pill.
    private var stageInset: CGFloat { TargetAppMetrics.sideInset(for: targetAppDisplay, inviz: inviz) }

    /// Whether the icon is shown on the resting or expanded pill's corner.
    private var showingTarget: Bool { targetAppDisplay != .off && app != nil }

    @ViewBuilder private var transcript: some View {
        let resting = snapshot == .empty
        let fixedWidth: CGFloat = resting ? OverlayLayout.restingSize.width : look.style.pane.width
        let paneWidth = capsuleWidth ?? fixedWidth
        let paneSize = CGSize(width: paneWidth, height: capsuleHeight)
        // Bottom-aligned within the fixed panel: the capsule's TOP edge rises.
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                PaneSurface(look: look, animated: animated)
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        // WYSIWYG: render EXACTLY the decomposition of
                        // snapshot.displayed — the bytes commit injects. Never a
                        // reconstruction with synthetic joiners (review finding:
                        // the user proofread a string with one more space than
                        // the injection).
                        (
                            Text(snapshot.settled).foregroundStyle(look.settledStyle)
                            + Text(snapshot.mutableSuffix).foregroundStyle(look.mutableStyle)
                        )
                        .font(look.font)
                        .lineSpacing(look.style.text.lineSpacing)
                        .textGlow(look.style.text)
                        // The text lays out at the final width and the animated
                        // capsule reveals it, so it never re-wraps mid-growth.
                        .frame(width: look.textWidth(inPaneWidth: paneWidth), alignment: .leading)
                        .transaction { $0.animation = nil }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, look.style.pane.paddingHorizontal)
                        .padding(.vertical, look.style.pane.paddingVertical)
                    }
                    .scrollIndicators(.hidden)
                    // Tail-follow must re-pin on BOTH initial layout and every
                    // size change, or one settled-off-anchor frame sticks forever
                    // (the panel ignores the mouse, so nothing could recover).
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    // Clip scrolled text to the capsule, not the rect — square
                    // glyph fragments rendered over the corner curves otherwise.
                    .clipShape(capsuleShape)
                }

                if resting, targetAppDisplay == .iconAndName, let app {
                    TargetAppName(name: app.name, look: look)
                        .opacity(TargetAppMetrics.opacity)
                        .accessibilityHidden(true)
                        .padding(.leading, TargetAppMetrics.nameLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }

                if recording {
                    RecordingDot(style: look.style.dot, tint: look.tintColor, animated: animated)
                        .padding(10)
                        .accessibilityLabel("Recording")
                }
            }
            .frame(width: paneSize.width, height: paneSize.height)
            // Hangs off the corner, outside the clip, so it does not change the pane's size.
            .overlay(alignment: .topLeading) {
                if let app, showingTarget {
                    cornerBadge(app)
                }
            }
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: paneSize)
            .animation(animated ? .easeOut(duration: 0.15) : nil, value: resting)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, stageInset)
        .padding(look.panelMargin)
    }

    /// The app icon centered on the pane's top-left corner arc, so about half
    /// of it hangs outside. The expanded pane shows the icon only.
    private func cornerBadge(_ app: TargetApp.Info) -> some View {
        let inset = TargetAppMetrics.iconCenterInset
        let offset = inset - TargetAppMetrics.paneIconSize / 2
        return TargetAppBadge(app: app, display: .icon, iconSize: TargetAppMetrics.paneIconSize, look: look)
            .fixedSize()
            .offset(x: offset, y: offset)
    }
}

/// The recording indicator: the look's dot color (the tint when unset) and
/// size, with an optional gentle opacity pulse that Reduce Motion turns off.
struct RecordingDot: View {
    let style: DotStyle
    let tint: Color
    let animated: Bool

    private static let pulseSeconds = 1.6
    private static let dimmestOpacity = 0.35

    var body: some View {
        TimelineView(.animation(paused: !(style.pulse && animated))) { timeline in
            Circle()
                .fill(style.colorHex.flatMap { Color(hex: $0) } ?? tint)
                .frame(width: style.size, height: style.size)
                .opacity(style.pulse && animated ? Self.opacity(at: timeline.date) : 1)
        }
    }

    /// Eases between full opacity and `dimmestOpacity` once per `pulseSeconds`.
    static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate / pulseSeconds * 2 * Double.pi
        let wave = (1 + cos(phase)) / 2
        return dimmestOpacity + (1 - dimmestOpacity) * wave
    }
}

private extension View {
    /// Soft glow around the transcript text, when the look enables it.
    @ViewBuilder func textGlow(_ text: TextStyle) -> some View {
        if text.glowEnabled {
            shadow(color: Color(hex: text.glowColorHex) ?? .white, radius: text.glowRadius)
        } else {
            self
        }
    }
}
