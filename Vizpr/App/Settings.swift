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
    /// Settle window, sentences (TokenStream live-region size).
    var settleSentences: Int = 2
    /// Auto-stop after this much silence, seconds.
    var autoStopSeconds: Int = 6
    /// Flush-settle cap at commit, milliseconds (§15 amendment).
    var settleCapMs: Int = 350
    /// Draft track minimum tail before the first decode, milliseconds —
    /// Mauria's "first draft faster?" lever; lower = earlier + junkier.
    var draftMinTailMs: Int = 1500

    // MARK: Cleanup
    var cleanupEnabled: Bool = true
    var codeModeOverride: Bool = false

    // MARK: Injection
    /// ON: original clipboard restored after paste. OFF: transcript stays on
    /// the clipboard (Mauria, PR 8 field request).
    var restoreClipboard: Bool = true

    /// Inviz mode (Mauria): no live transcript preview — just a small
    /// "talking is happening" indicator mid-screen; text appears finalized
    /// in place at commit. An explicit opt-out of proofread-as-you-speak;
    /// the pipeline underneath is unchanged.
    var invizMode: Bool = false
    /// Fall back to the built-in mic when the selected input delivers pure
    /// silence (the AirPods-on-a-phone-call trap; default on).
    var silentInputFallback: Bool = true

    // MARK: Appearance (PR 11 color decisions, 2026-07-05)
    /// Glass tint, hex RGB. Default is the §15 lavender — the lock is
    /// amended to "lavender default, user-tunable".
    var tintHex: String = "A16FDF"
    /// Tint strength 0...0.5 (13% default; §15 rejected 8% and 17% as the
    /// bounds of taste, the range allows exploring).
    var tintStrength: Double = 0.13
    /// Text theme: nil = System (primary/secondary label colors, adaptive).
    /// Set = custom base color hex; settled renders at full opacity and
    /// mutable at a FIXED ratio of it — the trust-contrast ratio is locked
    /// and no theme can collapse it (only the hue is user's).
    var textBaseHex: String?

    /// Linked mode: the text base color derives from the tint (one picker
    /// moves both); unlinked, tint and text are independent (Mauria).
    var colorsLinked: Bool = false
    /// Saved color configurations (Mauria: ~6 presets).
    var colorPresets: [ColorPreset] = []

    /// The locked settled:mutable opacity ratio (not persisted, not a
    /// setting — the trust contract's floor).
    static let mutableOpacityRatio = 0.55
    static let maxColorPresets = 6

    static let `default` = VizprSettings()

    /// Clamp every numeric into its safe range (decode-time guard).
    func clamped() -> VizprSettings {
        var s = self
        s.holdThresholdMs = min(max(s.holdThresholdMs, 100), 1_000)
        s.secondaryModifiers = s.secondaryModifiers.filter { Self.validModifiers.contains($0) }
        if s.secondaryModifiers.count < 2 { s.secondaryModifiers = ["control", "option"] }
        if s.primaryTrigger != "fn" { s.primaryTrigger = "fn" }   // only Fn yet
        s.settleSentences = min(max(s.settleSentences, 1), 6)
        s.autoStopSeconds = min(max(s.autoStopSeconds, 2), 60)
        s.settleCapMs = min(max(s.settleCapMs, 0), 1_000)
        s.draftMinTailMs = min(max(s.draftMinTailMs, 500), 4_000)
        s.tintStrength = min(max(s.tintStrength, 0), 0.5)
        s.tintHex = Self.sanitizeHex(s.tintHex) ?? Self.default.tintHex
        s.textBaseHex = s.textBaseHex.flatMap(Self.sanitizeHex)
        s.colorPresets = Array(s.colorPresets.prefix(Self.maxColorPresets))
            .map { $0.clamped() }
        return s
    }

    static func sanitizeHex(_ hex: String) -> String? {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "").uppercased()
        guard cleaned.count == 6, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        return cleaned
    }
}

/// One saved color configuration.
struct ColorPreset: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String = ""
    var tintHex: String = VizprSettings.default.tintHex
    var tintStrength: Double = 0.13
    var textBaseHex: String?
    var colorsLinked: Bool = false

    func clamped() -> ColorPreset {
        var p = self
        p.tintStrength = min(max(p.tintStrength, 0), 0.5)
        p.tintHex = VizprSettings.sanitizeHex(p.tintHex) ?? VizprSettings.default.tintHex
        p.textBaseHex = p.textBaseHex.flatMap(VizprSettings.sanitizeHex)
        return p
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
        let url = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vizpr/settings.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VizprSettings.self, from: data) {
            settings = decoded.clamped()
        } else {
            settings = .default
        }
    }

    func onChange(_ observer: @escaping (VizprSettings) -> Void) {
        observers.append(observer)
    }

    /// Reset every setting to its default. Color presets SURVIVE a reset
    /// (Mauria: deleting them is a separate, deliberate act).
    func resetAll() {
        update {
            let presets = $0.colorPresets
            $0 = .default
            $0.colorPresets = presets
        }
    }

    func deleteAllPresets() {
        update { $0.colorPresets = [] }
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
