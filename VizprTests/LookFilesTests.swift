import Foundation
import Testing
@testable import Vizpr

/// Temp folders and files for the look-file tests.
enum LookFixtures {
    static let idA = "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E01"
    static let idB = "5A1B6A52-6F42-4B7E-8D5C-2C0B5C1D9E02"

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-looks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func put(_ json: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    static func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vizpr/Overlay/\(name)")
    }
}

/// The look file is the look: these pin the loader's no-visible-change merge
/// and its per-file failure rule, where a mistake would silently restyle or
/// drop a user's look.
@Suite("Look files")
struct LookFilesTests {
    @Test("A look written with write and loaded with load is equal, after clamping too")
    func fileRoundTrip() throws {
        let folder = try LookFixtures.folder()
        var slab = OverlayLook.slab
        slab.id = UUID()
        slab.name = "Slab two"
        slab.slab.meshLoopSeconds = 12
        slab.style.light.bevel = 0.4
        var glass = OverlayLook.glass
        glass.id = UUID()
        glass.name = "Glass two"
        glass.textBaseHex = "ABCDEF"
        try LookFiles.write(slab, in: folder)
        try LookFiles.write(glass, in: folder)

        let report = LookFiles.load(from: folder)
        #expect(report.looks == [glass.clamped(), slab.clamped()])
        #expect(report.failures.isEmpty)
        #expect(Set(report.urls.keys) == [slab.id, glass.id])
    }

    @Test("A file holding only id, name and surface loads with every other field at the template's value")
    func partialFile() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put(#"{"id": "\#(LookFixtures.idA)", "name": "Bare", "surface": "slab"}"#, "bare.json", in: folder)
        let look = try #require(LookFiles.load(from: folder).looks.first)
        var expected = OverlayLook.mergeTemplate
        expected.id = try #require(UUID(uuidString: LookFixtures.idA))
        expected.name = "Bare"
        expected.surface = .slab
        #expect(look == expected)
    }

    @Test("A folder with an undecodable file, one without an id, one without a name and two good files loads the good two and reports three")
    func oneBadFile() throws {
        let folder = try LookFixtures.folder()
        let bad = try LookFixtures.put(
            #"{"id": "\#(LookFixtures.idA)", "name": "Bad", "surface": "marble"}"#, "a-bad.json", in: folder)
        let noID = try LookFixtures.put(#"{"name": "No id"}"#, "b-no-id.json", in: folder)
        let noName = try LookFixtures.put(#"{"id": "\#(LookFixtures.idB)"}"#, "c-no-name.json", in: folder)
        try LookFixtures.put(#"{"id": "\#(UUID().uuidString)", "name": "One"}"#, "d-one.json", in: folder)
        try LookFixtures.put(#"{"id": "\#(UUID().uuidString)", "name": "Two"}"#, "e-two.json", in: folder)

        let report = LookFiles.load(from: folder)
        #expect(report.looks.map(\.name) == ["One", "Two"])
        #expect(report.failures.map(\.url.lastPathComponent) == [bad, noID, noName].map(\.lastPathComponent))
        #expect(report.failures[1].reason == "needs an id")
        #expect(report.failures[2].reason == "needs a name")
    }

    @Test("A file that is not JSON is reported and does not stop the others")
    func notJSON() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put("{ not json", "a.json", in: folder)
        try LookFixtures.put("[1, 2]", "b.json", in: folder)
        try LookFixtures.put(#"{"id": "\#(UUID().uuidString)", "name": "Fine"}"#, "c.json", in: folder)
        let report = LookFiles.load(from: folder)
        #expect(report.looks.map(\.name) == ["Fine"])
        #expect(report.failures.count == 2)
    }

    @Test("A built-in id fails, and a duplicate id fails with the first file in name order winning")
    func idCollisions() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put(#"{"id": "\#(OverlayLook.glass.id.uuidString)", "name": "Impostor"}"#, "a.json", in: folder)
        try LookFixtures.put(#"{"id": "\#(LookFixtures.idA)", "name": "First"}"#, "b.json", in: folder)
        try LookFixtures.put(#"{"id": "\#(LookFixtures.idA)", "name": "Second"}"#, "c.json", in: folder)
        let report = LookFiles.load(from: folder)
        #expect(report.looks.map(\.name) == ["First"])
        #expect(report.failures.map(\.url.lastPathComponent) == ["a.json", "c.json"])
    }

    @Test("Files beyond the first 12 in name order are reported as over the limit and have no mapped URL")
    func overTheLimit() throws {
        let folder = try LookFixtures.folder()
        for number in 10..<24 {
            try LookFixtures.put(#"{"id": "\#(UUID().uuidString)", "name": "Look \#(number)"}"#, "look-\(number).json", in: folder)
        }
        let report = LookFiles.load(from: folder)
        #expect(report.looks.count == VizprSettings.maxLooks)
        #expect(report.urls.count == VizprSettings.maxLooks)
        #expect(report.failures.map(\.url.lastPathComponent) == ["look-22.json", "look-23.json"])
        #expect(report.failures.allSatisfy { $0.isOverLimit })
        #expect(LookFiles.load(from: folder, limit: .max).looks.count == 14)
    }

    @Test("A new look is named from its name, with a number on a collision and a fallback for an empty slug")
    func newFileNames() throws {
        let folder = try LookFixtures.folder()
        var look = OverlayLook.glass
        look.name = "Night Shift!"
        look.id = UUID()
        let first = try LookFiles.write(look, in: folder)
        look.id = UUID()
        let second = try LookFiles.write(look, in: folder)
        #expect(first.lastPathComponent == "night-shift.json")
        #expect(second.lastPathComponent == "night-shift-2.json")

        look.id = UUID(uuidString: LookFixtures.idA)!
        look.name = "★★★"
        #expect(try LookFiles.write(look, in: folder).lastPathComponent == "look-5a1b6a52.json")

        look.id = UUID()
        look.name = String(repeating: "abcdefghij ", count: 6)
        let long = try LookFiles.write(look, in: folder).deletingPathExtension().lastPathComponent
        #expect(long.count <= LookFiles.maxSlugLength)
        #expect(!long.hasSuffix("-"))
    }

    @Test("Writing a look that already has a file keeps that file's name")
    func fileIsNeverRenamed() throws {
        let folder = try LookFixtures.folder()
        var look = OverlayLook.glass
        look.id = UUID()
        look.name = "Before"
        let url = try LookFiles.write(look, in: folder)
        look.name = "After"
        #expect(try LookFiles.write(look, in: folder, at: url) == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["before.json"])
        #expect(LookFiles.load(from: folder).looks.first?.name == "After")
    }

    // The merge tests below were `VizprSettings.load(from:).looks` tests; the
    // names and assertions are kept.

    @Test("A saved look missing a field gets that field's default and keeps the rest")
    func lookMissingField() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put("""
        {"id": "\(LookFixtures.idA)", "name": "Mine", "cornerRadius": 12, "fontDesign": "serif"}
        """, "mine.json", in: folder)
        let look = try #require(LookFiles.load(from: folder).looks.first)
        #expect(look.name == "Mine")
        #expect(look.cornerRadius == 12)
        #expect(look.fontDesign == .serif)
        #expect(look.fontSize == OverlayLook.glass.fontSize)
        #expect(look.tintHex == OverlayLook.glass.tintHex)
    }

    @Test("A look with every field decodes the same whatever the merge template holds")
    func templateOnlyFillsMissingFields() throws {
        var look = OverlayLook.slab
        look.id = UUID()
        look.name = "Full"
        look.cornerRadius = 33
        look.tintHex = "123456"
        look.tintStrength = 0.4
        look.textBaseHex = "ABCDEF"
        look.colorsLinked = true
        look.slab.meshLoopSeconds = 12
        look.fontDesign = .serif
        look.fontSize = 20
        look.wordAppearance = .fade
        let folder = try LookFixtures.folder()
        try LookFiles.write(look, in: folder)

        var other = OverlayLook.mergeTemplate
        other.surface = .glass
        other.cornerRadius = 8
        other.tintHex = "000000"
        other.tintStrength = 0.5
        other.textBaseHex = "FFFFFF"
        other.colorsLinked = false
        other.slab.meshDrift = 0.5
        other.fontDesign = .monospaced
        other.fontSize = 28
        other.wordAppearance = .blurIn

        #expect(LookFiles.load(from: folder).looks == [look.clamped()])
        #expect(LookFiles.load(from: folder, template: other).looks == [look.clamped()])
    }

    @Test("A nested slab with only some keys merges with the rest defaulted")
    func partialSlab() throws {
        let folder = try LookFixtures.folder()
        try LookFixtures.put("""
        {"id": "\(LookFixtures.idA)", "name": "Mine", "surface": "slab", "slab": {"meshLoopSeconds": 12}}
        """, "mine.json", in: folder)
        let slab = try #require(LookFiles.load(from: folder).looks.first).slab
        #expect(slab.meshLoopSeconds == 12)
        #expect(slab.meshDrift == SlabStyle.default.meshDrift)
        #expect(slab.meshColorsHex == SlabStyle.defaultMeshColors)
    }

    @Test("The glass.json and slab.json files, decoded by the loader, equal the built-in constants")
    func builtInFilesMatchConstants() throws {
        #expect(try LookFiles.read(LookFixtures.sourceFile("glass.json")) == OverlayLook.glass)
        #expect(try LookFiles.read(LookFixtures.sourceFile("slab.json")) == OverlayLook.slab)
    }

    @Test("A built-in file placed in the Looks folder is refused, because its id is a built-in's")
    func builtInFileIsNotACustomLook() throws {
        let folder = try LookFixtures.folder()
        try FileManager.default.copyItem(
            at: LookFixtures.sourceFile("glass.json"), to: folder.appendingPathComponent("glass.json"))
        let report = LookFiles.load(from: folder)
        #expect(report.looks.isEmpty)
        #expect(report.failures.count == 1)
    }
}
