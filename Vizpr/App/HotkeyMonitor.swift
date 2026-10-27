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
/// **Give-up.** A tap the OS keeps disabling by timeout is being refused, not slow
/// (2026-10-27: an owner whose executable was deleted). `TapDisablePolicy` counts
/// those disables; at the limit the monitor tears the tap down and latches, and
/// only `resetGiveUp()` (an explicit user action) lets `start()` install again.
///
/// **Fail-open.** The callback returns `.consume` (nil) only when the machine says
/// so, and the machine only ever says so for Fn events. No code path here can
/// suppress a non-Fn key. This is the inversion of the Wispr stale-key bug.
final class HotkeyMonitor: @unchecked Sendable {
    /// Escape virtual keycode.
    private static let escapeKeyCode: Int64 = 53

    private static let log = Logger(subsystem: "com.kudzuweb.vizpr", category: "hotkey")

    private let runLoopThread = HotkeyRunLoopThread()

    // Hotkey-thread state.
    private var machine: HotkeyStateMachine
    /// Edge tracking lives in a pure, tested value type (see `FlagEdgeTracker`):
    /// flagsChanged reports the whole flag set, so down/up edges are derived by
    /// comparison, and that comparison has real failure modes worth testing.
    private var edges: FlagEdgeTracker
    /// The tap currently attached to the run loop (port and source).
    private var installed: InstalledTap?
    private var thresholdTimer: CFRunLoopTimer?
    private var watchdogTimer: CFRunLoopTimer?

    /// State read from more than one thread.
    private struct Shared: @unchecked Sendable {
        var port: CFMachPort?
        var hasObservedEvent = false
        var disablePolicy = TapDisablePolicy(
            limit: Tuning.tapDisableLimit, window: .seconds(Tuning.tapDisableWindowSeconds)
        )
        var onGiveUp: (@MainActor @Sendable () -> Void)?
    }
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())

    private var machPort: CFMachPort? { shared.withLockUnchecked { $0.port } }

    /// True once the callback has fired at least once. Reserved for an onboarding
    /// "press Fn to confirm" liveness step; not used to infer capability, because
    /// a freshly-granted but idle tap has legitimately observed nothing yet.
    var hasObservedEvent: Bool { shared.withLockUnchecked { $0.hasObservedEvent } }

    /// Called on the main actor after the monitor gives up on a refused tap.
    func setOnGiveUp(_ handler: @escaping @MainActor @Sendable () -> Void) {
        shared.withLockUnchecked { $0.onGiveUp = handler }
    }

    /// True from a give-up until `resetGiveUp()`.
    @MainActor
    var hasGivenUp: Bool { shared.withLockUnchecked { !$0.disablePolicy.mayArm } }

    /// Reopen the latch after a give-up. Only an explicit user action calls this;
    /// settings changes and permission flows must not.
    @MainActor
    func resetGiveUp() {
        shared.withLockUnchecked { $0.disablePolicy.reset() }
    }

    /// Live setting (PR 11): applies from the next press — replacing the
    /// machine preserves its current state so a mid-session change is safe.
    func setHoldThreshold(_ threshold: Duration) {
        runLoopThread.perform { [self] in
            machine = HotkeyStateMachine(holdThreshold: threshold, state: machine.state)
        }
    }

    /// Live setting (PR 11): reassign the secondary chord. Called on every
    /// settings change, so an unchanged mask is a no-op, and a changed one keeps
    /// the tracker's held-key state: a key held across the change must still
    /// produce its up edge.
    func setSecondaryMask(_ mask: CGEventFlags) {
        runLoopThread.perform { [self] in
            guard mask != edges.secondaryMask else { return }
            edges = edges.replacingSecondaryMask(mask)
        }
    }

    /// Dictation actions for the rest of the app to consume with `for await`.
    let actions: AsyncStream<DictationAction>
    private let actionsContinuation: AsyncStream<DictationAction>.Continuation

    init(holdThreshold: Duration, secondaryMask: CGEventFlags) {
        self.machine = HotkeyStateMachine(holdThreshold: holdThreshold)
        self.edges = FlagEdgeTracker(secondaryMask: secondaryMask)
        (actions, actionsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        // Backstop against use-after-free: the tap holds an unretained pointer to
        // self, so it must never outlive the object. Waiting for the teardown also
        // waits out a callback still running on the hotkey thread. Idempotent
        // with stop().
        var leftover = installed ?? InstalledTap()
        leftover.timers = [thresholdTimer, watchdogTimer].compactMap { $0 }
        let snapshot = leftover
        let thread = runLoopThread
        thread.performAndWait { snapshot.tearDown(on: thread) }
        actionsContinuation.finish()
    }

    // MARK: Lifecycle

    /// Install the tap on the hotkey thread's run loop. Returns false if the tap
    /// could not be created (almost always missing Accessibility) — the caller
    /// drives the permission flow via `PermissionProbe` and retries. Also returns
    /// false, creating nothing, after a give-up until `resetGiveUp()`.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard shared.withLockUnchecked({ $0.disablePolicy.mayArm }) else { return false }
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

        // A give-up can land between the check above and here; the latch is
        // re-read under the same lock that publishes the port.
        let accepted = shared.withLockUnchecked { state -> Bool in
            guard state.disablePolicy.mayArm else { return false }
            state.port = port
            return true
        }
        guard accepted else {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            return false
        }
        let tap = InstalledTap(port: port, source: CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
        runLoopThread.performAndWait { [self] in
            installed = tap
            if let source = tap.source { runLoopThread.add(source: source) }
            tap.port.map { CGEvent.tapEnable(tap: $0, enable: true) }
            startWatchdog()
        }
        return true
    }

    /// Remove the tap and reset all state before returning; the wait is bounded
    /// so a wedged hotkey thread cannot hang a permission flow or app quit.
    ///
    /// The port is cleared here, on the caller's thread, so a `start()` that
    /// follows a timed-out stop creates a fresh tap instead of seeing the old
    /// one. The queued teardown removes only the tap that this call stopped, so
    /// it can never remove that newer tap.
    @MainActor
    func stop() {
        let stoppedTap = shared.withLockUnchecked { state -> ObjectIdentifier? in
            defer { state.port = nil }
            return state.port.map(ObjectIdentifier.init)
        }
        runLoopThread.performAndWait { [self] in
            removeInstalledTap(matching: stoppedTap)
        }
    }

    /// Tear down the tap, timers and session. Hotkey thread only, and never from
    /// inside the tap callback: invalidating a port whose callout is running is
    /// not known to be safe, so the callback queues this with `perform`.
    ///
    /// The tap is removed only if it is the one that was stopped, so a queued
    /// teardown can never remove a newer tap.
    private func removeInstalledTap(matching stoppedTap: ObjectIdentifier?) {
        var teardown = InstalledTap()
        teardown.timers = [thresholdTimer, watchdogTimer].compactMap { $0 }
        if let current = installed, current.port.map(ObjectIdentifier.init) == stoppedTap {
            teardown.port = current.port
            teardown.source = current.source
            installed = nil
        }
        teardown.tearDown(on: runLoopThread)
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

    /// Take the tap out of service for good, for the bundle watcher's shutdown.
    /// Returns at once: the disable and the latch happen on the caller's thread,
    /// the rest is queued on the hotkey thread, which calls `completion` when
    /// done. Never waits on main or on the hotkey thread.
    func tearDownForExit(completion: @escaping @Sendable () -> Void) {
        let disabledTap = disableAndDetachPort(latching: true)
        runLoopThread.perform { [self] in
            removeInstalledTap(matching: disabledTap)
            completion()
        }
    }

    /// Disable the tap and clear the shared port, optionally closing the give-up
    /// latch in the same lock hold. Safe from any thread, including inside the
    /// tap callback. Returns the identity of the port taken out of service.
    private func disableAndDetachPort(latching: Bool) -> ObjectIdentifier? {
        let port = shared.withLockUnchecked { state -> CFMachPort? in
            if latching { state.disablePolicy.latch() }
            defer { state.port = nil }
            return state.port
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        return port.map(ObjectIdentifier.init)
    }

    /// Whether the tap currently reports healthy. The watchdog re-enables a dead
    /// tap; a `false` here with permission granted is the "granted but dead"
    /// signal the onboarding flow watches for.
    @MainActor
    var isTapHealthy: Bool {
        guard let port = machPort, !hasGivenUp else { return false }
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
        case .tapDisabledByTimeout:
            // The OS disabled us (slow callback or a refused owner). Re-enable
            // unless it keeps happening, in which case give up and stay off.
            recoverFromTimeout(origin: "callback")
            return Unmanaged.passUnretained(event)

        case .tapDisabledByUserInput:
            // Secure input, not a refused owner: re-enable without counting.
            // Reset BOTH the machine and the edge tracker: a press whose release
            // was missed while we were disabled must not strand `fnDown` true and
            // swallow the next press's edge.
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("tap disabled by userInput — re-enabling")
            #endif
            reEnableTap()
            apply(machine.handle(.tapDisabled(.userInput)))
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
        let converted = EventTimestamp.converted(eventNanoseconds: event.timestamp, handledAt: handledAt)
        let now = converted ?? handledAt

        // One packet can toggle both Fn and the secondary combo, so process every
        // edge it produces — never early-return after Fn. Only an Fn edge can ever
        // set `suppress`, so a packet without an Fn edge is never deleted. A packet
        // with an Fn edge is deleted whole, including any secondary edge in it.
        var suppress = false
        let found = edges.edges(for: event.flags)
        #if DICT_DEV_LOG
        logTimestampPathOnce(edges: found, rawStamp: event.timestamp, converted: converted, handledAt: handledAt)
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
        edges: [FlagEdgeTracker.Edge], rawStamp: UInt64, converted: MonotonicTime?, handledAt: MonotonicTime
    ) {
        guard !loggedTimestampPath, edges.contains(where: { $0 == .fnDown || $0 == .fnUp }) else { return }
        loggedTimestampPath = true
        VizprTranscriptLogger.note(
            "hotkey event stamp: \(converted == nil ? "fell back to handling time" : "converted") "
            + "rawStamp=\(rawStamp) convertedNs=\(converted?.nanoseconds.description ?? "-") "
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
    /// held).
    private func reEnableTap() {
        if let port = machPort { CGEvent.tapEnable(tap: port, enable: true) }
        edges.reset()
    }

    /// The one place a timeout-disabled tap is re-armed: the in-callback disable
    /// and the watchdog's found-dead branch both come here, and these are the only
    /// two sites that feed the disable counter. Hotkey thread only.
    ///
    /// Resets the machine as well as the edges: a tap that was disabled
    /// mid-session already lost events, and a clean idle is fail-open.
    private func recoverFromTimeout(origin: String) {
        // Disables already in flight when the monitor gave up change nothing.
        guard shared.withLockUnchecked({ $0.disablePolicy.mayArm }) else { return }
        let verdict = shared.withLockUnchecked { $0.disablePolicy.recordDisable(at: nowMonotonic()) }
        switch verdict {
        case .reArm(let count):
            Self.log.notice("tap disabled by timeout (\(origin, privacy: .public)): \(count) in window — re-enabling")
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("tap disabled by timeout (\(origin)): \(count) in window — re-enabling")
            #endif
            reEnableTap()
            apply(machine.handle(.tapDisabled(.timeout)))
        case .giveUp(let count):
            Self.log.fault("tap disabled by timeout (\(origin, privacy: .public)): \(count) in window — giving up")
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("tap disabled by timeout (\(origin)): \(count) in window — giving up")
            #endif
            giveUp()
        }
    }

    /// Stop holding input. Two steps because this can run inside the tap's own
    /// callback: disabling the tap and clearing the shared port frees input at
    /// once (in the incident, keys got through in exactly the instants the tap
    /// was disabled); the rest of the teardown is queued on the next pass of the
    /// hotkey thread. Uses only CF and CGEvent calls, never waits on main.
    private func giveUp() {
        let disabledTap = disableAndDetachPort(latching: false)
        runLoopThread.perform { [self] in removeInstalledTap(matching: disabledTap) }
        let handler = shared.withLockUnchecked { $0.onGiveUp }
        if let handler { Task { @MainActor in handler() } }
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
                self.recoverFromTimeout(origin: "watchdog")
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

    init(port: CFMachPort? = nil, source: CFRunLoopSource? = nil) {
        self.port = port
        self.source = source
    }

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
