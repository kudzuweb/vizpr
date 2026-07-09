import Foundation

/// Watches the user model directories for changes (PLAN.md §14, PR 11: the
/// Models pane updates live when a folder is dropped in — no relaunch, no
/// manual refresh). kqueue-backed DispatchSources on the asr/ and cleanup/
/// roots; events are debounced (a folder copy is many writes) and delivered
/// as a single callback.
///
/// Read-only observation of local directories — no file is ever written here.
final class ModelDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kudzuweb.vizpr.model-watch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let debounce: DispatchTimeInterval
    private let onChange: @Sendable () -> Void

    /// - Parameters:
    ///   - root: the user models root; its `asr/` and `cleanup/` children are
    ///     created (so there is something to watch and to reveal in Finder)
    ///     and then observed.
    ///   - onChange: fired on the watcher's queue after the debounce window.
    init(
        root: URL,
        debounce: DispatchTimeInterval = .milliseconds(300),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.debounce = debounce
        self.onChange = onChange

        for dir in [root.appendingPathComponent("asr", isDirectory: true),
                    root.appendingPathComponent("cleanup", isDirectory: true)] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            watch(dir)
        }
    }

    private func watch(_ directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    /// Debounce: a model drop is a burst of directory writes; collapse the
    /// burst into one rescan after the window closes.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            for source in sources { source.cancel() }
            sources.removeAll()
        }
    }

    deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
    }
}
