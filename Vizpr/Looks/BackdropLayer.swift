import SwiftUI

/// The dimming layer behind the pane surface (`BackdropStyle`). Inside the pane
/// it is a uniform fill; outside, a blurred copy of the pane shape, grown so
/// the fade starts at full strength at the pane edge and is gone `feather`
/// points out. It draws below the surface, so the glass's own color never
/// depends on it.
struct BackdropLayer: View {
    let style: BackdropStyle
    let cornerRadius: CGFloat

    /// The blurred copy grows by half the feather and its blur is a fifth of
    /// the feather: the fade is centered half way out and is within about 1%
    /// of full and of nothing at the pane edge and at the feather distance.
    private static let growth = 0.5
    private static let blurFraction = 0.2

    /// How far past the pane edge the layer draws: the growth plus three
    /// standard deviations of blur (a Gaussian is negligible beyond that),
    /// which is 1.1 times the feather.
    static func reach(feather: Double) -> CGFloat {
        feather + feather / 10
    }

    var body: some View {
        if style.enabled {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let color = (Color(hex: style.colorHex) ?? .black).opacity(style.strength)
            ZStack {
                shape.fill(color)
                if style.feather > 0 {
                    let growth = style.feather * Self.growth
                    RoundedRectangle(cornerRadius: cornerRadius + growth, style: .continuous)
                        .fill(color)
                        .padding(-growth)
                        .blur(radius: style.feather * Self.blurFraction)
                        .maskedToOutside(of: shape, margin: Self.reach(feather: style.feather))
                }
            }
            .allowsHitTesting(false)
        }
    }
}
