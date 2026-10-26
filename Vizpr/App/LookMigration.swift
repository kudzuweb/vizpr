import Foundation

/// One-way move of looks out of `settings.json` and into look files.
///
/// Nothing is dropped until every look is verified in the folder: `run`
/// reports `completed` only after reloading the folder and finding each
/// element there, and the caller keeps the original raw data in
/// `settings.json` until then. A rerun after a crash is safe: an element that
/// is already a file with equal content is skipped.
enum LookMigration {
    struct Outcome {
        let completed: Bool
        /// Why the migration stopped, for the dev log and the pane caption.
        let problem: String?

        static let done = Outcome(completed: true, problem: nil)
        static func failed(_ problem: String) -> Outcome { Outcome(completed: false, problem: problem) }
    }

    static let backupSuffix = "-before-look-files"
    static let renamedSuffix = " (from settings)"

    /// Writes each element as a look file.
    /// - Parameters:
    ///   - elements: the raw `looks` entries, or the looks the legacy color
    ///     migration produced, as parsed JSON.
    ///   - settings: the settings file and the bytes read from it. When given,
    ///     those bytes are first saved beside it as a `-before-look-files` copy.
    ///   - folder: the Looks folder.
    static func run(_ elements: [[String: Any]], backingUp settings: (url: URL, data: Data)?, into folder: URL) -> Outcome {
        if let settings {
            do {
                try backUp(settings.data, of: settings.url)
            } catch {
                return .failed("could not save a backup copy of \(settings.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var known = Dictionary(
            uniqueKeysWithValues: LookFiles.load(from: folder, limit: .max).looks.map { ($0.id, $0) }
        )
        var expectedLooks: [OverlayLook] = []
        var expectedRaw: [[String: Any]] = []

        do {
            for (index, element) in elements.enumerated() {
                guard let look = try? LookFiles.decode(element) else {
                    try keepRaw(element, index: index, in: folder)
                    expectedRaw.append(element)
                    continue
                }
                if let existing = known[look.id], existing == look {
                    expectedLooks.append(existing)
                } else if known[look.id] == nil, !look.isBuiltIn {
                    try LookFiles.write(look, in: folder)
                    known[look.id] = look
                    expectedLooks.append(look)
                } else {
                    // The id belongs to a built-in or to a different file: keep
                    // both, the element under a fresh id.
                    var renamed = look
                    renamed.id = UUID()
                    renamed.name = String(look.name.prefix(24)).trimmingCharacters(in: .whitespaces)
                        + renamedSuffix
                    renamed = renamed.clamped()
                    if let twin = known.values.first(where: { sameApartFromID($0, renamed) }) {
                        expectedLooks.append(twin)   // written by an earlier, interrupted run
                    } else {
                        try LookFiles.write(renamed, in: folder)
                        known[renamed.id] = renamed
                        expectedLooks.append(renamed)
                    }
                }
            }
        } catch {
            return .failed("could not write a look file: \(error.localizedDescription)")
        }

        let reloaded = LookFiles.load(from: folder, limit: .max)
        for look in expectedLooks where reloaded.looks.first(where: { $0.id == look.id }) != look {
            return .failed("look \"\(look.name)\" was not found in the Looks folder after writing")
        }
        let folderObjects = jsonObjects(in: folder)
        for raw in expectedRaw where !folderObjects.contains(where: { NSDictionary(dictionary: $0).isEqual(to: raw) }) {
            return .failed("an unreadable look was not found in the Looks folder after writing")
        }
        return .done
    }

    // MARK: Elements

    private static func sameApartFromID(_ existing: OverlayLook, _ candidate: OverlayLook) -> Bool {
        var copy = existing
        copy.id = candidate.id
        return copy == candidate
    }

    /// An element that cannot be decoded is written as it is, so the loader
    /// reports it and nothing is lost.
    private static func keepRaw(_ element: [String: Any], index: Int, in folder: URL) throws {
        if jsonObjects(in: folder).contains(where: { NSDictionary(dictionary: $0).isEqual(to: element) }) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stem = LookFiles.slug(of: element["name"] as? String ?? "")
        if stem.isEmpty {
            let fallback = LookFiles.fallbackSlug(forID: element["id"] as? String ?? "")
            stem = fallback == "look-" ? "look-element-\(index + 1)" : fallback
        }
        let data = try JSONSerialization.data(withJSONObject: element, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: LookFiles.newURL(slug: stem, in: folder), options: .atomic)
    }

    private static func jsonObjects(in folder: URL) -> [[String: Any]] {
        let files = (try? LookFiles.jsonFiles(in: folder)) ?? []
        return files.compactMap {
            (try? Data(contentsOf: $0))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    // MARK: Backup

    /// Saves `data` as `settings.json.<yyyy-MM-dd-HHmmss>-before-look-files`
    /// without overwriting a file, and does nothing when an earlier copy
    /// already holds the same bytes.
    private static func backUp(_ data: Data, of settingsURL: URL) throws {
        let directory = settingsURL.deletingLastPathComponent()
        let prefix = settingsURL.lastPathComponent + "."
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in siblings
        where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent.hasSuffix(backupSuffix) {
            if (try? Data(contentsOf: file)) == data { return }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        var destination = directory.appendingPathComponent(prefix + stamp + backupSuffix)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(prefix)\(stamp)-\(number)\(backupSuffix)")
            number += 1
        }
        try data.write(to: destination, options: .withoutOverwriting)
    }
}
