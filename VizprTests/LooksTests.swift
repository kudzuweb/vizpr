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

    @Test("Encode then decode is lossless, writes no legacy keys and leaves the looks to their files")
    func roundTrip() throws {
        var settings = VizprSettings.default
        var custom = OverlayLook.slab
        custom.id = UUID()
        custom.name = "Mine"
        settings.looks = [custom]
        settings.activeLookID = custom.id
        settings.autoStopSeconds = 9

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VizprSettings.self, from: data) == settings.withoutLooks)
        let keys = Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        #expect(keys.isDisjoint(with: ["tintHex", "tintStrength", "textBaseHex", "colorsLinked", "colorPresets"]))
        #expect(!keys.contains("looks"))
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
        // primaryTrigger only accepts "fn" today, so it cannot leave its default.
        for (field, base) in zip(Mirror(reflecting: settings).children, defaults)
        where field.label != "primaryTrigger" {
            #expect(String(describing: field.value) != String(describing: base.value),
                    "\(field.label ?? "?") is still at its default")
        }

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(VizprSettings.self, from: data) == settings.clamped().withoutLooks)
        #expect(settings.clamped() == settings)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("looks"), "looks are stored as files, never in settings.json")
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

        let store = SettingsStore(fileURL: url, looksFolder: try LookFixtures.folder())
        #expect(store.settings == .default)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")

        store.update { $0.autoStopSeconds = 9 }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test("A wrong-typed value loads defaults and keeps the file as settings.json.bad")
    func wrongTypedValueIsBackedUp() throws {
        let json = #"{"autoStopSeconds": "soon", "settleSentences": 4}"#
        let url = try tempFile(json)
        let store = SettingsStore(fileURL: url, looksFolder: try LookFixtures.folder())
        #expect(store.settings == .default)
        #expect(try String(contentsOf: url.appendingPathExtension("bad"), encoding: .utf8) == json)
    }

    @Test("Loading a legacy file writes the migrated looks as files once, with stable ids and no legacy keys")
    func migrationIsPersisted() throws {
        let url = try tempFile(
            #"{"tintHex": "112233", "colorPresets": [{"name": "Sunset", "tintHex": "FF8800"}]}"#
        )
        let folder = try LookFixtures.folder()
        let first = SettingsStore(fileURL: url, looksFolder: folder).settings
        #expect(first.looks.map(\.name) == ["My colors", "Sunset"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            == ["my-colors.json", "sunset.json"])

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["tintHex"] == nil && object["colorPresets"] == nil)
        #expect(object["looks"] == nil)
        let second = SettingsStore(fileURL: url, looksFolder: folder).settings
        #expect(second == first)
        #expect(second.looks.map(\.id) == first.looks.map(\.id))
    }

    @Test("Loading a file with removed keys drops them from the file and keeps the rest")
    func removedKeysAreShed() throws {
        let lookID = LookFixtures.idA
        let url = try tempFile("""
        {"settleCapMs": 500, "draftMinTailMs": 1500, "settleSentences": 4, "autoStopSeconds": 3,
         "looks": [{"id": "\(lookID)", "name": "Mine", "cornerRadius": 12}]}
        """)
        let folder = try LookFixtures.folder()
        let first = SettingsStore(fileURL: url, looksFolder: folder).settings

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["settleCapMs"] == nil)
        #expect(object["draftMinTailMs"] == nil)
        #expect(object["settleSentences"] == nil)
        #expect(object["autoStopSeconds"] as? Int == 3)
        #expect(object["looks"] == nil, "the migrated looks leave settings.json")
        #expect(first.looks.map { $0.id.uuidString } == [lookID])
        #expect(first.autoStopSeconds == 3)
        #expect(SettingsStore(fileURL: url, looksFolder: folder).settings == first)
    }

    @Test("A readable file is not rewritten or backed up on load")
    func readableFileUntouched() throws {
        let url = try tempFile(#"{"autoStopSeconds": 30}"#)
        _ = SettingsStore(fileURL: url, looksFolder: try LookFixtures.folder())
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"autoStopSeconds": 30}"#)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }
}
