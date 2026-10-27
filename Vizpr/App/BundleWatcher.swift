import Darwin
import Dispatch
import Foundation
import os

/// Quits Vizpr when the app's own files disappear while it runs.
///
/// A process whose executable is gone cannot be mapped to a path by the OS, and
/// WindowServer then refuses the events its active tap hands back (2026-10-27).
/// Two signals, both on this watcher's private queue so a stuck main thread or
/// hotkey thread cannot silence them:
///
/// - a vnode watch on the executable for delete or rename, the primary signal;
///   it catches an atomic replace, where `proc_pidpath` keeps answering;
/// - a 2 s `proc_pidpath` poll, which catches losses the vnode watch misses.
///
/// Renaming the whole bundle fires neither and is correct: the identity stays
/// resolvable.
///
/// On loss, in order: arm `_exit` at 5 s; log the reason; tear the tap down on
/// the hotkey thread; if that finishes within 1 s, move `_exit` out to 60 s and
/// show the alert on main (the keyboard is already safe), otherwise leave the
/// 5 s `_exit` standing with no alert. `_exit`, not `exit`: `exit` runs atexit
/// handlers and C++ destructors that can block on a lock a wedged thread holds.
/// The `_exit` timer has its own queue, so a watcher queue blocked on a lock
/// cannot stop it.
final class BundleWatcher: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.kudzuweb.vizpr", category: "bundle")
    private static let pollInterval = DispatchTimeInterval.seconds(2)
    private static let hardExitDelay = DispatchTimeInterval.seconds(5)
    private static let hardExitDelayAfterTeardown = DispatchTimeInterval.seconds(60)
    private static let teardownGrace = DispatchTimeInterval.seconds(1)

    private let executableURL: URL
    private let terminatesProcess: Bool
    private let tearDownTap: @Sendable (_ done: @escaping @Sendable () -> Void) -> Void
    private let presentLoss: @Sendable () -> Void

    private let queue = DispatchQueue(label: "app.vizpr.bundle-watcher")
    private let exitQueue = DispatchQueue(label: "app.vizpr.bundle-watcher.exit")
    // Confined to `queue`.
    private var vnodeSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var exitTimer: DispatchSourceTimer?
    private var lost = false

    /// - Parameters:
    ///   - terminatesProcess: false under a test host, where the watcher tears the
    ///     tap down but never arms `_exit`, matching `failLoudly`.
    ///   - tearDownTap: queues the tap teardown on the hotkey thread without
    ///     waiting, and calls `done` from there when it has run.
    ///   - presentLoss: shows the alert on main and terminates; it may block.
    init(
        executableURL: URL,
        terminatesProcess: Bool,
        tearDownTap: @escaping @Sendable (_ done: @escaping @Sendable () -> Void) -> Void,
        presentLoss: @escaping @Sendable () -> Void
    ) {
        self.executableURL = executableURL
        self.terminatesProcess = terminatesProcess
        self.tearDownTap = tearDownTap
        self.presentLoss = presentLoss
    }

    func start() {
        queue.async { [self] in
            watchExecutable()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [self] in
                if !BundleIdentity.processPathResolves() {
                    handleLoss("proc_pidpath no longer resolves this process")
                }
            }
            pollTimer = timer
            timer.resume()
        }
    }

    private func watchExecutable() {
        let descriptor = open(executableURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The poll still covers a lost executable; quitting on a failed open
            // would risk quitting a healthy app.
            Self.log.error("bundle watcher: cannot open the executable for watching (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.delete, .rename], queue: queue
        )
        source.setEventHandler { [self] in handleLoss("the executable was deleted or renamed") }
        source.setCancelHandler { close(descriptor) }
        vnodeSource = source
        source.resume()
    }

    private func handleLoss(_ reason: String) {
        guard !lost else { return }
        lost = true
        armHardExit(after: Self.hardExitDelay)
        Self.log.fault("Vizpr's app files are gone (\(reason, privacy: .public)); quitting")
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("bundle lost: \(reason) — tearing down the tap and quitting")
        #endif

        let tornDown = DispatchSemaphore(value: 0)
        tearDownTap { tornDown.signal() }
        guard tornDown.wait(timeout: .now() + Self.teardownGrace) == .success else {
            Self.log.fault("hotkey thread did not tear the tap down within 1 s; the 5 s exit stands")
            return
        }
        armHardExit(after: Self.hardExitDelayAfterTeardown)
        presentLoss()
    }

    /// Replaces any earlier `_exit` timer. Does nothing when the process is not
    /// meant to die (test host).
    private func armHardExit(after delay: DispatchTimeInterval) {
        guard terminatesProcess else { return }
        exitTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: exitQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { _exit(EXIT_FAILURE) }
        exitTimer = timer
        timer.resume()
    }
}
