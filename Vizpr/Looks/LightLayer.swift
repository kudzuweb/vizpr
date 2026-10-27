import SwiftUI

/// One transparent layer of light drawn over any pane surface (PR 15), clipped
/// to the pane's shape. A look with no light draws nothing. Only a look with a
/// moving term (sheen or grain) ticks; a still layer renders once.
struct LightLayer: View {
    let light: LightStyle
    let cornerRadius: CGFloat
    /// False under Reduce Motion: render one still frame (time 0) instead of animating.
    let animated: Bool

    private var isMoving: Bool { light.sheen > 0 || light.grain > 0 }

    @ViewBuilder var body: some View {
        if light.isNone {
            EmptyView()
        } else if isMoving && animated {
            TimelineView(.animation) { timeline in
                LightFrame(light: light, cornerRadius: cornerRadius,
                           time: SlabSurface.shaderTime(for: timeline.date))
            }
        } else {
            LightFrame(light: light, cornerRadius: cornerRadius, time: 0)
        }
    }
}

/// One frame of the light at a given shader time. Split out so a still frame
/// can be rendered at any time.
struct LightFrame: View {
    let light: LightStyle
    let cornerRadius: CGFloat
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.white)
                .colorEffect(ShaderLibrary.paneLight(
                    .float2(proxy.size),
                    .float(Float(time)),
                    .float(Float(cornerRadius)),
                    .float(Float(light.edgeLight)),
                    .float(Float(light.bevel)),
                    .float(Float(light.gloss)),
                    .float(Float(light.sheen)),
                    .float(Float(light.sheenSweepSeconds)),
                    .float(Float(light.grain))
                ))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}
