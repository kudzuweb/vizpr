import Foundation

/// One named context dictionary ("coding", "casual", "professional email" —
/// the user names them freely). Order in the library is the hotkey-cycling
/// order.
struct VocabularyBucket: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var entries: [VocabularyEntry] = []
    /// Style directives for this context (Mauria: buckets are full context
    /// profiles) — free text injected into the cleanup prompt when active,
    /// e.g. "no capitalization" or "formal punctuation; expand contractions
    /// (gonna -> going to)". Prompt-enforced, best-effort.
    var styleRules: String = ""
}

/// The hierarchical vocabulary (Mauria's design, 2026-07-05): a GLOBAL
/// dictionary that applies everywhere, named context buckets below it, and
/// app → bucket assignments — dictionaries belong to contexts, apps are
/// assigned to contexts. "Like a global claude.md and project-level, but for
/// how to interpret speech in context."
struct VocabularyLibrary: Codable, Equatable, Sendable {
    var global: [VocabularyEntry] = []
    var buckets: [VocabularyBucket] = []
    /// bundle id → bucket name.
    var appAssignments: [String: String] = [:]
    /// Manual override (hotkey cycle / menu pick). nil = automatic (use the
    /// app assignment); the reserved sentinel = global-only.
    var manualBucket: String?

    /// Reserved manualBucket value meaning "use ONLY the global dictionary —
    /// ignore app assignments" (a sentinel rather than a new field keeps the
    /// on-disk format stable; the control character can never collide with a
    /// user bucket name).
    static let globalOnly = "\u{1F}global-only"

    var isGlobalOnly: Bool { manualBucket == Self.globalOnly }

    /// Menu/UI display name for the current manual state.
    var activeDisplayName: String {
        if isGlobalOnly { return "Global only" }
        return manualBucket ?? "Automatic"
    }
    /// Style directives that apply everywhere (the global level's rules).
    var globalStyleRules: String = ""

    /// The active bucket under the same resolution order as resolved().
    func activeBucket(bundleID: String?) -> VocabularyBucket? {
        if isGlobalOnly { return nil }
        let name = manualBucket ?? bundleID.flatMap { appAssignments[$0] }
        return name.flatMap { n in buckets.first { $0.name == n } }
    }

    /// Combined style rules: global first, bucket last (bucket wins in
    /// instruction order). nil when neither has rules.
    func resolvedStyleRules(bundleID: String?) -> String? {
        let parts = [globalStyleRules, activeBucket(bundleID: bundleID)?.styleRules ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static let empty = VocabularyLibrary()

    /// Resolution order: manual override > app assignment > global-only.
    /// Within a resolved bucket, bucket entries win pattern conflicts with
    /// global (context overrides global; global fills everything else).
    func resolved(bundleID: String?) -> Vocabulary {
        guard let bucket = activeBucket(bundleID: bundleID) else {
            return Vocabulary(entries: global)
        }
        let overridden = Set(bucket.entries.map { $0.pattern.lowercased() })
        let merged = bucket.entries + global.filter {
            !overridden.contains($0.pattern.lowercased())
        }
        return Vocabulary(entries: merged)
    }

    /// Hotkey cycle: automatic → bucket 1 → bucket 2 → … → automatic.
    /// Returns the new state's display name for the menu/overlay.
    /// Cycle order: Automatic → Global only → bucket 1 → … → Automatic.
    @discardableResult
    mutating func cycleManualBucket() -> String {
        switch manualBucket {
        case nil:
            manualBucket = Self.globalOnly
        case Self.globalOnly:
            manualBucket = buckets.first?.name   // nil (Automatic) if none
        case let current?:
            if let index = buckets.firstIndex(where: { $0.name == current }),
               index + 1 < buckets.count {
                manualBucket = buckets[index + 1].name
            } else {
                manualBucket = nil   // wrap back to automatic
            }
        }
        return activeDisplayName
    }

    /// Propagation (the claude.md analogy): move an entry between levels.
    mutating func promoteToGlobal(pattern: String, fromBucket name: String) {
        guard let bucketIndex = buckets.firstIndex(where: { $0.name == name }),
              let entryIndex = buckets[bucketIndex].entries.firstIndex(where: {
                  $0.pattern.lowercased() == pattern.lowercased()
              }) else { return }
        let entry = buckets[bucketIndex].entries.remove(at: entryIndex)
        global.removeAll { $0.pattern.lowercased() == entry.pattern.lowercased() }
        global.append(entry)
    }

    mutating func demoteFromGlobal(pattern: String, toBucket name: String) {
        guard let entryIndex = global.firstIndex(where: {
                  $0.pattern.lowercased() == pattern.lowercased()
              }),
              let bucketIndex = buckets.firstIndex(where: { $0.name == name })
        else { return }
        let entry = global.remove(at: entryIndex)
        buckets[bucketIndex].entries.removeAll {
            $0.pattern.lowercased() == entry.pattern.lowercased()
        }
        buckets[bucketIndex].entries.append(entry)
    }
}

extension VocabularyStore {
    /// Load the hierarchical library, migrating a pre-PR-11 flat file
    /// (a bare entry array) into the global level losslessly.
    func loadLibrary() throws -> VocabularyLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        if let library = try? JSONDecoder().decode(VocabularyLibrary.self, from: data) {
            return library
        }
        let flat = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        return VocabularyLibrary(global: flat)
    }

    func saveLibrary(_ library: VocabularyLibrary) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
