import SwiftUI

/// The opaque "slab" pane surface (PR 14): an animated mesh gradient body
/// lit by the `paneSlab` Metal shader. Drawn at the display's full frame rate
/// while animating; there is deliberately no throttle.
struct SlabSurface: View {
    let style: SlabStyle
    let cornerRadius: CGFloat
    /// False under Reduce Motion: render one still frame (time 0) instead of animating.
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            SlabLayer(
                style: style,
                cornerRadius: cornerRadius,
                time: animated ? Self.shaderTime(for: timeline.date) : 0
            )
        }
    }

    /// A Float holding the reference-date timestamp has no sub-second precision,
    /// so the time is wrapped to an hour before it reaches the GPU.
    static func shaderTime(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
    }

    /// Positions of the 3x3 mesh points in unit coordinates, row-major. Corners
    /// stay put and edge midpoints slide only along their own edge, so the
    /// outline stays exact; only the center moves in both axes.
    static func meshPoints(time: Double, drift: Double, loopSeconds: Double) -> [SIMD2<Float>] {
        let angle = 2 * Double.pi * time / loopSeconds
        let amplitude = drift * 0.5
        func wave(_ phase: Double) -> Float {
            Float(amplitude * sin(angle + phase))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(0), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(1.6)), SIMD2(0.5 + wave(3.1), 0.5 + wave(4.7)), SIMD2(1, 0.5 + wave(0.9)),
            SIMD2(0, 1), SIMD2(0.5 + wave(2.4), 1), SIMD2(1, 1)
        ]
    }
}

/// One frame of the slab at a given shader time. Split out so a still frame
/// can be rendered at any time.
struct SlabLayer: View {
    let style: SlabStyle
    let cornerRadius: CGFloat
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            MeshGradient(
                width: 3,
                height: 3,
                points: SlabSurface.meshPoints(
                    time: time, drift: style.meshDrift, loopSeconds: style.meshLoopSeconds
                ),
                colors: style.meshColorsHex.map { Color(hex: $0) ?? .black }
            )
            .colorEffect(ShaderLibrary.paneSlab(
                .float2(proxy.size),
                .float(Float(time)),
                .float(Float(style.sheenStrength)),
                .float(Float(style.sheenSweepSeconds)),
                .float(Float(style.edgeGlow)),
                .float(Float(style.bevel)),
                .float(Float(style.grain)),
                .float(Float(cornerRadius))
            ))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(style.shadow), radius: 8, y: 3)
        }
    }
}
