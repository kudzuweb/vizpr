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
}
