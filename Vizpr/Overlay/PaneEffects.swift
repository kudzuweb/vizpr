import SwiftUI

/// Border, outer glow and drop shadow around a pane (PR 15). Applied to the
/// pane surface; the glow and shadow draw beyond the pane's bounds, so the
/// overlay panel is sized with `margin(for:)` of room around the pane.
struct PaneEffects: ViewModifier {
    let style: LookStyle
    let cornerRadius: CGFloat

    /// The blur of a glow or shadow reaches about twice its radius.
    private static let blurReach = 2.0

    /// Room the panel must leave around the pane so the enabled effects are
    /// not clipped: the largest extent of the glow, the shadow and the backdrop.
    static func margin(for style: LookStyle) -> CGFloat {
        let glow = style.outerGlow.enabled ? style.outerGlow.radius * blurReach : 0
        let shadow = style.dropShadow.enabled
            ? style.dropShadow.radius * blurReach + max(abs(style.dropShadow.x), abs(style.dropShadow.y))
            : 0
        let backdrop = style.backdrop.enabled ? BackdropLayer.reach(feather: style.backdrop.feather) : 0
        return ceil(max(glow, shadow, backdrop))
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay { border(shape) }
            .background { outsideEffects(shape) }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        let border = style.border
        if border.enabled {
            shape.strokeBorder(Color(hex: border.colorHex)?.opacity(border.opacity) ?? .clear,
                               lineWidth: border.width)
        }
    }

    /// Glow and shadow are blurred copies of the pane shape. Glass is
    /// see-through, so a copy left behind the pane would tint its interior:
    /// each is masked to the region outside the pane shape, which keeps the
    /// pane's own surface untouched.
    @ViewBuilder private func outsideEffects(_ shape: RoundedRectangle) -> some View {
        ZStack {
            if style.dropShadow.enabled {
                let shadow = style.dropShadow
                shape.fill((Color(hex: shadow.colorHex) ?? .black).opacity(shadow.opacity))
                    .blur(radius: shadow.radius)
                    .offset(x: shadow.x, y: shadow.y)
            }
            if style.outerGlow.enabled {
                let glow = style.outerGlow
                shape.fill((Color(hex: glow.colorHex) ?? .white).opacity(glow.strength))
                    .blur(radius: glow.radius)
            }
        }
        .maskedToOutside(of: shape, margin: Self.margin(for: style))
    }
}

extension View {
    /// Keeps only the part of the view outside `shape`, within `margin` points
    /// of it.
    func maskedToOutside(of shape: RoundedRectangle, margin: CGFloat) -> some View {
        mask {
            Rectangle()
                .padding(-margin - 1)
                .overlay { shape.fill(.black).blendMode(.destinationOut) }
                .compositingGroup()
        }
    }

    func paneEffects(_ style: LookStyle, cornerRadius: CGFloat) -> some View {
        modifier(PaneEffects(style: style, cornerRadius: cornerRadius))
    }
}
