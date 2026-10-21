import Foundation

/// Parameters for the opaque, animated "slab" pane surface (PR 14). Pure
/// data: SlabSurface renders it and OverlayLook persists it. `clamped()`
/// bounds every value, so a hand-edited settings file can't smuggle in a
/// pathological one.
struct SlabStyle: Codable, Equatable, Sendable {
    /// 3x3 mesh colors, row-major, 6-digit RGB hex.
    var meshColorsHex: [String] = SlabStyle.defaultMeshColors
    /// How far the interior mesh points drift, as a fraction of a cell, 0...0.5.
    var meshDrift: Double = 0.18
    /// Seconds per full drift loop, 2...60.
    var meshLoopSeconds: Double = 12
    /// Strength of the moving diagonal sheen band, 0...1.
    var sheenStrength: Double = 0.22
    /// Seconds per sheen sweep, 1...30.
    var sheenSweepSeconds: Double = 6
    /// Soft light along the top edge, 0...1.
    var edgeGlow: Double = 0.35
    /// Inner bevel: lighter top edge, darker bottom edge, 0...1.
    var bevel: Double = 0.5
    /// Animated film grain, 0...0.2.
    var grain: Double = 0.035
    /// Drop shadow opacity, 0...0.8.
    var shadow: Double = 0.35

    static let defaultMeshColors = [
        "1B1726", "231C35", "1A1624",
        "251E3A", "30264A", "221B31",
        "18141F", "201A2C", "16121C"
    ]
    static let `default` = SlabStyle()

    func clamped() -> SlabStyle {
        var style = self
        let colors = style.meshColorsHex.compactMap(VizprSettings.sanitizeHex)
        style.meshColorsHex = colors.count == 9 ? colors : Self.defaultMeshColors
        style.meshDrift = min(max(style.meshDrift, 0), 0.5)
        style.meshLoopSeconds = min(max(style.meshLoopSeconds, 2), 60)
        style.sheenStrength = min(max(style.sheenStrength, 0), 1)
        style.sheenSweepSeconds = min(max(style.sheenSweepSeconds, 1), 30)
        style.edgeGlow = min(max(style.edgeGlow, 0), 1)
        style.bevel = min(max(style.bevel, 0), 1)
        style.grain = min(max(style.grain, 0), 0.2)
        style.shadow = min(max(style.shadow, 0), 0.8)
        return style
    }
}
