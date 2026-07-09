import Foundation

/// UI-facing model list (PR 11 Models pane): owns the scan results, rescans
/// on filesystem changes (drop a folder → it appears), and resolves a
/// selected model id to its on-disk directory for engine construction.
@MainActor
final class ModelsModel: ObservableObject {
    @Published private(set) var entries: [ModelEntry] = []

    let userRoot: URL
    private let bundled: [ModelEntry]
    private var watcher: ModelDirectoryWatcher?

    init(userRoot: URL = ModelRegistry.defaultUserRoot, bundled: [ModelEntry]? = nil) {
        self.userRoot = userRoot
        self.bundled = bundled ?? ModelRegistry.bundledEntries()
        rescan()
    }

    func rescan() {
        entries = ModelRegistry.performScan(userModelsRoot: userRoot, bundled: bundled)
    }

    /// Start live FS watching (idempotent). Separate from init so tests can
    /// exercise scanning without kqueue sources.
    func startWatching() {
        guard watcher == nil else { return }
        watcher = ModelDirectoryWatcher(root: userRoot) {
            Task { @MainActor [weak self] in self?.rescan() }
        }
    }

    /// Entries the pane lists for one selectable kind (vad is infrastructure).
    func entries(kind: ModelKind) -> [ModelEntry] {
        entries.filter { $0.manifest?.kind == kind }
    }

    /// Resolve a selected model id to its directory — usable entries only.
    /// nil id (bundled default) and any unresolvable id return nil, and the
    /// engine falls back to its bundled model: selection fails soft, never
    /// dead (PLAN.md §11).
    func directory(forID id: String?, kind: ModelKind) -> URL? {
        guard let id else { return nil }
        return entries.first {
            $0.isUsable && $0.manifest?.id == id && $0.manifest?.kind == kind
        }?.directory
    }
}
