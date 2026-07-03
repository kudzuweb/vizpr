import Foundation

/// A model's role in the pipeline.
enum ModelKind: String, Codable, Sendable {
    case asr
    case cleanup
}

/// The inference runtime a model requires. A model of a supported runtime is
/// genuinely drop-in; a new runtime needs a new engine conformer (PLAN.md §11).
enum ModelRuntime: String, Codable, Sendable {
    case fluidAudioCoreML = "fluidaudio-coreml"
    case mlx
}

/// Per-folder manifest, `manifest.json` in each user model directory.
struct ModelManifest: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let kind: ModelKind
    let runtime: ModelRuntime
    let language: String
    let files: [String]
}

/// One discovered model: valid and selectable, or disabled with a reason the
/// Settings UI can show verbatim.
struct ModelEntry: Sendable, Equatable {
    let manifest: ModelManifest?
    let directory: URL
    let origin: Origin
    /// nil when the entry is usable; otherwise why it is disabled.
    let disabledReason: String?

    enum Origin: Sendable, Equatable {
        case bundled
        case user
    }

    var isUsable: Bool { disabledReason == nil }
}

/// Scans model directories and publishes what is available (PLAN.md §11, PR 4
/// skeleton). Bundled models are registered programmatically (they ship in the
/// read-only app bundle, pinned by the build — no manifest needed); user models
/// live under Application Support and each needs a `manifest.json`. Filesystem
/// watching for live updates is stubbed until PR 11 (Settings).
/// The registry never downloads anything: it only reads local folders.
actor ModelRegistry {
    private(set) var entries: [ModelEntry] = []

    private let userModelsRoot: URL
    private let bundledModels: [ModelEntry]

    /// Default user models root: ~/Library/Application Support/Vizpr/Models/.
    static var defaultUserRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vizpr/Models", isDirectory: true)
    }

    init(userModelsRoot: URL = ModelRegistry.defaultUserRoot, bundled: [ModelEntry]? = nil) {
        self.userModelsRoot = userModelsRoot
        self.bundledModels = bundled ?? Self.defaultBundledEntries()
    }

    /// The two models this build ships with. Registered without manifests: the
    /// build itself is their provenance, and their disabled state is derived
    /// from actual on-disk presence (a missing ASR bundle is visible in the
    /// registry rather than only exploding at engine load).
    private static func defaultBundledEntries() -> [ModelEntry] {
        func bundledEntry(id: String, name: String, kind: ModelKind, subdirectory: String) -> ModelEntry {
            let dir = Bundle.main.resourceURL!.appendingPathComponent("Models/\(subdirectory)")
            let present = FileManager.default.fileExists(atPath: dir.path)
            return ModelEntry(
                manifest: ModelManifest(
                    id: id, displayName: name, kind: kind,
                    runtime: .fluidAudioCoreML, language: "en", files: []
                ),
                directory: dir,
                origin: .bundled,
                disabledReason: present ? nil : "bundled model missing from app bundle"
            )
        }
        return [
            bundledEntry(
                id: "parakeet-tdt-0.6b-v2", name: "Parakeet TDT v2 (bundled)",
                kind: .asr, subdirectory: "parakeet-tdt-0.6b-v2"
            ),
            bundledEntry(
                id: "silero-vad", name: "Silero VAD (bundled)",
                kind: .asr, subdirectory: "silero-vad"
            )
        ]
    }

    /// Scan bundled + user models. Never throws: unusable entries are published
    /// as disabled-with-reason so Settings can show them, and an unreadable root
    /// simply yields the bundled list.
    @discardableResult
    func scan() -> [ModelEntry] {
        var found = bundledModels

        let fm = FileManager.default
        for kindDir in ["asr", "cleanup"] {
            let root = userModelsRoot.appendingPathComponent(kindDir, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                found.append(entry(for: dir))
            }
        }

        entries = found
        return found
    }

    /// Validate one user model folder into an entry.
    private func entry(for directory: URL) -> ModelEntry {
        let manifestURL = directory.appendingPathComponent("manifest.json")

        guard let data = try? Data(contentsOf: manifestURL) else {
            return ModelEntry(
                manifest: nil, directory: directory, origin: .user,
                disabledReason: "no manifest.json"
            )
        }
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            return ModelEntry(
                manifest: nil, directory: directory, origin: .user,
                disabledReason: "malformed manifest.json: \(error.localizedDescription)"
            )
        }

        // Every declared file must exist — a partially copied model folder is
        // disabled with the missing file named, not half-loaded.
        for file in manifest.files {
            let path = directory.appendingPathComponent(file).path
            if !FileManager.default.fileExists(atPath: path) {
                return ModelEntry(
                    manifest: manifest, directory: directory, origin: .user,
                    disabledReason: "missing declared file: \(file)"
                )
            }
        }

        return ModelEntry(manifest: manifest, directory: directory, origin: .user, disabledReason: nil)
    }
}
