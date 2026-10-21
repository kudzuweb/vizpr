import Foundation

/// Loads/saves the vocabulary as a single JSON document — one flat array of
/// entry objects — in Application Support (PLAN.md §4). Loaded whole, rewritten
/// on edit. Config, not transcript persistence (invariant 7 permits config).
///
/// This is the thin IO shell; `Vocabulary` holds the pure matching logic. The
/// Settings editor (PR 11) drives save().
struct VocabularyStore {
    let url: URL

    /// Default location: ~/Library/Application Support/Vizpr/vocabulary.json.
    static var defaultURL: URL {
        StorageRoot.url.appendingPathComponent("vocabulary.json")
    }

    init(url: URL = VocabularyStore.defaultURL) {
        self.url = url
    }

    /// Load the vocabulary. A missing file is an empty vocabulary (not an
    /// error — first run). A malformed file throws so the user is told rather
    /// than silently losing their terms.
    func load() throws -> Vocabulary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        return Vocabulary(entries: entries)
    }

    /// Rewrite the whole document.
    func save(_ vocabulary: Vocabulary) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(vocabulary.entries)
        try data.write(to: url, options: .atomic)
    }
}
