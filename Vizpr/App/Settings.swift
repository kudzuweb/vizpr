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
    /// Tap vs hold boundary, milliseconds (field-tuned default from PR 3).
    var holdThresholdMs: Int = 280

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

    /// The locked settled:mutable opacity ratio (not persisted, not a
    /// setting — the trust contract's floor).
    static let mutableOpacityRatio = 0.55

    static let `default` = VizprSettings()

    /// Clamp every numeric into its safe range (decode-time guard).
    func clamped() -> VizprSettings {
        var s = self
        s.holdThresholdMs = min(max(s.holdThresholdMs, 100), 1_000)
        s.settleSentences = min(max(s.settleSentences, 1), 6)
        s.autoStopSeconds = min(max(s.autoStopSeconds, 2), 60)
        s.settleCapMs = min(max(s.settleCapMs, 0), 1_000)
        s.draftMinTailMs = min(max(s.draftMinTailMs, 500), 4_000)
        s.tintStrength = min(max(s.tintStrength, 0), 0.5)
        s.tintHex = Self.sanitizeHex(s.tintHex) ?? Self.default.tintHex
        s.textBaseHex = s.textBaseHex.flatMap(Self.sanitizeHex)
        return s
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
final class SettingsStore {
    private let fileURL: URL
    private(set) var settings: VizprSettings
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
