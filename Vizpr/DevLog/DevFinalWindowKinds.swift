#if DICT_DEV_LOG
import Foundation

/// The window kind (`pause`, `forced` or `commit`) behind each final the ASR
/// engine yields, in yield order. The engine pushes the kind immediately
/// before it yields the final; `DevDictationTracker.observe` pops one per
/// final it sees. `TokenEvent` stays free of dev-log fields this way.
enum DevFinalWindowKinds {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var kinds: [String] = []

    static func push(_ kind: String) {
        lock.lock()
        defer { lock.unlock() }
        kinds.append(kind)
    }

    static func pop() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return kinds.isEmpty ? nil : kinds.removeFirst()
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        kinds.removeAll()
    }
}
#endif
