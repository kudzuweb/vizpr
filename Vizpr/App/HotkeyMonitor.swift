import AppKit
import Darwin

/// Thin CGEventTap shell around the pure `HotkeyStateMachine` (PLAN.md §6 + §8).
///
/// The shell does no decision logic — it translates CGEvents into machine inputs,
/// returns the machine's disposition to the OS, and re-arms itself when the OS
/// disables the tap. All the *behavior* (tap/hold/latch/commit) lives in the pure
/// machine; everything here is mechanism.
///
/// **Threading.** The tap is installed on the main run loop and every timer fires
/// on the main run loop, so `machine` and the edge-tracking fields are only ever
/// touched on the main thread. The C callback cannot be actor-isolated, so the
/// class is `@unchecked Sendable` with that single-threaded discipline asserted
/// in debug. The callback computes its disposition *synchronously* — it must,
/// because returning nil vs. the event is what suppresses or forwards the key.
///
/// **Fail-open.** The callback returns `.consume` (nil) only when the machine says
/// so, and the machine only ever says so for Fn events. No code path here can
/// suppress a non-Fn key. This is the inversion of the Wispr stale-key bug.
final class HotkeyMonitor: @unchecked Sendable {
    /// Escape virtual keycode.
    private static let escapeKeyCode: Int64 = 53

    private var machine: HotkeyStateMachine
    /// Edge tracking lives in a pure, tested value type (see `FlagEdgeTracker`):
    /// flagsChanged reports the whole flag set, so down/up edges are derived by
    /// comparison, and that comparison has real failure modes worth testing.
    private var edges: FlagEdgeTracker

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thresholdTimer: Timer?
    private var watchdogTimer: Timer?

    /// True once the callback has fired at least once. Reserved for an onboarding
    /// "press Fn to confirm" liveness step; not used to infer capability, because
    /// a freshly-granted but idle tap has legitimately observed nothing yet.
    private(set) var hasObservedEvent = false

    /// Dictation actions for the rest of the app to consume with `for await`.
    let actions: AsyncStream<DictationAction>
    private let actionsContinuation: AsyncStream<DictationAction>.Continuation

    init(holdThreshold: Duration = .milliseconds(200),
         secondaryMask: CGEventFlags = [.maskControl, .maskAlternate]) {
        self.machine = HotkeyStateMachine(holdThreshold: holdThreshold)
        self.edges = FlagEdgeTracker(secondaryMask: secondaryMask)
        (actions, actionsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        // Backstop against use-after-free: the tap holds an unretained pointer to
        // self, so it must never outlive the object. The monitor is only ever
        // owned on the main thread, so deinit runs there. Idempotent with stop().
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        thresholdTimer?.invalidate()
        watchdogTimer?.invalidate()
        actionsContinuation.finish()
    }

    // MARK: Lifecycle

    /// Install the tap on the main run loop. Returns false if the tap could not be
    /// created (almost always missing Accessibility) — the caller drives the
    /// permission flow via `PermissionProbe` and retries.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard machPort == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,                 // active tap: required to consume Fn
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        machPort = port
        runLoopSource = source
        startWatchdog()
        return true
    }

    @MainActor
    func stop() {
        thresholdTimer?.invalidate(); thresholdTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = machPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        runLoopSource = nil
        machPort = nil
        edges.reset()
        // Discard any in-flight session so a later start() cannot resume a
        // phantom latched/pressed state and mis-commit on the first press.
        // tapDisabled has exactly the semantics we want: cancel-from-active,
        // inert-from-idle, and it routes a .cancel to the pipeline if one is
        // listening. apply() also tears down the threshold timer via the sync.
        apply(machine.handle(.tapDisabled(.timeout)))
    }

    /// Whether the tap currently reports healthy. The watchdog re-enables a dead
    /// tap; a `false` here with permission granted is the "granted but dead"
    /// signal the onboarding flow watches for.
    @MainActor
    var isTapHealthy: Bool {
        guard let port = machPort else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    /// Feed a VAD-silence auto-stop into the state machine (PLAN.md §6): the
    /// same single commit path as a key press — the machine commits only from
    /// `latched` and ignores this everywhere else. Never a bypass.
    @MainActor
    func injectAutoStop() {
        apply(machine.handle(.autoStop))
    }

    // MARK: Event handling (called from the tap callback, on the main thread)

    /// Translate one CGEvent into machine input(s) and return its disposition.
    /// `nil` return means "suppress"; a passed-back event means "forward."
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        assertMainThread()
        hasObservedEvent = true

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The OS disabled us (slow callback or secure input). Re-enable and
            // reset BOTH the machine and the edge tracker: a press whose release
            // was missed while we were disabled must not strand `fnDown` true and
            // swallow the next press's edge.
            reEnableTap()
            apply(machine.handle(.tapDisabled(type == .tapDisabledByTimeout ? .timeout : .userInput)))
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            return handleFlagsChanged(event)

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
                // Escape only matters while dictating; the machine returns
                // passThrough regardless, so Escape always also reaches the app.
                let decision = machine.handle(.escape)
                apply(decision)
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = nowMonotonic()

        // One packet can toggle both Fn and the secondary combo, so process every
        // edge it produces — never early-return after Fn. Only an Fn edge can ever
        // set `suppress`, so a non-Fn modifier change is never deleted.
        var suppress = false
        for edge in edges.edges(for: event.flags) {
            let decision = machine.handle(input(for: edge, at: now))
            apply(decision)
            if decision.disposition == .consume { suppress = true }
        }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func input(for edge: FlagEdgeTracker.Edge, at now: MonotonicTime) -> HotkeyInput {
        switch edge {
        case .fnDown: return .fnDown(at: now)
        case .fnUp: return .fnUp(at: now)
        case .secondaryDown: return .secondaryDown(at: now)
        case .secondaryUp: return .secondaryUp(at: now)
        }
    }

    /// Re-enable a disabled tap and clear edge state (fail-open: assume nothing is
    /// held). Shared by the in-callback disable path and the watchdog.
    private func reEnableTap() {
        if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
        edges.reset()
    }

    /// Forward any dictation action and keep the threshold timer in sync with the
    /// machine's state.
    private func apply(_ decision: HotkeyDecision) {
        if let action = decision.action {
            actionsContinuation.yield(action)
        }
        syncThresholdTimer()
    }

    /// Arm a one-shot timer while in `pressed` so a long hold is promoted to
    /// `holding` even with no further key events; tear it down otherwise.
    ///
    /// This runs inside the synchronous tap callback, which the spec wants to keep
    /// to "translation only." A single `Timer` alloc/invalidate is cheap relative
    /// to the tap deadline, and it is doubly safety-netted: the watchdog re-enables
    /// a deadline-killed tap, and `release()` re-checks the hold duration anyway,
    /// so even a dropped threshold timer never changes the commit outcome.
    private func syncThresholdTimer() {
        if case .pressed = machine.state {
            guard thresholdTimer == nil else { return }
            let timer = Timer(timeInterval: machine.holdThreshold.seconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.apply(self.machine.handle(.thresholdElapsed(at: self.nowMonotonic())))
            }
            RunLoop.main.add(timer, forMode: .common)
            thresholdTimer = timer
        } else {
            thresholdTimer?.invalidate()
            thresholdTimer = nil
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let port = self.machPort else { return }
            if !CGEvent.tapIsEnabled(tap: port) {
                // Reset any in-flight press and edge state: a tap that died
                // mid-session is already broken, and a clean idle is fail-open.
                self.reEnableTap()
                self.apply(self.machine.handle(.tapDisabled(.timeout)))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    // MARK: Helpers

    private func nowMonotonic() -> MonotonicTime {
        MonotonicTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private func assertMainThread() {
        #if DEBUG
        precondition(Thread.isMainThread, "HotkeyMonitor must only be touched on the main thread")
        #endif
    }
}

private extension Duration {
    /// Seconds as a Double, for Timer intervals.
    var seconds: Double {
        let (whole, atto) = components
        return Double(whole) + Double(atto) / 1e18
    }
}

// MARK: - C callback bridge

/// Top-level `@convention(c)` callback: it cannot capture context, so the monitor
/// is recovered from the opaque `userInfo` pointer. Runs on the main run loop
/// (where the source is installed).
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
