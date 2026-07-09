import Foundation

/// A model's role in the pipeline.
enum ModelKind: String, Codable, Sendable {
    case asr
    case cleanup
    /// Voice-activity detection. Infrastructure, not user-swappable: it ships
    /// bundled and never appears in a Settings selection list.
    case vad
}

/// The inference runtime a model requires. A model of a supported runtime is
/// genuinely drop-in; a new runtime needs a new engine conformer (PLAN.md §11).
enum ModelRuntime: String, Codable, Sendable {
    case fluidAudioCoreML = "fluidaudio-coreml"
    case mlx

    /// Which runtime each swappable kind's engine can drive today.
    static func required(for kind: ModelKind) -> ModelRuntime? {
        switch kind {
        case .asr: return .fluidAudioCoreML
        case .cleanup: return .mlx
        case .vad: return nil
        }
    }
}

/// Per-folder manifest, `manifest.json` in each user model directory.
/// `runtime` stays a raw string so a manifest declaring a runtime this build
/// can't drive is shown disabled WITH the runtime named, instead of decoding
/// as "malformed manifest.json".
struct ModelManifest: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let kind: ModelKind
    let runtime: String
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
    /// On-disk footprint, filled in by scan (nil when the folder is absent).
    var sizeBytes: Int64?

    enum Origin: Sendable, Equatable {
        case bundled
        case user
    }

    var isUsable: Bool { disabledReason == nil }
}

/// Scans model directories and publishes what is available (PLAN.md §11).
/// Bundled models are registered programmatically (they ship in the read-only
/// app bundle, pinned by the build — no manifest needed); user models live
/// under Application Support and each needs a `manifest.json`. The scan core
/// is a nonisolated static so the Settings UI (MainActor) can rescan
/// synchronously on filesystem events; the actor wrapper remains for
/// pipeline-side callers.
/// The registry never downloads anything: it only reads local folders.
actor ModelRegistry {
    private(set) var entries: [ModelEntry] = []

    private let userModelsRoot: URL
    private let bundledModels: [ModelEntry]

    static let bundledASRID = "parakeet-tdt-0.6b-v2"
    static let bundledCleanupID = "qwen3-4b-instruct-2507-4bit"

    /// Default user models root: ~/Library/Application Support/Vizpr/Models/.
    static var defaultUserRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vizpr/Models", isDirectory: true)
    }

    init(userModelsRoot: URL = ModelRegistry.defaultUserRoot, bundled: [ModelEntry]? = nil) {
        self.userModelsRoot = userModelsRoot
        self.bundledModels = bundled ?? Self.bundledEntries()
    }

    /// The models this build ships with. Registered without manifests: the
    /// build itself is their provenance, and their disabled state is derived
    /// from actual on-disk presence (a missing ASR bundle is visible in the
    /// registry rather than only exploding at engine load).
    static func bundledEntries() -> [ModelEntry] {
        func bundledEntry(
            id: String, name: String, kind: ModelKind, runtime: ModelRuntime,
            subdirectory: String
        ) -> ModelEntry {
            let dir = Bundle.main.resourceURL!.appendingPathComponent("Models/\(subdirectory)")
            let present = FileManager.default.fileExists(atPath: dir.path)
            return ModelEntry(
                manifest: ModelManifest(
                    id: id, displayName: name, kind: kind,
                    runtime: runtime.rawValue, language: "en", files: []
                ),
                directory: dir,
                origin: .bundled,
                disabledReason: present ? nil : "bundled model missing from app bundle"
            )
        }
        return [
            bundledEntry(
                id: bundledASRID, name: "Parakeet TDT v2 (bundled)",
                kind: .asr, runtime: .fluidAudioCoreML, subdirectory: "parakeet-tdt-0.6b-v2"
            ),
            bundledEntry(
                id: bundledCleanupID, name: "Qwen3 4B Instruct (bundled)",
                kind: .cleanup, runtime: .mlx, subdirectory: "cleanup-llm"
            ),
            bundledEntry(
                id: "silero-vad", name: "Silero VAD (bundled)",
                kind: .vad, runtime: .fluidAudioCoreML, subdirectory: "silero-vad"
            )
        ]
    }

    /// Scan bundled + user models. Never throws: unusable entries are published
    /// as disabled-with-reason so Settings can show them, and an unreadable root
    /// simply yields the bundled list.
    @discardableResult
    func scan() -> [ModelEntry] {
        entries = Self.performScan(userModelsRoot: userModelsRoot, bundled: bundledModels)
        return entries
    }

    /// The synchronous scan core (also called directly by ModelsModel on the
    /// main actor — a scan is a directory listing plus a few manifest decodes).
    nonisolated static func performScan(
        userModelsRoot: URL, bundled: [ModelEntry]
    ) -> [ModelEntry] {
        var found = bundled

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

        return found.map { entry in
            var sized = entry
            sized.sizeBytes = folderSize(entry.directory)
            return sized
        }
    }

    /// Validate one user model folder into an entry.
    private nonisolated static func entry(for directory: URL) -> ModelEntry {
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

        // The runtime must be one this build's engines can drive, and it must
        // match the model's kind — an MLX "asr" model would be selectable but
        // unloadable, so it is disabled here with the mismatch named.
        guard let runtime = ModelRuntime(rawValue: manifest.runtime) else {
            return ModelEntry(
                manifest: manifest, directory: directory, origin: .user,
                disabledReason: "unsupported runtime: \(manifest.runtime)"
            )
        }
        guard let required = ModelRuntime.required(for: manifest.kind) else {
            return ModelEntry(
                manifest: manifest, directory: directory, origin: .user,
                disabledReason: "\(manifest.kind.rawValue) models are not user-swappable"
            )
        }
        if runtime != required {
            return ModelEntry(
                manifest: manifest, directory: directory, origin: .user,
                disabledReason: "runtime '\(runtime.rawValue)' can't drive an "
                    + "\(manifest.kind.rawValue) model — needs '\(required.rawValue)'"
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

    /// Total allocated bytes under a folder; nil when it doesn't exist.
    nonisolated static func folderSize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                  at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              ) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
