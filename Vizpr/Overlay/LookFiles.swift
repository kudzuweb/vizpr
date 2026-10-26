import Foundation

/// A look stored as one JSON file: the built-in looks' files and the user's
/// custom looks in the Looks folder. A file is one `OverlayLook` as the
/// encoder writes it; a partial file is merged over `OverlayLook.mergeTemplate`
/// on load, so a missing field takes its no-visible-change default.
///
/// Every method takes the folder, so tests pass a fresh temp folder.
enum LookFiles {
    /// A file that was not loaded, and why.
    struct Failure: Equatable, Sendable {
        let url: URL
        let reason: String
        var isOverLimit: Bool { reason == LookFiles.overLimitReason }
    }

    /// What a load found: the looks in file-name order (at most `limit`),
    /// the file each came from, and every file that was skipped.
    struct Report: Sendable {
        var looks: [OverlayLook] = []
        var urls: [UUID: URL] = [:]
        var failures: [Failure] = []
    }

    static let overLimitReason = "not loaded, over the limit"
    static let fileExtension = "json"
    static let maxSlugLength = 40

    /// Beside the `Fonts` folder; outside the repo, so a pull cannot reach it.
    static var folder: URL {
        StorageRoot.url.appendingPathComponent("Looks", isDirectory: true)
    }

    // MARK: Loading

    /// Loads every `.json` file in `folder`, in file-name order. A file that
    /// cannot be used is skipped and reported; it never stops the others.
    static func load(
        from folder: URL,
        template: OverlayLook = .mergeTemplate,
        limit: Int = VizprSettings.maxLooks
    ) -> Report {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted(by: sortsBefore)
        let templateObject = (try? encodedObject(of: template)) ?? [:]

        var report = Report()
        var owners: [UUID: URL] = [:]
        for file in files {
            let look: OverlayLook
            do {
                look = try read(file, over: templateObject)
            } catch {
                fail(&report, file, error.localizedDescription)
                continue
            }
            if look.isBuiltIn {
                fail(&report, file, "uses the id of the built-in look \(OverlayLook.builtIns.first { $0.id == look.id }?.name ?? "")")
            } else if let first = owners[look.id] {
                fail(&report, file, "has the same id as \(first.lastPathComponent)")
            } else {
                owners[look.id] = file
                if report.looks.count < limit {
                    report.looks.append(look)
                    report.urls[look.id] = file
                } else {
                    fail(&report, file, overLimitReason)
                }
            }
        }
        return report
    }

    /// File-name order, compared without the extension so `night.json` comes
    /// before `night-copy.json`.
    static func sortsBefore(_ left: URL, _ right: URL) -> Bool {
        let leftStem = left.deletingPathExtension().lastPathComponent
        let rightStem = right.deletingPathExtension().lastPathComponent
        return leftStem == rightStem ? left.lastPathComponent < right.lastPathComponent : leftStem < rightStem
    }

    private static func fail(_ report: inout Report, _ file: URL, _ reason: String) {
        report.failures.append(Failure(url: file, reason: reason))
        logLine("\(file.lastPathComponent) not loaded: \(reason)")
    }

    private struct FileProblem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Decodes one file as `load` does, without the rules that need the other
    /// files or the built-in ids. The test of `glass.json` and `slab.json`
    /// reads them this way, because `load` refuses a built-in id.
    static func read(_ file: URL, template: OverlayLook = .mergeTemplate) throws -> OverlayLook {
        try read(file, over: (try? encodedObject(of: template)) ?? [:])
    }

    private static func read(_ file: URL, over templateObject: [String: Any]) throws -> OverlayLook {
        let data = try Data(contentsOf: file)
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileProblem("is not a JSON object")
        }
        // Checked before the merge: afterwards a missing id reads as Glass's
        // and a missing name as the template's empty one.
        guard saved["id"] is String else { throw FileProblem("needs an id") }
        guard saved["name"] is String else { throw FileProblem("needs a name") }
        let merged = SettingsMerge.merged(saved: saved, over: templateObject, elementDefaults: [:])
        do {
            return try JSONDecoder()
                .decode(OverlayLook.self, from: JSONSerialization.data(withJSONObject: merged))
                .clamped()
        } catch let error as DecodingError {
            throw FileProblem(describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "has an invalid value at \(path(context)): \(context.debugDescription)"
        case .keyNotFound(let key, _):
            return "is missing \(key.stringValue)"
        @unknown default:
            return "could not be decoded"
        }
    }

    /// Any `Encodable` as parsed JSON.
    static func encodedObject(of value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Writing

    /// Writes `look` atomically. A look that already has a file passes it as
    /// `existing` and keeps its name, because a file is never renamed; a new
    /// look gets a file named from its name.
    @discardableResult
    static func write(_ look: OverlayLook, in folder: URL, at existing: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = existing ?? newURL(slug: slug(for: look), in: folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(look).write(to: url, options: .atomic)
        return url
    }

    /// Moves the file to the Trash, so a deletion from the pane can be undone.
    static func delete(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The file name stem for a new look: its name in lowercase with hyphens,
    /// or `look-<first 8 hex of the id>` when nothing is left of the name.
    static func slug(for look: OverlayLook) -> String {
        let slug = slug(of: look.name)
        return slug.isEmpty ? fallbackSlug(forID: look.id.uuidString) : slug
    }

    static func fallbackSlug(forID id: String) -> String {
        let hex = id.lowercased().filter { $0.isHexDigit }.prefix(8)
        return "look-\(hex)"
    }

    static func slug(of name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if slug.last != "-" {
                slug.append("-")
            }
        }
        let cut = slug.prefix(maxSlugLength)
        return String(cut).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `<slug>.json`, or `<slug>-2.json`, `-3`... when the name is taken in
    /// the folder or in `taken`.
    static func newURL(slug: String, in folder: URL, taken: Set<String> = []) -> URL {
        var candidate = "\(slug).\(fileExtension)"
        var number = 2
        while taken.contains(candidate)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(number).\(fileExtension)"
            number += 1
        }
        return folder.appendingPathComponent(candidate)
    }

    /// One Debug dev-log line; nothing in Release.
    static func logLine(_ message: String) {
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("LOOK FILES: \(message)")
        #endif
    }
}
