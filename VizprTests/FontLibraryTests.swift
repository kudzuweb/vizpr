import AppKit
import Foundation
import Testing
@testable import Vizpr

/// Registration is the seam between a font file the user dropped in and a
/// family name a look can store: a failure here leaves the picker silently
/// short of the font.
@MainActor
@Suite("Font library")
struct FontLibraryTests {
    private static let georgia = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-fonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A font file is registered, its family is offered, and registering again is not an error")
    func registersAndIsIdempotent() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: Self.georgia, to: folder.appendingPathComponent("Georgia.ttf"))

        let first = FontLibrary.registerAll(in: folder)
        let second = FontLibrary.registerAll(in: folder)

        #expect(first.families.contains("Georgia"))
        #expect(first.failedFiles.isEmpty)
        #expect(second == first)
        #expect(FontLibrary.families.contains("Georgia"))
    }

    @Test("A missing folder is created, non-font files are skipped and a corrupt font file is reported")
    func foldersAndBadFiles() throws {
        let folder = try makeFolder().appendingPathComponent("Fonts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        #expect(FontLibrary.registerAll(in: folder) == .init(families: [], failedFiles: []))
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try Data("not a font".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("not a font".utf8).write(to: folder.appendingPathComponent("broken.otf"))
        #expect(FontLibrary.registerAll(in: folder) == .init(families: [], failedFiles: ["broken.otf"]))
    }

    /// Georgia with its family name swapped for an unused one of the same
    /// length, so the name table keeps its offsets: a family no system or
    /// earlier registration can already supply.
    private func writeRenamedGeorgia(as family: String, into folder: URL) throws {
        func utf16(_ text: String) -> Data { Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) }
        var data = try Data(contentsOf: Self.georgia)
        for (old, new) in [(utf16("Georgia"), utf16(family)), (Data("Georgia".utf8), Data(family.utf8))] {
            var from = data.startIndex
            while let range = data.range(of: old, in: from..<data.endIndex) {
                data.replaceSubrange(range, with: new)
                from = range.upperBound
            }
        }
        try data.write(to: folder.appendingPathComponent("\(family).ttf"))
    }

    @Test("A registered family that was not installed appears in the picker list")
    func registrationAddsAFamily() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let family = String((0..<7).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
        #expect(!FontLibrary.families.contains(family))
        try writeRenamedGeorgia(as: family, into: folder)

        let report = FontLibrary.registerAll(in: folder)

        #expect(report.families == [family])
        #expect(FontLibrary.families.contains(family))
        #expect(NSFont(name: family, size: 14) != nil)
    }
}
