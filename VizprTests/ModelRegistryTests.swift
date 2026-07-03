import Foundation
import Testing
@testable import Vizpr

@Suite("ModelRegistry")
struct ModelRegistryTests {

    /// Build a throwaway user-models root with the given folder contents.
    private func makeRoot(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("Valid manifest with present files is usable")
    func validManifestIsUsable() async throws {
        let root = try makeRoot { root in
            let dir = root.appendingPathComponent("asr/my-model")
            try write(
                """
                {"id": "my-model", "displayName": "My Model", "kind": "asr",
                 "runtime": "fluidaudio-coreml", "language": "en", "files": ["weights.bin"]}
                """,
                to: dir.appendingPathComponent("manifest.json")
            )
            try write("fake-weights", to: dir.appendingPathComponent("weights.bin"))
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].isUsable)
        #expect(entries[0].manifest?.id == "my-model")
        #expect(entries[0].origin == .user)
    }

    @Test("Malformed manifest is rejected with a reason, not dropped")
    func malformedManifestDisabledWithReason() async throws {
        let root = try makeRoot { root in
            try write(
                "{this is not json",
                to: root.appendingPathComponent("asr/broken/manifest.json")
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(!entries[0].isUsable)
        #expect(entries[0].disabledReason?.contains("malformed manifest.json") == true)
    }

    @Test("Missing manifest disables the folder with a reason")
    func missingManifestDisabled() async throws {
        let root = try makeRoot { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("cleanup/mystery-folder"),
                withIntermediateDirectories: true
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].disabledReason == "no manifest.json")
    }

    @Test("Declared file missing on disk disables with the file named")
    func missingDeclaredFileDisabled() async throws {
        let root = try makeRoot { root in
            try write(
                """
                {"id": "partial", "displayName": "Partial", "kind": "cleanup",
                 "runtime": "mlx", "language": "en", "files": ["weights.safetensors"]}
                """,
                to: root.appendingPathComponent("cleanup/partial/manifest.json")
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].disabledReason == "missing declared file: weights.safetensors")
        #expect(entries[0].manifest?.id == "partial")   // manifest parsed, still shown
    }

    @Test("Nonexistent user root yields just the bundled list")
    func missingRootYieldsBundled() async throws {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-registry-nonexistent-\(UUID().uuidString)")
        let registry = ModelRegistry(userModelsRoot: ghost)
        let entries = await registry.scan()

        // The test host is the real app bundle, so both bundled models exist.
        // (allSatisfy hoisted out of #expect: keypath/rethrows calls confuse
        // the macro expansion into an unhandled-throw compile error.)
        let allBundled = entries.allSatisfy { $0.origin == .bundled }
        let allUsable = entries.allSatisfy(\.isUsable)
        let hasParakeet = entries.contains { $0.manifest?.id == "parakeet-tdt-0.6b-v2" }
        #expect(entries.count == 2)
        #expect(allBundled)
        #expect(allUsable)
        #expect(hasParakeet)
    }
}
