import Foundation
import Testing
@testable import Vizpr

/// `LookStyle.neutral` must stay the no-visible-change style: saved looks
/// merge over the template carrying it, so a non-neutral default would
/// silently restyle every look already made.
@Suite("LookStyle neutrality")
struct LookStyleTests {
    @Test("Glass carries the neutral style")
    func glassIsNeutral() {
        #expect(OverlayLook.glass.style == .neutral)
        #expect(OverlayLook.mergeTemplate.style == .neutral)
    }

    @Test("A saved look without a style key loads with the neutral style")
    func missingStyleKeyLoadsNeutral() throws {
        let json = """
        {"looks": [{"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Old", "surface": "glass"}]}
        """
        let settings = try VizprSettings.load(from: Data(json.utf8))
        #expect(try #require(settings.looks.first).style == .neutral)
    }

    @Test("The neutral style has no light, border, glow or shadow to draw")
    func neutralDrawsNothing() {
        let style = LookStyle.neutral
        #expect(style.light.isNone)
        #expect(!style.border.enabled && !style.outerGlow.enabled && !style.dropShadow.enabled)
        #expect(style.fill.frost == 0)
    }

    // MARK: Panel margin

    private let layout = OverlayLayout(screen: CGRect(x: 0, y: 0, width: 1600, height: 1000))

    @Test("The margin is the largest extent of the enabled effects, and 0 with none")
    func marginCoversEnabledEffects() {
        #expect(PaneEffects.margin(for: .neutral) == 0)

        var style = LookStyle.neutral
        style.outerGlow = GlowStyle(enabled: true, colorHex: "FFFFFF", radius: 20, strength: 0.7)
        #expect(PaneEffects.margin(for: style) == 40)

        style.dropShadow = ShadowStyle(enabled: true, colorHex: "000000", radius: 8, x: -30, y: 3, opacity: 0.3)
        #expect(PaneEffects.margin(for: style) == 46, "the offset shadow reaches further than the glow")

        style.dropShadow.enabled = false
        style.outerGlow.enabled = false
        #expect(PaneEffects.margin(for: style) == 0, "disabled effects take no room")
    }

    @Test("A margin grows the panel around the pane without moving the pane")
    func marginKeepsPaneInPlace() {
        for content in [0, 100, 400, 900] as [CGFloat] {
            let bare = layout.frame(contentHeight: content)
            let padded = layout.frame(contentHeight: content, margin: 40)
            #expect(padded.minX == bare.minX - 40 && padded.maxX == bare.maxX + 40)
            #expect(padded.minY + 40 == bare.minY, "the pane's bottom edge stays put")
            #expect(padded.maxY - 40 == bare.maxY)
            #expect(padded.midX == bare.midX)
        }
    }

    @Test("The look's pane width sets the reading width")
    func paneWidthSetsPanelWidth() {
        #expect(layout.frame(contentHeight: 100, paneWidth: 700).width == 700)
        #expect(layout.frame(contentHeight: 0, paneWidth: 700).width == OverlayLayout.restingSize.width)
    }
}
