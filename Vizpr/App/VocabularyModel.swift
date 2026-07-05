import Combine
import Foundation

/// Owns the live hierarchical vocabulary (PR 11): the Settings editor binds
/// to it, the session path resolves from it, edits persist immediately and
/// apply to the NEXT utterance (acceptance).
@MainActor
final class VocabularyModel: ObservableObject {
    @Published var library: VocabularyLibrary {
        didSet { try? store.saveLibrary(library) }
    }
    private let store: VocabularyStore

    init(store: VocabularyStore = VocabularyStore()) {
        self.store = store
        self.library = (try? store.loadLibrary()) ?? .empty
    }

    /// Hotkey/menu cycle; returns the new state's display name.
    @discardableResult
    func cycle() -> String {
        var lib = library
        let name = lib.cycleManualBucket()
        library = lib
        return name
    }
}
