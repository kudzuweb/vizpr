import Foundation

/// Parameters for the animated mesh body of the "slab" pane surface (PR 14).
/// Light and shadow live in `LookStyle`. Pure data: SlabSurface renders it
/// and OverlayLook persists it. `clamped()` bounds every value, so a
/// hand-edited settings file can't smuggle in a pathological one.
struct SlabStyle: Codable, Equatable, Sendable {
    /// 3x3 mesh colors, row-major, 6-digit RGB hex.
    var meshColorsHex: [String] = SlabStyle.defaultMeshColors
    /// How far the interior mesh points drift, as a fraction of a cell, 0...0.5.
    var meshDrift: Double = 0.06
    /// Seconds per full drift loop, 2...60.
    var meshLoopSeconds: Double = 40

    static let defaultMeshColors = [
        "1B1726", "231C35", "1A1624",
        "251E3A", "30264A", "221B31",
        "18141F", "201A2C", "16121C"
    ]
    static let `default` = SlabStyle()

    func clamped() -> SlabStyle {
        var style = self
        let colors = style.meshColorsHex.compactMap(OverlayLook.sanitizeHex)
        style.meshColorsHex = colors.count == 9 ? colors : Self.defaultMeshColors
        style.meshDrift = min(max(style.meshDrift, 0), 0.5)
        style.meshLoopSeconds = min(max(style.meshLoopSeconds, 2), 60)
        return style
    }
}
