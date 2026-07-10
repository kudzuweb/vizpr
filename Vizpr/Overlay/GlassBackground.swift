import SwiftUI

/// The overlay's user-tunable appearance (PR 11): lavender-default tint,
/// optional custom text base. The settled:mutable opacity RATIO is locked
/// (VizprSettings.mutableOpacityRatio) — themes recolor the trust contract,
/// never collapse it. Linked mode derives the text base from the tint.
struct OverlayTheme: Equatable {
    var tint: Color
    var tintStrength: Double
    /// nil = system label colors (adaptive primary/secondary).
    var textBase: Color?

    static let standard = OverlayTheme(
        tint: Color(hex: VizprSettings.default.tintHex) ?? .purple,
        tintStrength: VizprSettings.default.tintStrength,
        textBase: nil
    )

    static func from(_ settings: VizprSettings) -> OverlayTheme {
        let tint = Color(hex: settings.tintHex) ?? Self.standard.tint
        let base: Color? = settings.colorsLinked
            ? tint
            : settings.textBaseHex.flatMap { Color(hex: $0) }
        return OverlayTheme(tint: tint, tintStrength: settings.tintStrength, textBase: base)
    }
}

extension Color {
    /// 6-digit RGB hex (pre-sanitized by VizprSettings).
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// §13 glass: frosted capsule, tinted per theme (lavender 13% default).
/// macOS 26 gets real glass; earlier gets NSVisualEffectView (HUD material,
/// behind-window) under the same low-opacity tint. Reduce Transparency is
/// honored by the system materials automatically — never overridden here.
struct GlassBackground: View {
    var theme: OverlayTheme = .standard

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if #available(macOS 26, *) {
                shape.fill(.clear)
                    .glassEffect(
                        .regular.tint(theme.tint.opacity(theme.tintStrength)),
                        in: shape
                    )
            } else {
                VisualEffectBlur()
                    .overlay(shape.fill(theme.tint.opacity(theme.tintStrength)))
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
