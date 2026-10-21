import AppKit
import SwiftUI

/// One complete overlay appearance (PR 14): surface kind, shape, colors, font
/// and slab parameters under a name. Settings holds the user's looks; the two
/// built-ins are constants and are never persisted.
///
/// The settled:mutable text ratio is NOT part of a look. It is the trust
/// contract (VizprSettings.mutableOpacityRatio): a look recolors it, never
/// collapses it.
struct OverlayLook: Codable, Equatable, Sendable, Identifiable {
    enum Surface: String, Codable, Sendable, CaseIterable { case glass, slab }
    enum FontDesign: String, Codable, Sendable, CaseIterable { case rounded, standard, serif, monospaced }
    /// Reserved: rendered by a later PR.
    enum WordAppearance: String, Codable, Sendable, CaseIterable { case instant, fade, blurIn }

    static let defaultTintHex = "A16FDF"
    static let cornerRadiusRange = 8.0...40.0
    static let tintStrengthRange = 0.0...0.5
    static let fontSizeRange = 12.0...28.0

    var id: UUID
    var name: String
    var surface: Surface = .glass
    var cornerRadius: Double = 22
    /// Glass tint, and the recording dot / inviz pill on every surface.
    var tintHex: String = OverlayLook.defaultTintHex
    /// Glass only.
    var tintStrength: Double = 0.13
    /// nil = system label colors.
    var textBaseHex: String?
    /// The text base derives from the tint.
    var colorsLinked: Bool = false
    var slab: SlabStyle = .default
    var fontDesign: FontDesign = .rounded
    var fontSize: Double = 16
    var wordAppearance: WordAppearance = .instant
    var style: LookStyle = .neutral

    static let glass = OverlayLook(
        id: UUID(uuidString: "6B1E5A4C-0D2F-4C8E-9A57-3F1B7D20A001")!,
        name: "Glass"
    )

    /// The slab is dark in light and dark mode alike, so it carries its own
    /// text color: system label colors turn black in light mode.
    static let slab = OverlayLook(
        id: UUID(uuidString: "6B1E5A4C-0D2F-4C8E-9A57-3F1B7D20A002")!,
        name: "Slab",
        surface: .slab,
        textBaseHex: "F2EEF8"
    )

    static let builtIns = [glass, slab]

    /// Each saved look is merged over this when loading, so a field added in a
    /// later build takes the value given here for every look saved before it
    /// existed. A new field's value here must be its no-visible-change value
    /// (an effect at 0, a feature off, the existing behavior kept); built-in
    /// looks opt into new effects explicitly. Saved elements carry their own
    /// id and name, so those two are placeholders.
    static let mergeTemplate = OverlayLook(id: glass.id, name: "")

    static func isBuiltIn(_ id: UUID) -> Bool { builtIns.contains { $0.id == id } }
    var isBuiltIn: Bool { Self.isBuiltIn(id) }

    func clamped() -> OverlayLook {
        var look = self
        look.name = String(look.name.prefix(40))
        look.cornerRadius = min(max(look.cornerRadius, Self.cornerRadiusRange.lowerBound),
                                Self.cornerRadiusRange.upperBound)
        look.tintHex = VizprSettings.sanitizeHex(look.tintHex) ?? Self.defaultTintHex
        look.tintStrength = min(max(look.tintStrength, Self.tintStrengthRange.lowerBound),
                                Self.tintStrengthRange.upperBound)
        look.textBaseHex = look.textBaseHex.flatMap(VizprSettings.sanitizeHex)
        look.slab = look.slab.clamped()
        look.fontSize = min(max(look.fontSize, Self.fontSizeRange.lowerBound),
                            Self.fontSizeRange.upperBound)
        return look
    }

    // MARK: Rendering

    var tintColor: Color { Color(hex: tintHex) ?? Color(hex: Self.defaultTintHex)! }

    /// nil = system label colors (adaptive primary/secondary).
    var textBaseColor: Color? {
        colorsLinked ? tintColor : textBaseHex.flatMap { Color(hex: $0) }
    }

    /// Trust-contract styles shared by every surface: settled text at full
    /// color, mutable text at the locked fraction of it.
    var settledStyle: AnyShapeStyle {
        textBaseColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)
    }

    var mutableStyle: AnyShapeStyle {
        textBaseColor.map { AnyShapeStyle($0.opacity(VizprSettings.mutableOpacityRatio)) }
            ?? AnyShapeStyle(.secondary)
    }

    var font: Font {
        .system(size: fontSize, weight: .regular, design: fontDesign.swiftUIDesign)
    }

    /// The AppKit twin of `font`. The controller measures with this, so it
    /// must stay in step with `font`: a mismatch undersizes the pane and
    /// clips text.
    var measuringFont: NSFont {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        return base.fontDescriptor.withDesign(fontDesign.appKitDesign)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    }
}

extension OverlayLook.FontDesign {
    var swiftUIDesign: Font.Design {
        switch self {
        case .rounded: .rounded
        case .standard: .default
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    var appKitDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .rounded: .rounded
        case .standard: .default
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}
