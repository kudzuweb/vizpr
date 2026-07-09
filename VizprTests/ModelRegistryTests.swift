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
        // Field catch (Mauria, 2026-07-09): a manifest-less folder has no
        // manifest kind, so the pane's per-kind lists dropped it entirely —
        // "i put a test folder in asr and don't see anything". The kind must
        // come from the FOLDER so the row appears where it was dropped.
        #expect(entries[0].kind == .cleanup)
    }

    @Test("Manifest kind contradicting its folder is disabled with both named")
    func manifestFolderKindMismatch() async throws {
        let root = try makeRoot { root in
            try write(
                """
                {"id": "misfiled", "displayName": "Misfiled", "kind": "cleanup",
                 "runtime": "mlx", "language": "en", "files": []}
                """,
                to: root.appendingPathComponent("asr/misfiled/manifest.json")
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].kind == .asr, "shown in the list it was dropped into")
        #expect(entries[0].disabledReason
            == "manifest says kind 'cleanup' but the folder is under asr/")
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

        // The test host is the real app bundle, so all bundled models exist.
        // (allSatisfy hoisted out of #expect: keypath/rethrows calls confuse
        // the macro expansion into an unhandled-throw compile error.)
        let allBundled = entries.allSatisfy { $0.origin == .bundled }
        let allUsable = entries.allSatisfy(\.isUsable)
        let hasParakeet = entries.contains { $0.manifest?.id == ModelRegistry.bundledASRID }
        let hasQwen = entries.contains { $0.manifest?.id == ModelRegistry.bundledCleanupID }
        let sized = entries.allSatisfy { ($0.sizeBytes ?? 0) > 0 }
        #expect(entries.count == 3)
        #expect(allBundled)
        #expect(allUsable)
        #expect(hasParakeet)
        #expect(hasQwen)
        #expect(sized, "scan must report bundled model sizes for the pane")
    }

    @Test("Unsupported runtime is disabled with the runtime named")
    func unsupportedRuntimeDisabled() async throws {
        let root = try makeRoot { root in
            try write(
                """
                {"id": "onnx-thing", "displayName": "Onnx Thing", "kind": "asr",
                 "runtime": "onnx", "language": "en", "files": []}
                """,
                to: root.appendingPathComponent("asr/onnx-thing/manifest.json")
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].disabledReason == "unsupported runtime: onnx")
        #expect(entries[0].manifest?.id == "onnx-thing")   // manifest parsed, still shown
    }

    @Test("Kind/runtime mismatch is disabled — an MLX 'asr' model is unloadable")
    func kindRuntimeMismatchDisabled() async throws {
        let root = try makeRoot { root in
            try write(
                """
                {"id": "mlx-asr", "displayName": "MLX ASR", "kind": "asr",
                 "runtime": "mlx", "language": "en", "files": []}
                """,
                to: root.appendingPathComponent("asr/mlx-asr/manifest.json")
            )
        }
        let registry = ModelRegistry(userModelsRoot: root, bundled: [])
        let entries = await registry.scan()

        #expect(entries.count == 1)
        #expect(entries[0].disabledReason?.contains("can't drive an asr model") == true)
        #expect(entries[0].disabledReason?.contains("fluidaudio-coreml") == true)
    }
}

@Suite("ModelsModel")
@MainActor
struct ModelsModelTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-modelsmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeModel(
        _ root: URL, kindDir: String, folder: String, manifest: String
    ) throws {
        let dir = root.appendingPathComponent("\(kindDir)/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(
            to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
        )
    }

    @Test("directory(forID:) resolves usable ids; nil, unknown, and disabled ids fall back")
    func directoryResolution() throws {
        let root = try makeRoot()
        try writeModel(
            root, kindDir: "asr", folder: "good",
            manifest: """
            {"id": "good-asr", "displayName": "Good", "kind": "asr",
             "runtime": "fluidaudio-coreml", "language": "en", "files": []}
            """
        )
        try writeModel(
            root, kindDir: "asr", folder: "broken",
            manifest: """
            {"id": "broken-asr", "displayName": "Broken", "kind": "asr",
             "runtime": "fluidaudio-coreml", "language": "en", "files": ["gone.bin"]}
            """
        )
        let model = ModelsModel(userRoot: root, bundled: [])

        #expect(model.directory(forID: "good-asr", kind: .asr)?.lastPathComponent == "good")
        // Fail soft to bundled (nil directory), never dead:
        #expect(model.directory(forID: nil, kind: .asr) == nil)
        #expect(model.directory(forID: "no-such-model", kind: .asr) == nil)
        #expect(model.directory(forID: "broken-asr", kind: .asr) == nil, "disabled is not selectable")
        #expect(model.directory(forID: "good-asr", kind: .cleanup) == nil, "kind must match")
    }

    @Test("entries(kind:) filters selectable kinds — vad never appears")
    func kindFiltering() throws {
        let root = try makeRoot()
        let bundled = ModelRegistry.bundledEntries()
        let model = ModelsModel(userRoot: root, bundled: bundled)

        let asrIDs = model.entries(kind: .asr).compactMap { $0.manifest?.id }
        let cleanupIDs = model.entries(kind: .cleanup).compactMap { $0.manifest?.id }
        #expect(asrIDs == [ModelRegistry.bundledASRID])
        #expect(cleanupIDs == [ModelRegistry.bundledCleanupID])
        #expect(!asrIDs.contains("silero-vad") && !cleanupIDs.contains("silero-vad"))
    }

    @Test("A manifest-less folder still appears in the list it was dropped into")
    func manifestlessFolderListed() throws {
        let root = try makeRoot()
        let dir = root.appendingPathComponent("asr/mystery")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not a model".write(
            to: dir.appendingPathComponent("stuff.txt"), atomically: true, encoding: .utf8
        )
        let model = ModelsModel(userRoot: root, bundled: [])

        let asrEntries = model.entries(kind: .asr)
        #expect(asrEntries.count == 1)
        #expect(asrEntries[0].disabledReason == "no manifest.json")
        #expect(model.entries(kind: .cleanup).isEmpty)
    }

    @Test("Model-id settings clamp: empty string becomes nil (bundled)")
    func modelIDClamp() {
        var s = VizprSettings.default
        s.asrModelID = ""
        s.cleanupModelID = "some-model"
        let clamped = s.clamped()
        #expect(clamped.asrModelID == nil)
        #expect(clamped.cleanupModelID == "some-model")
    }
}

@Suite("ModelDirectoryWatcher")
struct ModelDirectoryWatcherTests {
    @Test("A folder dropped into asr/ fires a debounced change")
    func firesOnDrop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-watch-\(UUID().uuidString)")
        let counter = AtomicCounter()
        let watcher = ModelDirectoryWatcher(
            root: root, debounce: .milliseconds(50)
        ) { counter.increment() }
        defer { watcher.stop() }

        // The watcher creates asr/ and cleanup/ so there is something to watch.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("asr").path))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("asr/dropped-model"),
            withIntermediateDirectories: true
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while counter.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.value >= 1, "drop must trigger a rescan callback")
    }
}
