import Foundation
import Testing
@testable import Vizpr

/// Moving looks out of settings.json is a one-way step where a mistake loses a
/// user's look without any crash, so every path is pinned: the move, a folder
/// that cannot be written, a rerun after a crash, and ids that collide.
@MainActor
@Suite("Looks migration and look files in the store")
struct SettingsStoreLooksTests {
    private let twoLooks = """
    {"autoStopSeconds": 7,
     "looks": [{"id": "\(LookFixtures.idA)", "name": "Sunset", "cornerRadius": 12},
               {"id": "\(LookFixtures.idB)", "name": "Night", "surface": "slab"}]}
    """

    private func settingsFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func parsed(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func fileNames(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test("Two looks in the array become two files, a backup copy and a settings file without looks, and a second store loads the same two")
    func migration() throws {
        let url = try settingsFile(twoLooks)
        let original = try Data(contentsOf: url)
        let folder = try LookFixtures.folder()

        let first = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(try fileNames(folder) == ["night.json", "sunset.json"])
        #expect(first.settings.looks.map(\.name) == ["Night", "Sunset"])
        #expect(first.lookMigrationProblem == nil && first.lookFileFailures.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backups = siblings.filter { $0.hasPrefix("settings.json.") && $0.hasSuffix("-before-look-files") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backups[0])) == original)

        let object = try parsed(url)
        #expect(object["looks"] == nil)
        #expect(object["autoStopSeconds"] as? Int == 7)

        let second = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(second.settings == first.settings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix("-before-look-files") }.count == 1, "no second backup")
    }

    @Test("With the looks folder unwritable, a later save leaves both looks in settings.json equal to the original entries")
    func unwritableFolder() throws {
        let url = try settingsFile(twoLooks)
        let original = try parsed(url)
        let folder = try LookFixtures.folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        let store = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(store.lookMigrationProblem != nil)
        #expect(store.settings.looks.count == 2, "the looks still show while they are only in settings.json")
        store.update { $0.autoStopSeconds = 9 }

        let saved = try parsed(url)
        #expect(saved["autoStopSeconds"] as? Int == 9)
        #expect(NSArray(array: try #require(saved["looks"] as? [Any]))
            .isEqual(to: try #require(original["looks"] as? [Any])))
        #expect(try fileNames(folder).isEmpty)

        // A restart with a writable folder then completes the move.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let restarted = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(restarted.lookMigrationProblem == nil)
        #expect(Set(restarted.settings.looks.map(\.name)) == ["Sunset", "Night"])
        #expect(try parsed(url)["looks"] == nil)
    }

    @Test("With the files already written and the array still present, the migration skips them silently and drops the array")
    func crashRerun() throws {
        let url = try settingsFile(twoLooks)
        let folder = try LookFixtures.folder()
        // The state a crash between writing the files and rewriting settings.json leaves.
        _ = SettingsStore(fileURL: try settingsFile(twoLooks), looksFolder: folder)
        let before = try fileNames(folder)
        #expect(before == ["night.json", "sunset.json"])

        let store = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(store.lookFileFailures.isEmpty)
        #expect(store.lookMigrationProblem == nil)
        #expect(try fileNames(folder) == before, "no duplicate files")
        #expect(store.settings.looks.count == 2)
        #expect(try parsed(url)["looks"] == nil)
    }

    @Test("An element whose id matches a file with different content is written under a fresh id and the existing file is unchanged")
    func differingIDCollision() throws {
        let url = try settingsFile(
            #"{"looks": [{"id": "\#(LookFixtures.idA)", "name": "Other", "cornerRadius": 30}]}"#)
        let folder = try LookFixtures.folder()
        let existing = try LookFixtures.put(
            #"{"id": "\#(LookFixtures.idA)", "name": "Existing"}"#, "existing.json", in: folder)
        let existingBytes = try Data(contentsOf: existing)

        let store = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(try Data(contentsOf: existing) == existingBytes)
        #expect(store.settings.looks.map(\.name) == ["Existing", "Other (from settings)"])
        let renamed = try #require(store.settings.looks.last)
        #expect(renamed.id.uuidString != LookFixtures.idA)
        #expect(renamed.cornerRadius == 30)
        #expect(try parsed(url)["looks"] == nil)

        // A rerun of the same step does not write a third copy.
        _ = SettingsStore(fileURL: try settingsFile(
            #"{"looks": [{"id": "\#(LookFixtures.idA)", "name": "Other", "cornerRadius": 30}]}"#), looksFolder: folder)
        #expect(try fileNames(folder).count == 2)
    }

    @Test("An element with an unknown enum value is written as it is, reported by the loader, and does not block the others")
    func undecodableElement() throws {
        let url = try settingsFile("""
        {"looks": [{"id": "\(LookFixtures.idA)", "name": "Broken", "surface": "marble"},
                   {"id": "\(LookFixtures.idB)", "name": "Fine"}]}
        """)
        let folder = try LookFixtures.folder()
        let store = SettingsStore(fileURL: url, looksFolder: folder)

        #expect(try fileNames(folder) == ["broken.json", "fine.json"])
        let raw = try parsed(folder.appendingPathComponent("broken.json"))
        #expect(raw["surface"] as? String == "marble")
        #expect(store.settings.looks.map(\.name) == ["Fine"])
        #expect(store.lookFileFailures.map(\.url.lastPathComponent) == ["broken.json"])
        #expect(try parsed(url)["looks"] == nil)
    }

    @Test("A looks entry that is not a list is kept in settings.json through later saves")
    func wrongShapedLooksEntryIsKept() throws {
        let url = try settingsFile(#"{"looks": "oops"}"#)
        let store = SettingsStore(fileURL: url, looksFolder: try LookFixtures.folder())
        store.update { $0.autoStopSeconds = 9 }
        #expect(try parsed(url)["looks"] as? String == "oops")
    }

    @Test("Editing a look rewrites its file, a rename keeps the file name, and settings.json is not rewritten")
    func editsGoToTheFile() throws {
        let url = try settingsFile(twoLooks)
        let folder = try LookFixtures.folder()
        let store = SettingsStore(fileURL: url, looksFolder: folder)
        let settingsBytes = try Data(contentsOf: url)

        store.selectLook(try #require(UUID(uuidString: LookFixtures.idA)))
        let afterSelect = try Data(contentsOf: url)
        #expect(afterSelect != settingsBytes, "a settings change still saves settings.json")

        store.updateActiveLook { $0.name = "Zebra"; $0.cornerRadius = 20 }
        #expect(try Data(contentsOf: url) == afterSelect, "a look-only change leaves settings.json alone")
        #expect(try fileNames(folder) == ["night.json", "sunset.json"])
        #expect(store.settings.looks.map(\.name) == ["Night", "Zebra"], "the row keeps its place")
        let reloaded = LookFiles.load(from: folder).looks
        #expect(reloaded.map(\.name) == ["Night", "Zebra"])
        #expect(reloaded.last?.cornerRadius == 20)
    }

    @Test("A duplicate is inserted in file-name order at once and matches a reload")
    func duplicateOrder() throws {
        let folder = try LookFixtures.folder()
        let store = SettingsStore(fileURL: try settingsFile(twoLooks), looksFolder: folder)
        store.duplicateLook(try #require(store.settings.looks.first))   // "Night copy"
        #expect(store.settings.looks.map(\.name) == ["Night", "Night copy", "Sunset"])
        #expect(LookFiles.load(from: folder).looks == store.settings.looks)
    }

    @Test("Delete and Delete All act only on loaded files, never on unreadable or over-the-limit ones")
    func deleteTouchesOnlyMappedFiles() throws {
        let folder = try LookFixtures.folder()
        let unreadable = try LookFixtures.put("{ not json", "0-broken.json", in: folder)
        for number in 10..<24 {
            try LookFixtures.put(#"{"id": "\#(UUID().uuidString)", "name": "Look \#(number)"}"#,
                                 "look-\(number).json", in: folder)
        }
        var discarded: [URL] = []
        let store = SettingsStore(
            fileURL: try settingsFile("{}"), looksFolder: folder,
            discardLookFile: { discarded.append($0) }
        )
        #expect(store.settings.looks.count == 12)

        store.deleteLook(store.settings.looks[0].id)
        #expect(discarded.map(\.lastPathComponent) == ["look-10.json"])

        store.deleteAllLooks()
        #expect(discarded.count == 12)
        let names = Set(discarded.map(\.lastPathComponent))
        #expect(!names.contains("0-broken.json") && !names.contains("look-22.json") && !names.contains("look-23.json"))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
    }

    @Test("Reload Looks picks up a file added by hand and reports a broken one")
    func reload() throws {
        let folder = try LookFixtures.folder()
        let store = SettingsStore(fileURL: try settingsFile("{}"), looksFolder: folder)
        #expect(store.settings.looks.isEmpty)
        try LookFixtures.put(#"{"id": "\#(LookFixtures.idA)", "name": "Added"}"#, "added.json", in: folder)
        try LookFixtures.put("{ nope", "broken.json", in: folder)

        var notified = 0
        store.onChange { _ in notified += 1 }
        store.reloadLooks()
        #expect(store.settings.looks.map(\.name) == ["Added"])
        #expect(store.lookFileFailures.map(\.url.lastPathComponent) == ["broken.json"])
        #expect(notified == 1)
    }

    @Test("A broken file at launch is reported without a reload, and settings.json is left alone")
    func launchReportsFailures() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put("{ nope", "broken.json", in: folder)
        let url = try settingsFile(#"{"autoStopSeconds": 30}"#)
        let store = SettingsStore(fileURL: url, looksFolder: folder)
        #expect(store.lookFileFailures.count == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"autoStopSeconds": 30}"#)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
    }
}
