import Foundation
import Testing
@testable import Vizpr

/// The settings.json format is a seam: a decode that throws silently resets
/// every setting, and a migration that misreads legacy colors loses a user's
/// look.
@Suite("Looks and settings format")
struct LooksTests {
    private func decode(_ json: String) throws -> VizprSettings {
        try VizprSettings.load(from: Data(json.utf8))
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
        #expect(settings.autoStopSeconds == 12)
        #expect(settings.cleanupEnabled == false)
        #expect(settings.codeModeOverride == true)
        #expect(settings.asrModelID == "my-asr")
        #expect(settings.cleanupModelID == "my-cleanup")
        #expect(settings.restoreClipboard == false)
        #expect(settings.invizMode == true)
        #expect(settings.silentInputFallback == false)
        // A file from before the field existed still says "primaryTrigger": "fn".
        #expect(settings.trigger == .fn)

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

    @Test("A file without targetAppDisplay loads with the icon shown; a saved choice survives")
    func missingTargetAppDisplay() throws {
        #expect(try decode(#"{"invizMode": true}"#).targetAppDisplay == .icon)
        #expect(try decode(#"{"targetAppDisplay": "iconAndName"}"#).targetAppDisplay == .iconAndName)
        #expect(try decode(#"{"targetAppDisplay": "off"}"#).targetAppDisplay == .off)
    }

    @Test("A file without overlayAnchors loads with an empty map")
    func missingAnchors() throws {
        #expect(try decode(#"{"invizMode": true}"#).overlayAnchors.isEmpty)
        let saved = try decode(#"{"overlayAnchors": {"display-a": {"x": 0.2, "y": 0.7}}}"#)
        #expect(saved.overlayAnchors == ["display-a": OverlayAnchor(x: 0.2, y: 0.7)])
    }

    @Test("Out-of-range anchors are clamped into 0...1")
    func anchorsClamp() throws {
        let settings = try decode(#"{"overlayAnchors": {"a": {"x": -3, "y": 9}, "b": {"x": 0.4, "y": 0.5}}}"#)
        #expect(settings.overlayAnchors["a"] == OverlayAnchor(x: 0, y: 1))
        #expect(settings.overlayAnchors["b"] == OverlayAnchor(x: 0.4, y: 0.5))
    }

    @Test("A saved look missing a field gets that field's default and keeps the rest")
    func lookMissingField() throws {
        let settings = try decode("""
        {"looks": [{"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Mine",
                    "cornerRadius": 12, "fontDesign": "serif"}]}
        """)
        let look = try #require(settings.looks.first)
        #expect(look.name == "Mine")
        #expect(look.cornerRadius == 12)
        #expect(look.fontDesign == .serif)
        #expect(look.fontSize == OverlayLook.glass.fontSize)
        #expect(look.tintHex == OverlayLook.glass.tintHex)
    }

    @Test("A look with every field decodes the same whatever the merge template holds")
    func templateOnlyFillsMissingFields() throws {
        var look = OverlayLook.slab
        look.id = UUID()
        look.name = "Full"
        look.cornerRadius = 33
        look.tintHex = "123456"
        look.tintStrength = 0.4
        look.textBaseHex = "ABCDEF"
        look.colorsLinked = true
        look.slab.meshLoopSeconds = 12
        look.fontDesign = .serif
        look.fontSize = 20
        look.wordAppearance = .fade
        var settings = VizprSettings.default
        settings.looks = [look]
        let data = try JSONEncoder().encode(settings)

        var other = OverlayLook.mergeTemplate
        other.surface = .glass
        other.cornerRadius = 8
        other.tintHex = "000000"
        other.tintStrength = 0.5
        other.textBaseHex = "FFFFFF"
        other.colorsLinked = false
        other.slab.meshDrift = 0.5
        other.fontDesign = .monospaced
        other.fontSize = 28
        other.wordAppearance = .blurIn

        #expect(try VizprSettings.load(from: data) == settings)
        #expect(try VizprSettings.load(from: data, lookTemplate: other) == settings)
    }

    @Test("A nested slab with only some keys merges with the rest defaulted")
    func partialSlab() throws {
        let settings = try decode("""
        {"looks": [{"id": "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01", "name": "Mine",
                    "surface": "slab", "slab": {"meshLoopSeconds": 12}}]}
        """)
        let slab = try #require(settings.looks.first).slab
        #expect(slab.meshLoopSeconds == 12)
        #expect(slab.meshDrift == SlabStyle.default.meshDrift)
        #expect(slab.meshColorsHex == SlabStyle.defaultMeshColors)
    }

    @Test("Encode then decode is lossless and writes no legacy keys")
    func roundTrip() throws {
        var settings = VizprSettings.default
        var custom = OverlayLook.slab
        custom.id = UUID()
        custom.name = "Mine"
        custom.fontDesign = .serif
        custom.cornerRadius = 12
        custom.slab.meshLoopSeconds = 12
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

    @Test("A round trip preserves every field, none of them left at its default")
    func everyFieldRoundTrips() throws {
        var settings = VizprSettings()
        settings.hotkeyEnabled = false
        settings.holdThresholdMs = 410
        settings.secondaryModifiers = ["command", "shift", "option"]
        settings.trigger = HotkeyTrigger(keyCode: 105, modifiers: ["control"])   // F13
        settings.autoStopSeconds = 17
        settings.cleanupEnabled = false
        settings.codeModeOverride = true
        settings.asrModelID = "asr-x"
        settings.cleanupModelID = "cleanup-x"
        settings.restoreClipboard = false
        settings.invizMode = true
        settings.targetAppDisplay = .iconAndName
        settings.silentInputFallback = false
        settings.overlayAnchors = ["display-a": OverlayAnchor(x: 0.3, y: 0.6)]
        var look = OverlayLook.slab
        look.id = UUID()
        look.name = "Everything"
        look.cornerRadius = 31
        look.tintHex = "123456"
        look.tintStrength = 0.4
        look.colorsLinked = true
        look.fontDesign = .monospaced
        look.fontSize = 21
        look.wordAppearance = .blurIn
        settings.looks = [look]
        settings.activeLookID = look.id

        // Fails when a new field is added to VizprSettings but not set above.
        let defaults = Mirror(reflecting: VizprSettings.default).children
        for (field, base) in zip(Mirror(reflecting: settings).children, defaults) {
            #expect(String(describing: field.value) != String(describing: base.value),
                    "\(field.label ?? "?") is still at its default")
        }

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VizprSettings.self, from: data) == settings.clamped())
        #expect(settings.clamped() == settings)
    }
}

@Suite("SettingsMerge")
struct SettingsMergeTests {
    private func merge(
        _ saved: [String: Any], over defaults: [String: Any],
        elements: [String: [String: Any]] = [:]
    ) -> [String: Any] {
        SettingsMerge.merged(saved: saved, over: defaults, elementDefaults: elements)
    }

    private func same(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: left).isEqual(to: right)
    }

    @Test("Keys only in the defaults stay, and keys only in the saved file pass through")
    func unionOfKeys() {
        let result = merge(["saved": 1, "both": 2], over: ["both": 0, "default": 3])
        #expect(same(result, ["saved": 1, "both": 2, "default": 3]))
    }

    @Test("Dictionaries on both sides merge recursively")
    func recursion() {
        let result = merge(["slab": ["grain": 0.1]], over: ["slab": ["grain": 0.0, "bevel": 0.5]])
        #expect(same(result, ["slab": ["grain": 0.1, "bevel": 0.5]]))
    }

    @Test("An array replaces the default array when its key has no element template")
    func arrayReplacement() {
        let result = merge(["mods": ["a"]], over: ["mods": ["x", "y"]])
        #expect(same(result, ["mods": ["a"]]))
    }

    @Test("Each saved array element merges over its key's element template")
    func elementDefaults() {
        let result = merge(
            ["looks": [["name": "One"], ["name": "Two", "size": 9]]],
            over: ["looks": [[String: Any]]()],
            elements: ["looks": ["name": "?", "size": 16, "nested": ["a": 1, "b": 2]]]
        )
        #expect(same(result, ["looks": [
            ["name": "One", "size": 16, "nested": ["a": 1, "b": 2]],
            ["name": "Two", "size": 9, "nested": ["a": 1, "b": 2]]
        ]]))
    }

    @Test("A saved value of a different shape replaces the default")
    func shapeMismatch() {
        let result = merge(["slab": "none"], over: ["slab": ["grain": 0.0]])
        #expect(same(result, ["slab": "none"]))
    }
}

@MainActor
@Suite("SettingsStore loading")
struct SettingsStoreLoadingTests {
    private func tempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("A file that fails to decode is kept as settings.json.bad, replacing an older copy")
    func unreadableFileIsBackedUp() throws {
        let url = try tempFile("{ not json")
        let backup = url.appendingPathExtension("bad")
        try Data("older".utf8).write(to: backup)

        let store = SettingsStore(fileURL: url)
        #expect(store.settings == .default)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")

        store.update { $0.autoStopSeconds = 9 }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test("A wrong-typed value loads defaults and keeps the file as settings.json.bad")
    func wrongTypedValueIsBackedUp() throws {
        let json = #"{"autoStopSeconds": "soon", "settleSentences": 4}"#
        let url = try tempFile(json)
        let store = SettingsStore(fileURL: url)
        #expect(store.settings == .default)
        #expect(try String(contentsOf: url.appendingPathExtension("bad"), encoding: .utf8) == json)
    }

    @Test("Loading a legacy file saves the migrated looks once, with stable ids and no legacy keys")
    func migrationIsPersisted() throws {
        let url = try tempFile(
            #"{"tintHex": "112233", "colorPresets": [{"name": "Sunset", "tintHex": "FF8800"}]}"#
        )
        let first = SettingsStore(fileURL: url).settings
        #expect(first.looks.map(\.name) == ["My colors", "Sunset"])

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["tintHex"] == nil && object["colorPresets"] == nil)
        #expect(SettingsStore(fileURL: url).settings == first)
    }

    @Test("Loading a file with removed keys drops them from the file and keeps the rest")
    func removedKeysAreShed() throws {
        let lookID = "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01"
        let url = try tempFile("""
        {"settleCapMs": 500, "settleSentences": 4, "autoStopSeconds": 3,
         "primaryTrigger": "fn",
         "looks": [{"id": "\(lookID)", "name": "Mine", "cornerRadius": 12}]}
        """)
        let first = SettingsStore(fileURL: url).settings

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["settleCapMs"] == nil)
        #expect(object["draftMinTailMs"] == nil)
        #expect(object["settleSentences"] == nil)
        #expect(object["primaryTrigger"] == nil)
        #expect(object["autoStopSeconds"] as? Int == 3)
        let looks = try #require(object["looks"] as? [[String: Any]])
        #expect(looks.map { $0["id"] as? String } == [lookID])
        #expect(first.autoStopSeconds == 3)
        #expect(SettingsStore(fileURL: url).settings == first)
    }

    @Test("A saved trigger loads and survives a save and reload")
    func triggerRoundTripsThroughTheFile() throws {
        let url = try tempFile(#"{"trigger": {"keyCode": 61, "modifiers": []}, "autoStopSeconds": 9}"#)
        let store = SettingsStore(fileURL: url)
        #expect(store.settings.trigger == HotkeyTrigger(keyCode: 61, modifiers: []))
        store.update { $0.trigger = HotkeyTrigger(keyCode: 2, modifiers: ["shift", "command"]) }
        let reloaded = SettingsStore(fileURL: url).settings
        #expect(reloaded.trigger == HotkeyTrigger(keyCode: 2, modifiers: ["command", "shift"]))
        #expect(reloaded.autoStopSeconds == 9)
    }

    @Test("A malformed trigger becomes Fn and never costs the rest of the file")
    func malformedTriggerFallsBackToFn() throws {
        for trigger in [
            #""fn""#,
            #"{"keyCode": "61", "modifiers": []}"#,
            #"{"keyCode": 70000, "modifiers": []}"#,
            #"{"keyCode": -1, "modifiers": []}"#,
            #"{"keyCode": 61, "modifiers": "option"}"#,
            #"{"keyCode": 300, "modifiers": []}"#,
            #"{"keyCode": 57, "modifiers": []}"#,
            #"{"keyCode": 53, "modifiers": []}"#,
            #"{"keyCode": 61, "modifiers": ["hyper"]}"#,
            #"{"keyCode": 61, "modifiers": ["option"]}"#,
            #"{"keyCode": 63, "modifiers": ["shift"]}"#,
            #"{"keyCode": 2, "modifiers": ["option", "control", "shift"]}"#
        ] {
            let json = #"{"holdThresholdMs": 410, "trigger": \#(trigger)}"#
            let settings = try VizprSettings.load(from: Data(json.utf8))
            #expect(settings.trigger == .fn, "trigger \(trigger) should fall back to Fn")
            #expect(settings.holdThresholdMs == 410, "trigger \(trigger) must not cost the rest of the file")
        }
    }

    @Test("A trigger's modifiers are sorted and deduplicated, and a chord edit cannot orphan it")
    func triggerClampingIsStable() {
        var settings = VizprSettings()
        settings.trigger = HotkeyTrigger(keyCode: 2, modifiers: ["shift", "command", "shift"])
        #expect(settings.clamped().trigger == HotkeyTrigger(keyCode: 2, modifiers: ["command", "shift"]))
        // The default chord is control + option: a trigger holding both is refused.
        settings.trigger = HotkeyTrigger(keyCode: 2, modifiers: ["option", "control"])
        #expect(settings.clamped().trigger == .fn)
        // Right Option as a bare trigger coexists with Option in the chord.
        settings.trigger = HotkeyTrigger(keyCode: 61, modifiers: [])
        #expect(settings.clamped().trigger == settings.trigger)
    }

    @Test("A readable file is not rewritten or backed up on load")
    func readableFileUntouched() throws {
        let url = try tempFile(#"{"autoStopSeconds": 30}"#)
        _ = SettingsStore(fileURL: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"autoStopSeconds": 30}"#)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }
}
