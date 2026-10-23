import AppKit
import Darwin
import os

/// Thin CGEventTap shell around the pure `HotkeyStateMachine` (PLAN.md §6 + §8).
///
/// The shell does no decision logic — it translates CGEvents into machine inputs,
/// returns the machine's disposition to the OS, and re-arms itself when the OS
/// disables the tap. All the *behavior* (tap/hold/latch/commit) lives in the pure
/// machine; everything here is mechanism.
///
/// **Threading.** The tap source and both timers live on a dedicated run loop
/// thread (`HotkeyRunLoopThread`), so a blocked main thread cannot starve the tap.
/// `machine`, `edges`, the source and the timers are only ever touched on that
/// thread; the public entry points hop onto it. The tap port is shared with the
/// main thread (`isTapHealthy`) behind a lock. The C callback cannot be
/// actor-isolated, so the class is `@unchecked Sendable` with that discipline
/// asserted in debug. The callback computes its disposition *synchronously* — it
/// must, because returning nil vs. the event is what suppresses or forwards the key.
///
/// **Fail-open.** The callback returns `.consume` (nil) only when the machine says
/// so, and the machine only ever says so for Fn events. No code path here can
/// suppress a non-Fn key. This is the inversion of the Wispr stale-key bug.
final class HotkeyMonitor: @unchecked Sendable {
    /// Escape virtual keycode.
    private static let escapeKeyCode: Int64 = 53

    private let runLoopThread = HotkeyRunLoopThread()

    // Hotkey-thread state.
    private var machine: HotkeyStateMachine
    /// Edge tracking lives in a pure, tested value type (see `FlagEdgeTracker`):
    /// flagsChanged reports the whole flag set, so down/up edges are derived by
    /// comparison, and that comparison has real failure modes worth testing.
    private var edges: FlagEdgeTracker
    private var runLoopSource: CFRunLoopSource?
    private var thresholdTimer: CFRunLoopTimer?
    private var watchdogTimer: CFRunLoopTimer?

    /// State read from more than one thread.
    private struct Shared: @unchecked Sendable {
        var port: CFMachPort?
        var hasObservedEvent = false
    }
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())

    private var machPort: CFMachPort? { shared.withLockUnchecked { $0.port } }

    /// True once the callback has fired at least once. Reserved for an onboarding
    /// "press Fn to confirm" liveness step; not used to infer capability, because
    /// a freshly-granted but idle tap has legitimately observed nothing yet.
    var hasObservedEvent: Bool { shared.withLockUnchecked { $0.hasObservedEvent } }

    /// Live setting (PR 11): applies from the next press — replacing the
    /// machine preserves its current state so a mid-session change is safe.
    func setHoldThreshold(_ threshold: Duration) {
        runLoopThread.perform { [self] in
            machine = HotkeyStateMachine(holdThreshold: threshold, state: machine.state)
        }
    }

    /// Live setting (PR 11): reassign the secondary chord. A fresh tracker
    /// is unseeded, so it silently adopts the current flag state as its
    /// baseline (no phantom edges).
    func setSecondaryMask(_ mask: CGEventFlags) {
        runLoopThread.perform { [self] in
            edges = FlagEdgeTracker(secondaryMask: mask)
        }
    }

    /// Dictation actions for the rest of the app to consume with `for await`.
    let actions: AsyncStream<DictationAction>
    private let actionsContinuation: AsyncStream<DictationAction>.Continuation

    init(holdThreshold: Duration = .milliseconds(280),
         secondaryMask: CGEventFlags = [.maskControl, .maskAlternate]) {
        self.machine = HotkeyStateMachine(holdThreshold: holdThreshold)
        self.edges = FlagEdgeTracker(secondaryMask: secondaryMask)
        (actions, actionsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        // Backstop against use-after-free: the tap holds an unretained pointer to
        // self, so it must never outlive the object. Waiting for the teardown also
        // waits out a callback still running on the hotkey thread. Idempotent
        // with stop().
        let installed = InstalledTap(port: machPort, source: runLoopSource,
                                     timers: [thresholdTimer, watchdogTimer].compactMap { $0 })
        let thread = runLoopThread
        thread.performAndWait { installed.tearDown(on: thread) }
        actionsContinuation.finish()
    }

    // MARK: Lifecycle

    /// Install the tap on the hotkey thread's run loop. Returns false if the tap
    /// could not be created (almost always missing Accessibility) — the caller
    /// drives the permission flow via `PermissionProbe` and retries.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard machPort == nil else { return true }
        // Created here, on the caller's thread, so the Bool result is immediate;
        // only the run-loop source is attached on the hotkey thread.

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

        shared.withLockUnchecked { $0.port = port }
        let installed = InstalledTap(port: port, source: CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
        runLoopThread.performAndWait { [self] in
            runLoopSource = installed.source
            if let source = installed.source { runLoopThread.add(source: source) }
            installed.port.map { CGEvent.tapEnable(tap: $0, enable: true) }
            startWatchdog()
        }
        return true
    }

    /// Remove the tap and reset all state before returning; the wait is bounded
    /// so a wedged hotkey thread cannot hang a permission flow or app quit.
    @MainActor
    func stop() {
        runLoopThread.performAndWait { [self] in
            InstalledTap(port: machPort, source: runLoopSource,
                         timers: [thresholdTimer, watchdogTimer].compactMap { $0 })
                .tearDown(on: runLoopThread)
            shared.withLockUnchecked { $0.port = nil }
            runLoopSource = nil
            thresholdTimer = nil
            watchdogTimer = nil
            edges.reset()
            // Discard any in-flight session so a later start() cannot resume a
            // phantom latched/pressed state and mis-commit on the first press.
            // tapDisabled has exactly the semantics we want: cancel-from-active,
            // inert-from-idle, and it routes a .cancel to the pipeline if one is
            // listening. apply() also tears down the threshold timer via the sync.
            apply(machine.handle(.tapDisabled(.timeout)))
        }
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
        runLoopThread.perform { [self] in
            apply(machine.handle(.autoStop))
        }
    }

    /// End the session when audio capture dies: the machine cancels from any
    /// active state, so a dead recording cannot leave the hotkey latched.
    func injectCaptureFailure() {
        runLoopThread.perform { [self] in
            apply(machine.handle(.captureFailed))
        }
    }

    // MARK: Event handling (called from the tap callback, on the hotkey thread)

    /// Translate one CGEvent into machine input(s) and return its disposition.
    /// `nil` return means "suppress"; a passed-back event means "forward."
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        assertOnHotkeyThread()
        shared.withLockUnchecked { $0.hasObservedEvent = true }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The OS disabled us (slow callback or secure input). Re-enable and
            // reset BOTH the machine and the edge tracker: a press whose release
            // was missed while we were disabled must not strand `fnDown` true and
            // swallow the next press's edge.
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note(
                "tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "userInput") — re-enabling"
            )
            #endif
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
        // Edges carry the event's own time: a callback serviced late (main thread
        // blocked) must still see a quick tap as a quick tap.
        let handledAt = nowMonotonic()
        let converted = EventTimestamp.converted(eventTicks: event.timestamp, handledAt: handledAt)
        let now = converted ?? handledAt

        // One packet can toggle both Fn and the secondary combo, so process every
        // edge it produces — never early-return after Fn. Only an Fn edge can ever
        // set `suppress`, so a non-Fn modifier change is never deleted.
        var suppress = false
        let found = edges.edges(for: event.flags)
        #if DICT_DEV_LOG
        logTimestampPathOnce(edges: found, rawTicks: event.timestamp, converted: converted, handledAt: handledAt)
        #endif
        for edge in found {
            let decision = machine.handle(input(for: edge, at: now))
            apply(decision)
            if decision.disposition == .consume { suppress = true }
        }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }

    #if DICT_DEV_LOG
    private var loggedTimestampPath = false

    /// Once per launch, on the first Fn edge: records whether the event stamp was
    /// converted or fell back to handling time, with the raw numbers, so a wrong
    /// unit assumption is visible. Numbers only, no typed text.
    private func logTimestampPathOnce(
        edges: [FlagEdgeTracker.Edge], rawTicks: UInt64, converted: MonotonicTime?, handledAt: MonotonicTime
    ) {
        guard !loggedTimestampPath, edges.contains(where: { $0 == .fnDown || $0 == .fnUp }) else { return }
        loggedTimestampPath = true
        VizprTranscriptLogger.note(
            "hotkey event stamp: \(converted == nil ? "fell back to handling time" : "converted") "
            + "rawTicks=\(rawTicks) convertedNs=\(converted?.nanoseconds.description ?? "-") "
            + "uptimeNs=\(handledAt.nanoseconds)"
        )
    }
    #endif

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
            let interval = machine.holdThreshold.seconds
            thresholdTimer = runLoopThread.addTimer(interval: interval, repeats: false) { [weak self] in
                guard let self else { return }
                self.apply(self.machine.handle(.thresholdElapsed(at: self.nowMonotonic())))
            }
        } else {
            thresholdTimer.map { CFRunLoopTimerInvalidate($0) }
            thresholdTimer = nil
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdogTimer = runLoopThread.addTimer(interval: 2.0, repeats: true) { [weak self] in
            guard let self, let port = self.machPort else { return }
            if !CGEvent.tapIsEnabled(tap: port) {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("tap watchdog: tap found dead — re-enabling")
                #endif
                // Reset any in-flight press and edge state: a tap that died
                // mid-session is already broken, and a clean idle is fail-open.
                self.reEnableTap()
                self.apply(self.machine.handle(.tapDisabled(.timeout)))
            }
        }
    }

    // MARK: Helpers

    private func nowMonotonic() -> MonotonicTime {
        MonotonicTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    private func assertOnHotkeyThread() {
        #if DEBUG
        precondition(runLoopThread.isCurrent, "HotkeyMonitor state must only be touched on the hotkey thread")
        #endif
    }
}

/// What `start()` installs, gathered so `stop()` and `deinit` remove it the same
/// way. CF objects are not `Sendable`; the box is only handed to the hotkey thread.
private struct InstalledTap: @unchecked Sendable {
    var port: CFMachPort?
    var source: CFRunLoopSource?
    var timers: [CFRunLoopTimer] = []

    /// Must run on the hotkey thread so it is ordered after any callback in flight.
    func tearDown(on thread: HotkeyRunLoopThread) {
        timers.forEach { CFRunLoopTimerInvalidate($0) }
        if let source { thread.remove(source: source) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
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
/// is recovered from the opaque `userInfo` pointer. Runs on the hotkey thread's
/// run loop (where the source is installed).
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
