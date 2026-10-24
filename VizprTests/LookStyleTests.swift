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

    @Test("A saved look without a backdrop key renders no backdrop")
    func missingBackdropKeyDrawsNothing() throws {
        let json = """
        {"looks": [{"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Old", "surface": "solid",
                    "style": {"fill": {"frost": 0.16, "colorHex": "2A1F3D"}}}]}
        """
        let style = try #require(try VizprSettings.load(from: Data(json.utf8)).looks.first).style
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

    private func renderedTextHeight(_ look: OverlayLook, showingTarget: Bool = false) -> CGFloat {
        let style = look.style
        let width = look.textWidth(showingTarget: showingTarget)
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

    @Test("Measured height covers the text and stays within two lines of it")
    func fits() {
        for (name, configure) in Self.options {
            let look = look(configure)
            let rendered = renderedTextHeight(look)
            let padding = 2 * look.style.pane.paddingVertical
            let line = ceil(look.measuringFont.ascender - look.measuringFont.descender)
            let measured = look.paneHeight(fitting: text)
            #expect(measured >= rendered + padding, "\(name): text would clip")
            #expect(measured <= rendered + padding + 2 * line + look.style.text.lineSpacing,
                    "\(name): pane far taller than text")
        }
    }

    @Test("With the target icon shown the text wraps narrower and the pane measures for that width")
    func iconColumnEntersMeasurement() {
        for (name, configure) in Self.options {
            let look = look(configure)
            let narrow = look.textWidth(showingTarget: true)
            #expect(narrow < look.textWidth(showingTarget: false), "\(name): icon column takes no width")
            let rendered = renderedTextHeight(look, showingTarget: true)
            let measured = look.paneHeight(fitting: text, showingTarget: true)
            #expect(measured >= rendered + 2 * look.style.pane.paddingVertical, "\(name): text would clip")
            #expect(measured >= look.paneHeight(fitting: text), "\(name): narrower column cannot be shorter")
        }
    }

    @Test("The icon never rides closer than the minimum to the pane's top edge")
    func iconTopInsetClamped() {
        let tight = look { $0.style.pane.paddingVertical = 4 }
        #expect(tight.targetIconTopInset == TargetAppMetrics.paneIconMinTop)
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
