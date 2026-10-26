import AppKit
import Foundation
import SwiftUI
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
        let folder = try LookFixtures.folder()
        try LookFixtures.put("""
        {"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Old", "surface": "glass"}
        """, "old.json", in: folder)
        #expect(try #require(LookFiles.load(from: folder).looks.first).style == .neutral)
    }

    @Test("The neutral style has no light, border, glow or shadow to draw")
    func neutralDrawsNothing() {
        let style = LookStyle.neutral
        #expect(style.light.isNone)
        #expect(!style.border.enabled && !style.outerGlow.enabled && !style.dropShadow.enabled)
        #expect(style.fill.frost == 0)
    }

    @Test("A saved look without a backdrop key renders no backdrop")
    func missingBackdropKeyDrawsNothing() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put("""
        {"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Old", "surface": "solid",
         "style": {"fill": {"frost": 0.16, "colorHex": "2A1F3D"}}}
        """, "old.json", in: folder)
        let style = try #require(LookFiles.load(from: folder).looks.first).style
        #expect(style.fill.frost == 0.16, "the saved style loaded")
        #expect(style.backdrop == BackdropStyle())
        #expect(!style.backdrop.enabled)
        #expect(PaneEffects.margin(for: style) == 0)
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

        style.backdrop = BackdropStyle(enabled: true, colorHex: "000000", strength: 0.5, feather: 60)
        #expect(PaneEffects.margin(for: style) == 66, "the backdrop's fade reaches a little past its feather")
        style.backdrop.enabled = false
        #expect(PaneEffects.margin(for: style) == 0)
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

// MARK: Measurement

/// The controller sizes the pane from `paneHeight(fitting:)`; a height smaller
/// than the rendered text clips it, silently, so the measurement is checked
/// against real SwiftUI layout for each way a look can set its font and spacing.
@MainActor
@Suite("Pane height fits the rendered text")
struct PaneMeasurementTests {
    private typealias Configure = @Sendable (inout OverlayLook) -> Void

    private let text = String(
        repeating: "The settled words read steadily while the newest draft words are still live. ", count: 6
    )

    private func look(_ configure: Configure) -> OverlayLook {
        var look = OverlayLook.glass
        configure(&look)
        return look
    }

    private let shortText = "A few words that fit on one line."

    /// Height SwiftUI gives `text` at the width the view lays it out in for
    /// the pane the measurement chose.
    private func renderedTextHeight(_ look: OverlayLook, _ text: String) -> CGFloat {
        let style = look.style
        let width = look.textWidth(inPaneWidth: look.paneWidth(fitting: text))
        let view = Text(text)
            .font(look.font)
            .lineSpacing(style.text.lineSpacing)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        return NSHostingView(rootView: view).fittingSize.height
    }

    private static let options: [(String, Configure)] = [
        ("system rounded", { _ in }),
        ("system serif bold", { $0.fontDesign = .serif; $0.style.text.weight = .bold }),
        ("Georgia semibold", { $0.style.text.fontFamily = "Georgia"; $0.style.text.weight = .semibold }),
        ("line spacing 8", { $0.style.text.lineSpacing = 8 }),
        ("padding 30, width 700", {
            $0.style.pane.paddingVertical = 30
            $0.style.pane.paddingHorizontal = 30
            $0.style.pane.width = 700
        }),
        ("Georgia, spacing 8, padding 30", {
            $0.style.text.fontFamily = "Georgia"
            $0.style.text.lineSpacing = 8
            $0.style.pane.paddingVertical = 30
            $0.style.pane.paddingHorizontal = 30
        })
    ]

    @Test("Measured height covers the text and leaves at most a few points under it")
    func fits() {
        for (name, configure) in Self.options {
            let look = look(configure)
            for sample in [text, shortText] {
                let rendered = renderedTextHeight(look, sample)
                let padding = 2 * look.style.pane.paddingVertical
                let measured = look.paneHeight(fitting: sample)
                #expect(measured >= rendered + padding, "\(name): text would clip")
                #expect(measured <= rendered + padding + 4, "\(name): gap under the text")
            }
        }
    }

    @Test("A pane sized to one line never wraps the text in the view")
    func narrowPaneDoesNotWrap() {
        for (name, configure) in Self.options {
            let look = look(configure)
            let oneLine = ceil(look.measuringFont.ascender - look.measuringFont.descender) + 1
            for sample in ["a", shortText, String(text.prefix(40))] {
                guard look.paneWidth(fitting: sample) < CGFloat(look.style.pane.width) else { continue }
                #expect(renderedTextHeight(look, sample) <= oneLine, "\(name): '\(sample)' wrapped")
            }
        }
    }

    @Test("Pane width clamps between the resting width and the look's width and never narrows as text grows")
    func paneWidthGrowsWithText() {
        for (name, configure) in Self.options {
            let look = look(configure)
            var previous = OverlayLayout.restingSize.width
            for count in [1, 5, 20, 60, 200] {
                let sample = String(repeating: "word ", count: count)
                let width = look.paneWidth(fitting: sample)
                #expect(width >= previous, "\(name): width shrank at \(count) words")
                #expect(width >= OverlayLayout.restingSize.width && width <= look.style.pane.width)
                previous = width
            }
            #expect(look.paneWidth(fitting: "a") == OverlayLayout.restingSize.width, "\(name)")
            #expect(look.paneWidth(fitting: text) == CGFloat(look.style.pane.width), "\(name)")
        }
    }

    @Test("The corner icon's overhang fits in the panel margin")
    func marginCoversOverhang() {
        #expect(look { _ in }.panelMargin >= TargetAppMetrics.cornerOverhang)
    }

    @Test("Only the inviz pill reserves side room; the pane stays put when it does")
    func sideInsetKeepsPane() {
        for display in [TargetAppDisplay.off, .icon, .iconAndName] {
            #expect(TargetAppMetrics.sideInset(for: display, inviz: false) == 0)
        }
        #expect(TargetAppMetrics.sideInset(for: .off, inviz: true) == 0)
        #expect(TargetAppMetrics.sideInset(for: .icon, inviz: true) > 0)
        let layout = OverlayLayout(screen: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let bare = layout.frame(contentHeight: 100, paneWidth: 560, margin: 10)
        let inset = TargetAppMetrics.sideInset(for: .iconAndName, inviz: true)
        let wide = layout.frame(contentHeight: 100, paneWidth: 560, margin: 10, sideInset: inset)
        #expect(wide.minX == bare.minX - inset)
        #expect(wide.width == bare.width + 2 * inset)
        #expect(wide.midX == bare.midX)
        #expect(wide.minY == bare.minY && wide.height == bare.height)
    }

    @Test("A named family that is installed is used; a missing one falls back to the system font")
    func familyFallback() {
        let georgia = look { $0.style.text.fontFamily = "Georgia" }
        #expect(georgia.measuringFont.familyName == "Georgia")
        let missing = look { $0.style.text.fontFamily = "No Such Family 123" }
        #expect(missing.measuringFont == look { _ in }.measuringFont)
    }

    @Test("Weight changes the measured font on the system path")
    func weightReachesTheSystemFont() {
        #expect(look { _ in }.measuringFont != look { $0.style.text.weight = .bold }.measuringFont)
    }
}
