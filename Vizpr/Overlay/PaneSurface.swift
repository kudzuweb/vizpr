import SwiftUI

/// The overlay pane's background, chosen by the look's surface. Shared by the
/// transcript pane and the inviz indicator.
struct PaneSurface: View {
    let look: OverlayLook
    /// False under Reduce Motion. The glass ignores it; the slab animates only
    /// when true.
    let animated: Bool

    var body: some View {
        ZStack {
            surface
            LightLayer(light: look.style.light, cornerRadius: look.cornerRadius, animated: animated)
        }
    }

    @ViewBuilder private var surface: some View {
        switch look.surface {
        case .glass:
            GlassSurface(look: look)
        case .slab:
            SlabSurface(style: look.slab, cornerRadius: look.cornerRadius, animated: animated)
        case .solid:
            SolidSurface(style: look.style.fill, cornerRadius: look.cornerRadius)
        }
    }
}

/// A flat rounded-rectangle fill. The 0.05 floor keeps the pane visible (and
/// its text legible against the desktop) when frost is dragged to 0.
private struct SolidSurface: View {
    let style: FillStyle
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill((Color(hex: style.colorHex) ?? .black).opacity(max(style.frost, 0.05)))
    }
}

/// §13 glass: frosted pane, tinted per look (lavender 13% default).
/// macOS 26 gets real glass; earlier gets NSVisualEffectView (HUD material,
/// behind-window) under the same low-opacity tint. Reduce Transparency is
/// honored by the system materials automatically — never overridden here.
private struct GlassSurface: View {
    let look: OverlayLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
        let tint = look.tintColor.opacity(look.tintStrength)
        let frost = look.style.fill
        Group {
            if #available(macOS 26, *) {
                shape.fill(.clear)
                    .glassEffect(.regular.tint(tint), in: shape)
            } else {
                VisualEffectBlur()
                    .overlay(shape.fill(tint))
                    .clipShape(shape)
            }
        }
        // Frost covers the material: 0 leaves it as-is, 1 hides what is behind.
        .overlay(shape.fill(Color(hex: frost.colorHex)?.opacity(frost.frost) ?? .clear))
    }
}

/// NSVisualEffectView bridge for the pre-26 fallback.
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
