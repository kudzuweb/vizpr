import Foundation
import Testing
@testable import Vizpr

/// The settings.json format is a seam: a decode that throws silently resets
/// every setting, and a migration that misreads legacy colors loses a user's
/// look.
@Suite("Looks and settings format")
struct LooksTests {
    private func decode(_ json: String) throws -> VizprSettings {
        try JSONDecoder().decode(VizprSettings.self, from: Data(json.utf8))
    }

    /// settings.json as written before looks: custom colors and two presets.
    private let legacyJSON = """
    {
      "hotkeyEnabled": false,
      "holdThresholdMs": 350,
      "secondaryModifiers": ["command", "shift"],
      "primaryTrigger": "fn",
      "settleSentences": 3,
      "autoStopSeconds": 12,
      "settleCapMs": 200,
      "draftMinTailMs": 2000,
      "cleanupEnabled": false,
      "codeModeOverride": true,
      "asrModelID": "my-asr",
      "cleanupModelID": "my-cleanup",
      "restoreClipboard": false,
      "invizMode": true,
      "silentInputFallback": false,
      "tintHex": "112233",
      "tintStrength": 0.3,
      "textBaseHex": "FFEEDD",
      "colorsLinked": false,
      "colorPresets": [
        {"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Sunset", "tintHex": "FF8800",
         "tintStrength": 0.2, "textBaseHex": null, "colorsLinked": true},
        {"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E02", "name": "", "tintHex": "00AAFF",
         "tintStrength": 0.1, "colorsLinked": false}
      ]
    }
    """

    @Test("Legacy settings keep every non-appearance field and migrate colors to looks")
    func legacyMigration() throws {
        let settings = try decode(legacyJSON)
        #expect(settings.hotkeyEnabled == false)
        #expect(settings.holdThresholdMs == 350)
        #expect(settings.secondaryModifiers == ["command", "shift"])
        #expect(settings.settleSentences == 3)
        #expect(settings.autoStopSeconds == 12)
        #expect(settings.settleCapMs == 200)
        #expect(settings.draftMinTailMs == 2000)
        #expect(settings.cleanupEnabled == false)
        #expect(settings.codeModeOverride == true)
        #expect(settings.asrModelID == "my-asr")
        #expect(settings.cleanupModelID == "my-cleanup")
        #expect(settings.restoreClipboard == false)
        #expect(settings.invizMode == true)
        #expect(settings.silentInputFallback == false)

        #expect(settings.looks.map(\.name) == ["My colors", "Sunset", "00AAFF"])
        #expect(settings.looks.allSatisfy { $0.surface == .glass })
        let mine = settings.looks[0]
        #expect(mine.tintHex == "112233")
        #expect(mine.tintStrength == 0.3)
        #expect(mine.textBaseHex == "FFEEDD")
        #expect(settings.looks[1].colorsLinked)
        #expect(settings.activeLookID == mine.id)
        #expect(settings.activeLook.name == "My colors")
    }

    @Test("Legacy settings with default colors and no presets migrate to no looks")
    func legacyDefaultsMigrateToNothing() throws {
        let settings = try decode(#"{"tintHex": "A16FDF", "tintStrength": 0.13, "colorsLinked": false}"#)
        #expect(settings.looks.isEmpty)
        #expect(settings.activeLook.id == OverlayLook.glass.id)
    }

    @Test("A file missing many keys keeps the keys it has")
    func missingKeys() throws {
        let settings = try decode(#"{"autoStopSeconds": 30, "invizMode": true, "futureKey": 1}"#)
        #expect(settings.autoStopSeconds == 30)
        #expect(settings.invizMode)
        #expect(settings.holdThresholdMs == VizprSettings.default.holdThresholdMs)
        #expect(settings.secondaryModifiers == VizprSettings.default.secondaryModifiers)
    }

    @Test("A malformed value costs only its own key")
    func malformedValue() throws {
        let settings = try decode(#"{"autoStopSeconds": "soon", "settleSentences": 4}"#)
        #expect(settings.autoStopSeconds == VizprSettings.default.autoStopSeconds)
        #expect(settings.settleSentences == 4)
    }

    @Test("Encode then decode is lossless and writes no legacy keys")
    func roundTrip() throws {
        var settings = VizprSettings.default
        var custom = OverlayLook.slab
        custom.id = UUID()
        custom.name = "Mine"
        custom.fontDesign = .serif
        custom.cornerRadius = 12
        custom.slab.grain = 0.1
        settings.looks = [custom]
        settings.activeLookID = custom.id
        settings.autoStopSeconds = 9

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VizprSettings.self, from: data) == settings)
        let keys = Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        #expect(keys.isDisjoint(with: ["tintHex", "tintStrength", "textBaseHex", "colorsLinked", "colorPresets"]))
    }

    @Test("Clamping bounds every look and slab value")
    func clamping() {
        var look = OverlayLook.glass
        look.id = UUID()
        look.cornerRadius = 500
        look.tintStrength = 9
        look.tintHex = "not hex"
        look.textBaseHex = "zz"
        look.fontSize = 1
        look.slab.meshDrift = 7
        look.slab.meshColorsHex = ["FFFFFF"]
        var settings = VizprSettings.default
        settings.looks = [look]

        let clamped = settings.clamped().looks[0]
        #expect(clamped.cornerRadius == 40)
        #expect(clamped.tintStrength == 0.5)
        #expect(clamped.tintHex == OverlayLook.defaultTintHex)
        #expect(clamped.textBaseHex == nil)
        #expect(clamped.fontSize == 12)
        #expect(clamped.slab.meshDrift == 0.5)
        #expect(clamped.slab.meshColorsHex == SlabStyle.defaultMeshColors)
    }

    @Test("Stored looks cannot shadow a built-in or exceed the cap")
    func lookListInvariants() {
        var settings = VizprSettings.default
        var shadow = OverlayLook.glass
        shadow.name = "Impostor"
        settings.looks = [shadow] + (0..<20).map { _ in
            var look = OverlayLook.glass
            look.id = UUID()
            return look
        }
        let clamped = settings.clamped()
        #expect(clamped.looks.count == VizprSettings.maxLooks)
        #expect(!clamped.looks.contains { $0.isBuiltIn })
    }

    @Test("A dangling active look id resolves to Glass")
    func danglingActiveLook() {
        var settings = VizprSettings.default
        settings.activeLookID = UUID()
        #expect(settings.activeLook == OverlayLook.glass)
    }

    @Test("The glass built-in carries exactly the pre-looks overlay defaults")
    func glassMatchesLegacyDefaults() {
        let glass = OverlayLook.glass
        #expect(glass.tintHex == "A16FDF")
        #expect(glass.tintStrength == 0.13)
        #expect(glass.textBaseHex == nil)
        #expect(glass.colorsLinked == false)
        #expect(glass.cornerRadius == 22)
        #expect(glass.fontSize == 16)
        #expect(glass.fontDesign == .rounded)
    }
}
