import Foundation

/// The slider range of each look field in `LookStyle` and `SlabStyle`. Each
/// mirrors that field's `clamped()` bound; LooksEditorTests fails when the two
/// drift, because a slider longer than the clamp silently stops moving the
/// look partway along its travel.
enum LookRanges {
    static let unit = 0.0...1.0

    static let backdropStrength = 0.0...0.9
    static let backdropFeather = 0.0...60.0

    static let grain = 0.0...0.2
    static let sheenSweepSeconds = 1.0...30.0

    static let borderWidth = 0.5...6.0
    static let glowRadius = 1.0...60.0
    static let shadowRadius = 0.0...60.0
    static let shadowOffset = -40.0...40.0

    static let paneWidth = 360.0...900.0
    static let panePadding = 4.0...48.0

    static let lineSpacing = 0.0...16.0
    static let textGlowRadius = 0.0...20.0
    static let dotSize = 3.0...16.0

    static let meshDrift = 0.0...0.5
    static let meshLoopSeconds = 2.0...60.0
}
