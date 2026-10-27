import Foundation

/// Every adjustable aspect of a look beyond its surface body (PR 15): fill,
/// light, border, glow, shadow, pane shape, text and the recording dot. Pure
/// data; PaneSurface and OverlayView render it, Settings edits it.
///
/// Every default here is the field's no-visible-change value, so `.neutral`
/// is today's Glass appearance. Saved looks merge over a template carrying
/// `.neutral` (OverlayLook.mergeTemplate), so a field added here never
/// restyles a look the user already made. Built-in looks opt into effects
/// explicitly.
struct LookStyle: Codable, Equatable, Sendable {
    var glass = GlassStyle()
    var fill = FillStyle()
    var backdrop = BackdropStyle()
    var light = LightStyle()
    var border = BorderStyle()
    var outerGlow = GlowStyle()
    var dropShadow = ShadowStyle()
    var pane = PaneShape()
    var text = TextStyle()
    var dot = DotStyle()

    static let neutral = LookStyle()

    func clamped() -> LookStyle {
        LookStyle(
            glass: glass,
            fill: fill.clamped(),
            backdrop: backdrop.clamped(),
            light: light.clamped(),
            border: border.clamped(),
            outerGlow: outerGlow.clamped(),
            dropShadow: dropShadow.clamped(),
            pane: pane.clamped(),
            text: text.clamped(),
            dot: dot.clamped()
        )
    }
}

/// Which system glass the glass surface draws. `regular` is the default and
/// what every look made before this field renders; `clear` is the more
/// transparent glass, which the system docs pair with a dimming layer behind
/// it (`BackdropStyle`) for legible text. Other surfaces ignore it.
struct GlassStyle: Codable, Equatable, Sendable {
    enum Variant: String, Codable, Sendable, CaseIterable { case regular, clear }

    var variant = Variant.regular
}

/// How much the surface covers what is behind it. Glass: 0 is the system
/// material as-is, 1 is fully covered by `colorHex` (frosted to solid).
/// Solid: the fill's opacity is `max(frost, 0.05)`. Slab: unused.
struct FillStyle: Codable, Equatable, Sendable {
    var frost = 0.0
    var colorHex = "1C1828"

    func clamped() -> FillStyle {
        FillStyle(frost: frost.clamped(to: 0...1),
                  colorHex: OverlayLook.sanitizeHex(colorHex) ?? FillStyle().colorHex)
    }
}

/// A neutral dimming layer BEHIND the surface: it quiets busy content so text
/// reads, without coloring the glass above it. Disabled is no layer at all.
struct BackdropStyle: Codable, Equatable, Sendable {
    var enabled = false
    var colorHex = "000000"
    /// Opacity inside the pane, 0...0.9.
    var strength = 0.45
    /// How far past the pane edge the backdrop fades to nothing, points, 0...60.
    var feather = 16.0

    func clamped() -> BackdropStyle {
        BackdropStyle(enabled: enabled,
                      colorHex: OverlayLook.sanitizeHex(colorHex) ?? BackdropStyle().colorHex,
                      strength: strength.clamped(to: 0...0.9),
                      feather: feather.clamped(to: 0...60))
    }
}

/// Light drawn over any surface as one transparent layer. All zero draws
/// no layer at all.
struct LightStyle: Codable, Equatable, Sendable {
    /// Soft light along the top edge.
    var edgeLight = 0.0
    /// Inner bevel: lighter top edge, darker bottom edge.
    var bevel = 0.0
    /// Matte (0) to shiny (1): a still specular highlight near the top.
    var gloss = 0.0
    /// A moving diagonal sheen band.
    var sheen = 0.0
    var sheenSweepSeconds = 6.0
    /// Animated film grain.
    var grain = 0.0

    var isNone: Bool { edgeLight == 0 && bevel == 0 && gloss == 0 && sheen == 0 && grain == 0 }

    func clamped() -> LightStyle {
        LightStyle(edgeLight: edgeLight.clamped(to: 0...1),
                   bevel: bevel.clamped(to: 0...1),
                   gloss: gloss.clamped(to: 0...1),
                   sheen: sheen.clamped(to: 0...1),
                   sheenSweepSeconds: sheenSweepSeconds.clamped(to: 1...30),
                   grain: grain.clamped(to: 0...0.2))
    }
}

struct BorderStyle: Codable, Equatable, Sendable {
    var enabled = false
    var width = 1.0
    var colorHex = "FFFFFF"
    var opacity = 0.25

    func clamped() -> BorderStyle {
        BorderStyle(enabled: enabled,
                    width: width.clamped(to: 0.5...6),
                    colorHex: OverlayLook.sanitizeHex(colorHex) ?? BorderStyle().colorHex,
                    opacity: opacity.clamped(to: 0...1))
    }
}

/// A glow around the pane's outline.
struct GlowStyle: Codable, Equatable, Sendable {
    var enabled = false
    var colorHex = "A16FDF"
    var radius = 12.0
    var strength = 0.5

    func clamped() -> GlowStyle {
        GlowStyle(enabled: enabled,
                  colorHex: OverlayLook.sanitizeHex(colorHex) ?? GlowStyle().colorHex,
                  radius: radius.clamped(to: 1...60),
                  strength: strength.clamped(to: 0...1))
    }
}

struct ShadowStyle: Codable, Equatable, Sendable {
    var enabled = false
    var colorHex = "000000"
    var radius = 8.0
    var x = 0.0
    var y = 3.0
    var opacity = 0.25

    func clamped() -> ShadowStyle {
        ShadowStyle(enabled: enabled,
                    colorHex: OverlayLook.sanitizeHex(colorHex) ?? ShadowStyle().colorHex,
                    radius: radius.clamped(to: 0...60),
                    x: x.clamped(to: -40...40),
                    y: y.clamped(to: -40...40),
                    opacity: opacity.clamped(to: 0...1))
    }
}

/// Pane geometry. The defaults are the pre-PR 15 constants
/// (OverlayLayout.readingWidth and OverlayView's text padding).
struct PaneShape: Codable, Equatable, Sendable {
    var width = 560.0
    var paddingHorizontal = 18.0
    var paddingVertical = 12.0

    func clamped() -> PaneShape {
        PaneShape(width: width.clamped(to: 360...900),
                  paddingHorizontal: paddingHorizontal.clamped(to: 4...48),
                  paddingVertical: paddingVertical.clamped(to: 4...48))
    }
}

struct TextStyle: Codable, Equatable, Sendable {
    enum Weight: String, Codable, Sendable, CaseIterable {
        case light, regular, medium, semibold, bold
    }

    /// A font family name (installed, or registered from Vizpr's Fonts
    /// folder). nil = the system font in the look's `fontDesign`. A family
    /// that is no longer available falls back to nil at render time.
    var fontFamily: String?
    var weight = Weight.regular
    /// Extra space between lines, points.
    var lineSpacing = 0.0
    var glowEnabled = false
    var glowColorHex = "FFFFFF"
    var glowRadius = 4.0

    func clamped() -> TextStyle {
        TextStyle(fontFamily: fontFamily.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) },
                  weight: weight,
                  lineSpacing: lineSpacing.clamped(to: 0...16),
                  glowEnabled: glowEnabled,
                  glowColorHex: OverlayLook.sanitizeHex(glowColorHex) ?? TextStyle().glowColorHex,
                  glowRadius: glowRadius.clamped(to: 0...20))
    }
}

/// The recording indicator.
struct DotStyle: Codable, Equatable, Sendable {
    /// nil = the look's tint.
    var colorHex: String?
    var size = 7.0
    var pulse = false

    func clamped() -> DotStyle {
        DotStyle(colorHex: colorHex.flatMap(OverlayLook.sanitizeHex),
                 size: size.clamped(to: 3...16),
                 pulse: pulse)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
