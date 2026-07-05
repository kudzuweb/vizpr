import SwiftUI

/// §13 glass: frosted capsule with the locked #A16FDF lavender tint at 13%.
/// macOS 26 gets real glass; earlier gets NSVisualEffectView (HUD material,
/// behind-window) under the same low-opacity tint. Reduce Transparency is
/// honored by the system materials automatically — never overridden here.
struct GlassBackground: View {
    /// Locked tint (§15 decision log: 8% too faint, 17% too branded).
    static let tint = Color(red: 0xA1 / 255, green: 0x6F / 255, blue: 0xDF / 255)
    static let tintStrength = 0.13

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if #available(macOS 26, *) {
                shape.fill(.clear)
                    .glassEffect(
                        .regular.tint(Self.tint.opacity(Self.tintStrength)),
                        in: shape
                    )
            } else {
                VisualEffectBlur()
                    .overlay(shape.fill(Self.tint.opacity(Self.tintStrength)))
                    .clipShape(shape)
            }
        }
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
