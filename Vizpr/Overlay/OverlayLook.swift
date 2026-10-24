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
    enum Surface: String, Codable, Sendable, CaseIterable { case glass, slab, solid }
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
        textBaseHex: "F2EEF8",
        style: slabLightAndShadow
    )

    /// The Slab look's light and shadow: the values tuned in PR 14, now
    /// expressed as the generic light layer and drop shadow.
    private static var slabLightAndShadow: LookStyle {
        var style = LookStyle.neutral
        style.light = LightStyle(edgeLight: 0.25, bevel: 0.3, grain: 0.02)
        style.dropShadow = ShadowStyle(enabled: true, colorHex: "000000", radius: 8, x: 0, y: 3, opacity: 0.25)
        return style
    }

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
        look.style = look.style.clamped()
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

    /// The SwiftUI font. A configured family is shared with `measuringFont`
    /// (the same NSFont); otherwise this is the system font in the look's
    /// design, which `measuringFont` mirrors.
    var font: Font {
        if let family = familyFont { return Font(family as CTFont) }
        return .system(size: fontSize, weight: style.text.weight.swiftUIWeight, design: fontDesign.swiftUIDesign)
    }

    /// The AppKit twin of `font`. The controller measures with this, so it
    /// must stay in step with `font`: a mismatch undersizes the pane and
    /// clips text.
    var measuringFont: NSFont {
        if let family = familyFont { return family }
        let base = NSFont.systemFont(ofSize: fontSize, weight: style.text.weight.appKitWeight)
        return base.fontDescriptor.withDesign(fontDesign.appKitDesign)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
    }

    /// The configured family at the look's size and weight, or nil when none
    /// is set or it is not installed (the look then uses the system font).
    private var familyFont: NSFont? {
        guard let family = style.text.fontFamily else { return nil }
        return NSFontManager.shared.font(
            withFamily: family, traits: [], weight: style.text.weight.fontManagerWeight, size: fontSize
        )
    }

    /// Pane height needed for `text` at this look's width, font, line spacing
    /// and padding, plus one extra line of headroom: growth leads the text
    /// instead of trailing it, so a wrapping word never renders against the
    /// clipped edge. OverlayView lays the text out with the same width,
    /// padding, font and line spacing. `showingTarget` narrows the text column
    /// for the target-app icon, exactly as `OverlayView` does.
    func paneHeight(fitting text: String, showingTarget: Bool = false) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.text.lineSpacing
        let font = measuringFont
        let width = textWidth(showingTarget: showingTarget)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return ceil(bounds.height) + 2 * style.pane.paddingVertical + ceil(font.ascender - font.descender)
    }

    /// Where the transcript column starts in the expanded pane.
    func textLeadingInset(showingTarget: Bool) -> CGFloat {
        showingTarget
            ? TargetAppMetrics.textLeading(paddingHorizontal: style.pane.paddingHorizontal)
            : style.pane.paddingHorizontal
    }

    /// Width the transcript wraps to in the expanded pane. The view and the
    /// height measurement both use it.
    func textWidth(showingTarget: Bool) -> CGFloat {
        style.pane.width - textLeadingInset(showingTarget: showingTarget) - style.pane.paddingHorizontal
    }

    /// Distance from the expanded pane's top edge to the target icon's top,
    /// which centers the icon on the first line of text.
    var targetIconTopInset: CGFloat {
        let font = measuringFont
        let lineHeight = ceil(font.ascender - font.descender)
        let centered = style.pane.paddingVertical + (lineHeight - TargetAppMetrics.paneIconSize) / 2
        return max(centered, TargetAppMetrics.paneIconMinTop)
    }
}

extension TextStyle.Weight {
    var swiftUIWeight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var appKitWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    /// NSFontManager's 0...15 weight scale (5 is regular, 9 is bold).
    var fontManagerWeight: Int {
        switch self {
        case .light: 4
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        }
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
