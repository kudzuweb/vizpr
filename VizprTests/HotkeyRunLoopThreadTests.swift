import Foundation
import Testing
@testable import Vizpr

@Suite("HotkeyRunLoopThread")
struct HotkeyRunLoopThreadTests {

    @Test("Blocks run in order on the hotkey thread, not the caller's")
    func runsInOrderOffCaller() {
        let thread = HotkeyRunLoopThread()
        let seen = ThreadLog()
        for index in 0..<5 {
            thread.perform { seen.append("\(index)", onHotkeyThread: thread.isCurrent) }
        }
        #expect(thread.performAndWait { seen.append("done", onHotkeyThread: thread.isCurrent) })
        #expect(seen.entries == ["0", "1", "2", "3", "4", "done"])
        #expect(seen.allOnHotkeyThread)
        #expect(!thread.isCurrent)
    }

    @Test("A timer fires while the calling thread is blocked")
    func timerFiresWhileCallerBlocked() {
        let thread = HotkeyRunLoopThread()
        let fired = DispatchSemaphore(value: 0)
        let timer = thread.addTimer(interval: 0.05, repeats: false) { fired.signal() }
        // The caller stands in for a main thread stuck in a cold audio-engine start.
        let firedDuringBlock = fired.wait(timeout: .now() + 1) == .success
        CFRunLoopTimerInvalidate(timer)
        #expect(firedDuringBlock)
    }
}

private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Bool)] = []

    func append(_ entry: String, onHotkeyThread: Bool) {
        lock.withLock { items.append((entry, onHotkeyThread)) }
    }
    var entries: [String] { lock.withLock { items.map(\.0) } }
    var allOnHotkeyThread: Bool { lock.withLock { items.allSatisfy(\.1) } }
}
