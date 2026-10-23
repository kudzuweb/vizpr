import Foundation

/// A dedicated thread running its own CFRunLoop, so the hotkey event tap is
/// serviced even while the main thread is blocked (a cold `AVAudioEngine.start()`
/// stalls it for about two seconds, long enough for the OS to disable the tap).
///
/// Work is handed over with `perform` / `performAndWait`; blocks run in order.
/// Sources and timers are added and removed through the CFRunLoop APIs, which
/// are safe to call from any thread.
final class HotkeyRunLoopThread: @unchecked Sendable {
    private let thread: Thread
    private let runLoop: CFRunLoop

    init() {
        let started = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loop: CFRunLoop?
        thread = Thread {
            loop = CFRunLoopGetCurrent()
            // A run loop with no sources returns immediately; a port keeps it alive.
            RunLoop.current.add(Port(), forMode: .default)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "app.vizpr.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        runLoop = loop!
    }

    deinit {
        CFRunLoopStop(runLoop)
    }

    var isCurrent: Bool { Thread.current === thread }

    /// Queue `block` on the hotkey thread and return immediately.
    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Run `block` on the hotkey thread and wait for it to finish, up to `timeout`.
    /// Runs inline when already on the thread. Returns false if the wait timed out;
    /// the block still runs when the thread gets to it.
    @discardableResult
    func performAndWait(timeout: DispatchTimeInterval = .seconds(2), _ block: @escaping @Sendable () -> Void) -> Bool {
        if isCurrent {
            block()
            return true
        }
        let done = DispatchSemaphore(value: 0)
        perform {
            block()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    func add(source: CFRunLoopSource) {
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    func remove(source: CFRunLoopSource) {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }

    /// Create and schedule a timer on the hotkey thread's run loop. Invalidate it
    /// with `CFRunLoopTimerInvalidate`.
    func addTimer(interval: TimeInterval, repeats: Bool, _ handler: @escaping @Sendable () -> Void) -> CFRunLoopTimer {
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            repeats ? interval : 0,
            0, 0
        ) { _ in handler() }!
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        return timer
    }
}
