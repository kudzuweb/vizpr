/// Decides whether a hotkey tap that the OS disabled may be re-armed.
///
/// A tap that macOS keeps disabling by timeout is being refused, not slow:
/// re-enabling it each time holds the keyboard in the instants between
/// disables. The policy counts timeout disables in a sliding window and, at the
/// limit, gives up. Giving up is a latch: `mayArm` stays false until `reset()`,
/// so nothing that merely calls `start()` again can bring the tap back.
///
/// Pure value type; `HotkeyMonitor` keeps one behind its `shared` lock.
struct TapDisablePolicy: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Re-enable the tap. `count` is the disables now inside the window.
        case reArm(count: Int)
        /// Stop re-arming and tear the tap down.
        case giveUp(count: Int)
    }

    let limit: Int
    let window: Duration

    private var disables: [MonotonicTime] = []
    private var latched = false

    init(limit: Int, window: Duration) {
        precondition(limit > 0, "a limit of zero would give up before the first disable")
        self.limit = limit
        self.window = window
    }

    /// False from the give-up until `reset()`.
    var mayArm: Bool { !latched }

    /// Count one OS-reported timeout disable seen at `now`. After a give-up every
    /// further disable is also a give-up.
    mutating func recordDisable(at now: MonotonicTime) -> Verdict {
        disables.removeAll { now.elapsed(since: $0) > window }
        disables.append(now)
        if disables.count >= limit { latched = true }
        return latched ? .giveUp(count: disables.count) : .reArm(count: disables.count)
    }

    /// An explicit user action reopens the latch and forgets the old disables.
    mutating func reset() {
        latched = false
        disables.removeAll()
    }
}
