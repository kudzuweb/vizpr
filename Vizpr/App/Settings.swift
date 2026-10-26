import Combine
import Foundation

/// User settings (PLAN.md §14 + PR 11). One JSON doc (§15: JSON for mutable
/// config), every field applied LIVE — no relaunch for any setting.
///
/// INVARIANT GUARD (PR 11 acceptance): nothing representable here can enable
/// network access, weaken secure-input suppression, or write transcripts in
/// Release. This is structural: there simply are no such fields, and decode
/// clamps every numeric to its safe range so a hand-edited file can't smuggle
/// a pathological value in.
struct VizprSettings: Codable, Equatable, Sendable {
    // MARK: Hotkey
    /// Master switch: disable to release the event tap entirely (Fn behaves
    /// stock, nothing listens).
    var hotkeyEnabled: Bool = true
    /// Tap vs hold boundary, milliseconds (field-tuned default from PR 3).
    var holdThresholdMs: Int = 280
    /// Secondary chord modifiers (ordered set of: control, option, shift,
    /// command). At least two — a single bare modifier would collide with
    /// normal typing.
    var secondaryModifiers: [String] = ["control", "option"]
    /// RESERVED for trigger reassignment (Mauria: "maybe other people want
    /// other button. especially vim guys"). Only "fn" is valid today — the
    /// fail-open state machine is written around Fn's flagsChanged behavior
    /// and gets parameterized deliberately, with its own property-test pass
    /// (see NOTES.md "Trigger reassignment"). Reserving the field now keeps
    /// the on-disk format stable when that lands.
    var primaryTrigger: String = "fn"

    static let validModifiers: Set<String> = ["control", "option", "shift", "command"]

    // MARK: Session behavior
    /// Auto-stop after this much silence, seconds.
    var autoStopSeconds: Int = 6
    /// Tail-settle cap at commit, milliseconds (§15 amendment). The commit waits
    /// for one decode of the unconfirmed tail (up to 15 s of audio), and a cap
    /// below the decode time commits the last draft and drops the decode.
    /// Rule: 2 x p90(15 s decode) + 100 ms, rounded up to 50 ms, clamped to
    /// 350...1000 — the factor of 2 covers a draft decode still running when
    /// the input ends plus the commit decode queued behind it. Measured
    /// 2026-10-25 on the bundled model: p90 of 180.6 ms over 10 runs gives 500.
    var settleCapMs: Int = 500
    /// Draft track minimum tail before the first decode, milliseconds —
    /// Mauria's "first draft faster?" lever; lower = earlier + junkier.
    var draftMinTailMs: Int = 1500

    // MARK: Cleanup
    var cleanupEnabled: Bool = true
    var codeModeOverride: Bool = false

    // MARK: Models (PR 11 Models pane)
    /// Selected user model ids; nil = the bundled model. An id that no longer
    /// resolves to a usable folder fails SOFT to bundled at engine build —
    /// selection can never leave the app without a model. Model loading stays
    /// local-only regardless of value (the registry never downloads).
    var asrModelID: String?
    var cleanupModelID: String?

    // MARK: Injection
    /// ON: original clipboard restored after paste. OFF: transcript stays on
    /// the clipboard (Mauria, PR 8 field request).
    var restoreClipboard: Bool = true

    /// Inviz mode (Mauria): no live transcript preview — just a small
    /// "talking is happening" indicator mid-screen; text appears finalized
    /// in place at commit. An explicit opt-out of proofread-as-you-speak;
    /// the pipeline underneath is unchanged.
    var invizMode: Bool = false
    /// Whether the overlay shows the frontmost app, so you can see where the
    /// text will land. A global behavior, not part of a look.
    var targetAppDisplay: TargetAppDisplay = .icon
    /// Fall back to the built-in mic when the selected input delivers pure
    /// silence (the AirPods-on-a-phone-call trap; default on).
    var silentInputFallback: Bool = true

    // MARK: Appearance (PR 14 looks)
    /// The user's own looks, at most `maxLooks`. The built-ins are not stored.
    var looks: [OverlayLook] = []
    /// The look the overlay renders. An id that matches nothing resolves to
    /// Glass (see `activeLook`).
    var activeLookID: UUID = OverlayLook.glass.id

    // MARK: Overlay position
    /// Where the user dragged the overlay, per display. The key is the
    /// display's UUID (`NSScreen.displayUUID`); an absent key is the default
    /// lower-center.
    var overlayAnchors: [String: OverlayAnchor] = [:]

    /// The locked settled:mutable opacity ratio (not persisted, not a
    /// setting — the trust contract's floor).
    static let mutableOpacityRatio = 0.55
    static let maxLooks = 12

    static let `default` = VizprSettings()

    /// Clamp every numeric into its safe range (decode-time guard).
    func clamped() -> VizprSettings {
        var s = self
        s.holdThresholdMs = min(max(s.holdThresholdMs, 100), 1_000)
        s.secondaryModifiers = s.secondaryModifiers.filter { Self.validModifiers.contains($0) }
        if s.secondaryModifiers.count < 2 { s.secondaryModifiers = ["control", "option"] }
        if s.primaryTrigger != "fn" { s.primaryTrigger = "fn" }   // only Fn yet
        if s.asrModelID?.isEmpty == true { s.asrModelID = nil }
        if s.cleanupModelID?.isEmpty == true { s.cleanupModelID = nil }
        s.autoStopSeconds = min(max(s.autoStopSeconds, 2), 60)
        s.settleCapMs = min(max(s.settleCapMs, 0), 1_000)
        s.draftMinTailMs = min(max(s.draftMinTailMs, 500), 4_000)
        s.overlayAnchors = s.overlayAnchors.mapValues { $0.clamped() }
        // Built-ins are read-only constants, so a stored look may not shadow
        // one, and ids must be unique for selection to be unambiguous.
        var seen = Set(OverlayLook.builtIns.map(\.id))
        s.looks = Array(s.looks.filter { seen.insert($0.id).inserted }.prefix(Self.maxLooks))
            .map { $0.clamped() }
        return s
    }

    /// The active look; a dangling id resolves to Glass so the overlay can
    /// always render.
    var activeLook: OverlayLook {
        (OverlayLook.builtIns + looks).first { $0.id == activeLookID } ?? .glass
    }

    static func sanitizeHex(_ hex: String) -> String? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "").uppercased()
        guard cleaned.count == 6, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        return cleaned
    }
}

/// Load/save + live change notification. Settings live next to the vocab
/// store in Application Support.
@MainActor
final class SettingsStore: ObservableObject {
    private let fileURL: URL
    @Published private(set) var settings: VizprSettings
    /// Observers invoked on every successful save (live application).
    private var observers: [(VizprSettings) -> Void] = []

    init(fileURL: URL? = nil) {
        let url = fileURL ?? StorageRoot.url.appendingPathComponent("settings.json")
        self.fileURL = url
        settings = .default
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            settings = try VizprSettings.load(from: data)
            // Rewrite once so migrated looks keep their ids and the legacy
            // keys leave the file.
            if VizprSettings.hasLegacyKeys(data) { persist() }
        } catch {
            keepUnreadableFile(at: url)
        }
    }

    /// A settings file that fails to decode is copied to `settings.json.bad`
    /// (replacing an earlier copy) before defaults take over, so the next save
    /// cannot destroy it.
    private func keepUnreadableFile(at url: URL) {
        let backup = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    func onChange(_ observer: @escaping (VizprSettings) -> Void) {
        observers.append(observer)
    }

    /// Reset every setting to its default. The user's looks SURVIVE a reset
    /// (Mauria: deleting them is a separate, deliberate act); the active look
    /// returns to Glass.
    func resetAll() {
        update {
            let looks = $0.looks
            $0 = .default
            $0.looks = looks
        }
    }

    func deleteAllLooks() {
        update {
            $0.looks = []
            $0.activeLookID = OverlayLook.glass.id
        }
    }

    /// Puts the overlay back at lower-center on every display.
    func resetOverlayPositions() {
        update { $0.overlayAnchors = [:] }
    }

    func selectLook(_ id: UUID) {
        update { $0.activeLookID = id }
    }

    /// Copies a look under "<name> copy" and makes the copy active. No-op at
    /// the `maxLooks` cap.
    func duplicateLook(_ look: OverlayLook) {
        update {
            guard $0.looks.count < VizprSettings.maxLooks else { return }
            var copy = look
            copy.id = UUID()
            copy.name = "\(look.name) copy"
            $0.looks.append(copy)
            $0.activeLookID = copy.id
        }
    }

    /// Deletes a user look; deleting the active one falls back to Glass.
    func deleteLook(_ id: UUID) {
        update {
            $0.looks.removeAll { $0.id == id }
            if $0.activeLookID == id { $0.activeLookID = OverlayLook.glass.id }
        }
    }

    /// Edits the active look in place. Built-ins are read-only, so this is a
    /// no-op while one is active.
    func updateActiveLook(_ mutate: (inout OverlayLook) -> Void) {
        update {
            let activeID = $0.activeLookID
            guard let index = $0.looks.firstIndex(where: { $0.id == activeID }) else { return }
            mutate(&$0.looks[index])
        }
    }

    /// Menu-bar cycle: built-ins, then user looks, wrapping around.
    @discardableResult
    func cycleLook() -> OverlayLook {
        let all = OverlayLook.builtIns + settings.looks
        let current = all.firstIndex { $0.id == settings.activeLookID } ?? 0
        let next = all[(current + 1) % all.count]
        selectLook(next.id)
        return next
    }

    func update(_ mutate: (inout VizprSettings) -> Void) {
        var next = settings
        mutate(&next)
        next = next.clamped()
        guard next != settings else { return }
        settings = next
        persist()
        for observer in observers { observer(next) }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            // Settings failing to persist must never take dictation down;
            // the in-memory value still applied.
        }
    }
}

// MARK: - Loading

extension VizprSettings {
    /// Parses a saved settings file: the JSON is merged over the encoded
    /// defaults (see `SettingsMerge`), decoded, clamped, and then any
    /// pre-looks color keys are migrated to looks. Throws when the file is not
    /// a JSON object or a value has the wrong type.
    static func load(from data: Data, lookTemplate: OverlayLook = .mergeTemplate) throws -> VizprSettings {
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Settings file is not a JSON object")
            )
        }
        let merged = SettingsMerge.merged(
            saved: saved,
            over: try jsonObject(of: VizprSettings.default),
            elementDefaults: ["looks": try jsonObject(of: lookTemplate)]
        )
        var settings = try JSONDecoder().decode(
            VizprSettings.self, from: JSONSerialization.data(withJSONObject: merged)
        )
        // A file written before looks existed has no `looks` key.
        if saved["looks"] == nil {
            let legacy = try JSONDecoder().decode(LegacyAppearance.self, from: data)
            settings.migrate(legacy, keepsActiveLook: saved["activeLookID"] != nil)
        }
        return settings.clamped()
    }

    private static func jsonObject(of value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// True when `data` is a settings object still carrying pre-looks color
    /// keys, so the store knows to save the migrated form.
    static func hasLegacyKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return LegacyAppearance.keys.contains { object[$0] != nil }
    }

    /// The pre-looks appearance keys, as they were saved.
    private struct LegacyAppearance: Decodable {
        struct Preset: Decodable {
            var name: String?
            var tintHex: String?
            var tintStrength: Double?
            var textBaseHex: String?
            var colorsLinked: Bool?
        }

        static let keys = ["tintHex", "tintStrength", "textBaseHex", "colorsLinked", "colorPresets"]

        var tintHex: String?
        var tintStrength: Double?
        var textBaseHex: String?
        var colorsLinked: Bool?
        var colorPresets: [Preset]?
    }

    /// Stable id for the look migrated from the top-level colors.
    private static let migratedColorsID = UUID(uuidString: "6B1E5A4C-0D2F-4C8E-9A57-3F1B7D20A0FF")!

    /// Legacy top-level colors that differ from the old defaults become a
    /// glass look named "My colors" (made active); each legacy preset becomes
    /// a glass look of its own.
    private mutating func migrate(_ legacy: LegacyAppearance, keepsActiveLook: Bool) {
        let glass = OverlayLook.glass
        var migrated: [OverlayLook] = []

        let tintHex = legacy.tintHex ?? glass.tintHex
        let tintStrength = legacy.tintStrength ?? glass.tintStrength
        let colorsLinked = legacy.colorsLinked ?? glass.colorsLinked
        let customized = VizprSettings.sanitizeHex(tintHex) != glass.tintHex
            || abs(tintStrength - glass.tintStrength) > 1e-9
            || legacy.textBaseHex != nil
            || colorsLinked
        if customized {
            var mine = glass
            mine.id = Self.migratedColorsID
            mine.name = "My colors"
            mine.tintHex = tintHex
            mine.tintStrength = tintStrength
            mine.textBaseHex = legacy.textBaseHex
            mine.colorsLinked = colorsLinked
            migrated.append(mine)
        }

        for preset in legacy.colorPresets ?? [] {
            var look = glass
            look.id = UUID()
            look.tintHex = preset.tintHex ?? glass.tintHex
            look.tintStrength = preset.tintStrength ?? glass.tintStrength
            look.textBaseHex = preset.textBaseHex
            look.colorsLinked = preset.colorsLinked ?? glass.colorsLinked
            look.name = (preset.name?.isEmpty ?? true) ? look.tintHex : preset.name!
            migrated.append(look)
        }

        looks = migrated
        if customized, !keepsActiveLook { activeLookID = Self.migratedColorsID }
    }
}
