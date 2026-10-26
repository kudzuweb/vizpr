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
    /// The key that starts and stops dictation: Fn by default, or any other
    /// key or key-and-modifiers combination (see NOTES.md "Trigger
    /// reassignment"). Its own events are consumed system-wide, so a value
    /// that cannot work is reset to Fn by `clamped()`.
    var trigger: HotkeyTrigger = .fn

    static let validModifiers = Set(HotkeyTrigger.familyFlags.keys)

    // MARK: Session behavior
    /// Auto-stop after this much silence, seconds.
    var autoStopSeconds: Int = 6

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
    /// The user's own looks, at most `maxLooks`, in file-name order. They live
    /// as files in the Looks folder (`LookFiles`), so this property is left out
    /// of `CodingKeys` and never reaches `settings.json`. The built-ins are not
    /// stored.
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

    /// Every stored property except `looks`, which is kept in files.
    private enum CodingKeys: String, CodingKey {
        case hotkeyEnabled, holdThresholdMs, secondaryModifiers, primaryTrigger
        case autoStopSeconds, cleanupEnabled, codeModeOverride
        case asrModelID, cleanupModelID, restoreClipboard
        case invizMode, targetAppDisplay, silentInputFallback
        case activeLookID, overlayAnchors
    }

    /// The settings that `settings.json` holds.
    var withoutLooks: VizprSettings {
        var copy = self
        copy.looks = []
        return copy
    }

    /// Valid ranges, shared by `clamped()` and the Behavior pane's sliders.
    static let holdThresholdRangeMs = 100...1_000
    static let autoStopRangeSeconds = 2...60

    /// Clamp every numeric into its safe range (decode-time guard).
    func clamped() -> VizprSettings {
        var s = self
        s.holdThresholdMs = min(max(s.holdThresholdMs, Self.holdThresholdRangeMs.lowerBound),
                               Self.holdThresholdRangeMs.upperBound)
        s.secondaryModifiers = s.secondaryModifiers.filter { Self.validModifiers.contains($0) }
        if s.secondaryModifiers.count < 2 { s.secondaryModifiers = Self.default.secondaryModifiers }
        s.trigger = s.trigger.clamped(secondaryModifiers: s.secondaryModifiers)
        if s.asrModelID?.isEmpty == true { s.asrModelID = nil }
        if s.cleanupModelID?.isEmpty == true { s.cleanupModelID = nil }
        s.autoStopSeconds = min(max(s.autoStopSeconds, Self.autoStopRangeSeconds.lowerBound),
                                Self.autoStopRangeSeconds.upperBound)
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
/// store in Application Support; the user's looks live as files in the Looks
/// folder (`LookFiles`).
///
/// Every look edit goes through `update`, which is the one place that writes
/// and deletes look files; it never renames one. No editor calls `LookFiles`
/// itself.
@MainActor
final class SettingsStore: ObservableObject {
    private let fileURL: URL
    private let looksFolder: URL
    private let discardLookFile: (URL) throws -> Void
    @Published private(set) var settings: VizprSettings
    /// Look files that were not loaded or not saved, from the latest load or
    /// save. Set by the launch load too, so a broken file shows without a
    /// manual reload.
    @Published private(set) var lookFileFailures: [LookFiles.Failure] = []
    /// Set while looks could not be moved out of `settings.json`, which keeps
    /// them until the move succeeds.
    @Published private(set) var lookMigrationProblem: String?
    /// Observers invoked on every successful save (live application).
    private var observers: [(VizprSettings) -> Void] = []
    /// The file each loaded look came from. Only these files are ever deleted.
    private var lookURLs: [UUID: URL] = [:]
    /// Entries of `settings.json` that are written back verbatim by every save
    /// until their looks are verified in the Looks folder: the raw `looks`
    /// array, or the pre-looks color keys.
    private var carriedEntries: [String: Any] = [:]
    /// Looks that are still only in `settings.json`; shown in the list so a
    /// failed migration changes nothing for the user.
    private var unmigratedLooks: [OverlayLook] = []

    /// - Parameters:
    ///   - looksFolder: where look files live; tests pass a temp folder.
    ///   - discardLookFile: removes a look file; the default moves it to the
    ///     Trash so a deletion can be undone.
    init(
        fileURL: URL? = nil,
        looksFolder: URL? = nil,
        discardLookFile: @escaping (URL) throws -> Void = LookFiles.delete(at:)
    ) {
        let url = fileURL ?? StorageRoot.url.appendingPathComponent("settings.json")
        self.fileURL = url
        self.looksFolder = looksFolder ?? LookFiles.folder
        self.discardLookFile = discardLookFile
        settings = .default

        // 1. Parse and decode settings.json.
        var rewriteNeeded = false
        var pending: [[String: Any]] = []
        var backup: (url: URL, data: Data)?
        if let data = try? Data(contentsOf: url) {
            do {
                var loaded = try VizprSettings.load(from: data)
                let legacyLooks = loaded.looks
                loaded.looks = []
                settings = loaded
                rewriteNeeded = VizprSettings.hasStaleKeys(data)
                (pending, backup) = collectPendingLooks(
                    data: data, url: url, legacyLooks: legacyLooks
                )
            } catch {
                keepUnreadableFile(at: url)
            }
        }

        // 2-3. Move pending looks into the folder. Nothing is persisted yet,
        // so a failure leaves settings.json exactly as it was read.
        var migrated = false
        if !pending.isEmpty {
            let outcome = LookMigration.run(pending, backingUp: backup, into: self.looksFolder)
            if outcome.completed {
                carriedEntries = [:]
                migrated = true
            } else {
                lookMigrationProblem = outcome.problem
                LookFiles.logLine("migration stopped, looks stay in settings.json: \(outcome.problem ?? "")")
                unmigratedLooks = pending.compactMap { try? LookFiles.decode($0) }
            }
        }

        // 4. Set the looks from the folder, then the single rewrite that
        // drops the migrated entries and any stale keys.
        applyLookFolder()
        if migrated || rewriteNeeded { persist() }
    }

    /// The looks `settings.json` still holds that must move to the folder,
    /// and the entries to carry until they have. A `looks` value of the wrong
    /// shape is carried too and never dropped.
    private func collectPendingLooks(
        data: Data, url: URL, legacyLooks: [OverlayLook]
    ) -> ([[String: Any]], (url: URL, data: Data)?) {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let raw = object["looks"] {
            if let elements = raw as? [[String: Any]] {
                guard !elements.isEmpty else { return ([], nil) }
                carriedEntries = ["looks": raw]
                return (elements, (url, data))
            }
            if (raw as? [Any])?.isEmpty != true {
                carriedEntries = ["looks": raw]
                lookMigrationProblem = "the looks entry in settings.json is not a list of looks, so it was left as it is"
            }
            return ([], nil)
        }
        guard !legacyLooks.isEmpty else { return ([], nil) }
        carriedEntries = VizprSettings.legacyEntries(in: object)
        let elements = legacyLooks.compactMap { try? LookFiles.encodedObject(of: $0) }
        return (elements, nil)
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

    // MARK: Look files

    /// Replaces the looks with what the Looks folder holds now, then tells the
    /// observers if anything changed. Does not write any file.
    func reloadLooks() {
        let before = settings
        applyLookFolder()
        guard settings != before else { return }
        for observer in observers { observer(settings) }
    }

    /// Creates the Looks folder if needed so it can be opened in Finder.
    func looksFolderForOpening() -> URL {
        try? FileManager.default.createDirectory(at: looksFolder, withIntermediateDirectories: true)
        return looksFolder
    }

    private func applyLookFolder() {
        let report = LookFiles.load(from: looksFolder)
        lookURLs = report.urls
        lookFileFailures = report.failures
        var next = settings
        next.looks = report.looks + unmigratedLooks.filter { look in !report.looks.contains { $0.id == look.id } }
        settings = next.clamped()
    }

    /// Writes each added or changed look, deletes each removed one, and returns
    /// `new` in file-name order, so the list matches what a reload would give.
    private func syncLookFiles(from old: [OverlayLook], to new: [OverlayLook]) -> [OverlayLook] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        for removed in old where !newIDs.contains(removed.id) {
            guard let url = lookURLs[removed.id] else { continue }
            do {
                try discardLookFile(url)
                lookURLs[removed.id] = nil
            } catch {
                recordLookFileFailure(url, .notDeleted, "could not be deleted: \(error.localizedDescription)")
            }
        }
        for look in new where oldByID[look.id] != look {
            do {
                lookURLs[look.id] = try LookFiles.write(look, in: looksFolder, at: lookURLs[look.id])
            } catch {
                recordLookFileFailure(lookURLs[look.id] ?? looksFolder, .notSaved, "could not be saved: \(error.localizedDescription)")
            }
        }
        return new.enumerated().sorted { left, right in
            switch (lookURLs[left.element.id], lookURLs[right.element.id]) {
            case let (a?, b?): a == b ? left.offset < right.offset : LookFiles.sortsBefore(a, b)
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): left.offset < right.offset
            }
        }.map(\.element)
    }

    private func recordLookFileFailure(_ url: URL, _ kind: LookFiles.Failure.Kind, _ reason: String) {
        LookFiles.logLine("\(url.lastPathComponent) \(reason)")
        let failure = LookFiles.Failure(url: url, kind: kind, reason: reason)
        if !lookFileFailures.contains(failure) { lookFileFailures.append(failure) }
    }

    // MARK: Changes

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
        next.looks = syncLookFiles(from: settings.looks, to: next.looks)
        // A look-only change leaves settings.json alone.
        let settingsFileChanged = next.withoutLooks != settings.withoutLooks
        settings = next
        if settingsFileChanged { persist() }
        for observer in observers { observer(next) }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encodedSettings().write(to: fileURL, options: .atomic)
        } catch {
            // Settings failing to persist must never take dictation down;
            // the in-memory value still applied.
        }
    }

    /// The settings as JSON, with the carried entries written back as they
    /// were read.
    private func encodedSettings() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard !carriedEntries.isEmpty else { return data }
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        object.merge(carriedEntries) { _, carried in carried }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Loading

extension VizprSettings {
    /// Parses a saved settings file: the JSON is merged over the encoded
    /// defaults (see `SettingsMerge`), decoded and clamped. A file written
    /// before looks existed (no `looks` key, at least one pre-looks color key)
    /// also has its colors migrated: the result's `looks` then holds the looks
    /// they became, which the caller writes as look files. Any other `looks`
    /// entry in the file is not decoded here (see `LookMigration`). Throws when
    /// the file is not a JSON object or a value has the wrong type.
    static func load(from data: Data) throws -> VizprSettings {
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Settings file is not a JSON object")
            )
        }
        let merged = SettingsMerge.merged(
            saved: saved,
            over: try LookFiles.encodedObject(of: VizprSettings.default),
            elementDefaults: [:]
        )
        var settings = try JSONDecoder().decode(
            VizprSettings.self, from: JSONSerialization.data(withJSONObject: merged)
        )
        if saved["looks"] == nil, !legacyEntries(in: saved).isEmpty {
            let legacy = try JSONDecoder().decode(LegacyAppearance.self, from: data)
            settings.migrate(legacy, keepsActiveLook: saved["activeLookID"] != nil)
        }
        return settings.clamped()
    }

    /// The pre-looks color entries of a parsed settings file, as saved.
    static func legacyEntries(in object: [String: Any]) -> [String: Any] {
        object.filter { LegacyAppearance.keys.contains($0.key) }
    }

    /// Keys that were settings once and no longer are. The decoder ignores
    /// them; listing them here makes the next load drop them from the file.
    private static let removedKeys = ["settleCapMs", "draftMinTailMs", "settleSentences", "primaryTrigger"]

    /// True when `data` is a settings object still carrying pre-looks color
    /// keys or removed keys, so the store knows to save the current form.
    static func hasStaleKeys(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (LegacyAppearance.keys + removedKeys).contains { object[$0] != nil }
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
