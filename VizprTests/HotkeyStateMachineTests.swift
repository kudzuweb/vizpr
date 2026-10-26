import Foundation
import Testing
@testable import Vizpr

// MARK: - Fixtures

private let threshold = Duration.milliseconds(200)

private func t(_ ms: UInt64) -> MonotonicTime {
    MonotonicTime(nanoseconds: ms * 1_000_000)
}

private func machine(_ state: HotkeyState = .idle) -> HotkeyStateMachine {
    HotkeyStateMachine(holdThreshold: threshold, state: state)
}

// MARK: - Transition table

@Suite("HotkeyStateMachine transitions")
struct HotkeyTransitionTests {

    @Test("Primary down from idle starts dictation and consumes the event")
    func primaryDownStarts() {
        var m = machine()
        let d = m.handle(.primaryDown(at: t(0)))
        #expect(d.action == .startDictation)
        #expect(d.disposition == .consume)
        #expect(m.state == .pressed(since: t(0), source: .primary))
    }

    @Test("Tap (release before threshold) latches; next press commits")
    func tapLatchesThenNextPressCommits() {
        var m = machine()
        _ = m.handle(.primaryDown(at: t(0)))
        let up = m.handle(.primaryUp(at: t(150)))           // 150ms < 200ms → tap
        #expect(up.action == nil)                       // keep dictating, no commit yet
        #expect(up.disposition == .consume)
        #expect(m.state == .latched(source: .primary))

        let next = m.handle(.primaryDown(at: t(2000)))       // next press commits
        #expect(next.action == .commit)
        #expect(next.disposition == .consume)
        #expect(m.state == .idle)
    }

    @Test("Hold (release at/after threshold) commits on release")
    func holdCommitsOnRelease() {
        var m = machine()
        _ = m.handle(.primaryDown(at: t(0)))
        let up = m.handle(.primaryUp(at: t(300)))           // 300ms ≥ 200ms → hold
        #expect(up.action == .commit)
        #expect(up.disposition == .consume)
        #expect(m.state == .idle)
    }

    @Test("Threshold boundary: exactly at threshold is a hold")
    func thresholdBoundaryIsHold() {
        var tap = machine()
        _ = tap.handle(.primaryDown(at: t(0)))
        #expect(tap.handle(.primaryUp(at: t(199))).action == nil)          // 199 < 200 → tap/latch
        #expect(tap.state == .latched(source: .primary))

        var hold = machine()
        _ = hold.handle(.primaryDown(at: t(0)))
        #expect(hold.handle(.primaryUp(at: t(200))).action == .commit)     // 200 ≥ 200 → hold
        #expect(hold.state == .idle)
    }

    @Test("thresholdElapsed promotes pressed → holding; release then commits")
    func thresholdElapsedPromotesToHolding() {
        var m = machine()
        _ = m.handle(.primaryDown(at: t(0)))
        let promote = m.handle(.thresholdElapsed(at: t(200)))
        #expect(promote.action == nil)
        #expect(m.state == .holding(since: t(0), source: .primary))
        let up = m.handle(.primaryUp(at: t(5000)))
        #expect(up.action == .commit)
        #expect(m.state == .idle)
    }

    @Test("A tap whose release is handled late still latches, even after a late thresholdElapsed")
    func lateHandledTapLatches() {
        for (source, down, up) in [
            (ActivationSource.primary, HotkeyInput.primaryDown(at: t(0)), HotkeyInput.primaryUp(at: t(100))),
            (.secondary, .secondaryDown(at: t(0)), .secondaryUp(at: t(100)))
        ] {
            var m = machine()
            _ = m.handle(down)
            // Main thread was blocked: the timer is handled at 2000 ms, before the release (stamped 100 ms).
            _ = m.handle(.thresholdElapsed(at: t(2000)))
            #expect(m.state == .holding(since: t(0), source: source))
            let d = m.handle(up)
            #expect(d.action == nil)
            #expect(m.state == .latched(source: source))
        }
    }

    @Test("A real hold promoted to holding still commits on release")
    func realHoldCommitsFromHolding() {
        var m = machine()
        _ = m.handle(.primaryDown(at: t(0)))
        _ = m.handle(.thresholdElapsed(at: t(200)))
        let d = m.handle(.primaryUp(at: t(600)))
        #expect(d.action == .commit)
        #expect(d.disposition == .consume)
        #expect(m.state == .idle)
    }

    @Test("Early thresholdElapsed is ignored (cannot mislabel a tap as a hold)")
    func earlyThresholdElapsedIgnored() {
        var m = machine()
        _ = m.handle(.primaryDown(at: t(0)))
        _ = m.handle(.thresholdElapsed(at: t(50)))     // 50ms < threshold → no promotion
        #expect(m.state == .pressed(since: t(0), source: .primary))
    }

    @Test("Escape discards from every active state and never consumes")
    func escapeCancelsFromActiveStates() {
        for start: HotkeyState in [
            .pressed(since: t(0), source: .primary),
            .holding(since: t(0), source: .primary),
            .latched(source: .primary)
        ] {
            var m = machine(start)
            let d = m.handle(.escape)
            #expect(d.action == .cancel)
            #expect(d.disposition == .passThrough)
            #expect(m.state == .idle)
        }
    }

    @Test("Escape from idle passes through with no action")
    func escapeFromIdleIsInert() {
        var m = machine()
        let d = m.handle(.escape)
        #expect(d.action == nil)
        #expect(d.disposition == .passThrough)
        #expect(m.state == .idle)
    }

    @Test("tapDisabled from every state fails open to idle")
    func tapDisabledFailsOpenFromEveryState() {
        let states: [HotkeyState] = [
            .idle,
            .pressed(since: t(0), source: .primary),
            .holding(since: t(0), source: .secondary),
            .latched(source: .primary)
        ]
        for reason in [TapDisableReason.timeout, .userInput] {
            for start in states {
                var m = machine(start)
                let d = m.handle(.tapDisabled(reason))
                #expect(m.state == .idle, "tapDisabled must reset \(start) to idle")
                #expect(d.disposition == .passThrough)
                if start != .idle {
                    #expect(d.action == .cancel)   // discard any in-flight session
                }
            }
        }
    }

    @Test("captureFailed cancels from every active state and never consumes")
    func captureFailedCancelsFromActiveStates() {
        for start: HotkeyState in [
            .pressed(since: t(0), source: .primary),
            .holding(since: t(0), source: .secondary),
            .latched(source: .primary)
        ] {
            var m = machine(start)
            let d = m.handle(.captureFailed)
            #expect(d.action == .cancel, "captureFailed must cancel \(start)")
            #expect(d.disposition == .passThrough)
            #expect(m.state == .idle)
        }
    }

    @Test("captureFailed from idle is inert")
    func captureFailedFromIdleIsInert() {
        var m = machine()
        let d = m.handle(.captureFailed)
        #expect(d == .ignorePassThrough)
        #expect(m.state == .idle)
    }

    @Test("Auto-stop commits only in a latched session")
    func autoStopCommitsOnlyWhenLatched() {
        var latched = machine(.latched(source: .primary))
        let d = latched.handle(.autoStop)
        #expect(d.action == .commit)
        #expect(d.disposition == .passThrough)
        #expect(latched.state == .idle)

        for start: HotkeyState in [.idle, .pressed(since: t(0), source: .primary), .holding(since: t(0), source: .primary)] {
            var m = machine(start)
            #expect(m.handle(.autoStop).action == nil, "autoStop is inert in \(start)")
            #expect(m.state == start)
        }
    }

    @Test("An autorepeat of the primary key is swallowed in every state and changes nothing")
    func primaryRepeatIsInertEverywhere() {
        for start: HotkeyState in [
            .idle,
            .pressed(since: t(0), source: .primary),
            .holding(since: t(0), source: .primary),
            .latched(source: .primary),
            .latched(source: .secondary)
        ] {
            var m = machine(start)
            let d = m.handle(.primaryRepeat)
            #expect(d == .ignoreConsume, "repeat in \(start) must only be swallowed")
            #expect(m.state == start)
        }
    }

    @Test("A held key repeating after the commit press does not start a new session")
    func repeatAfterCommitDoesNotRestart() {
        var m = machine(.latched(source: .primary))
        #expect(m.handle(.primaryDown(at: t(2000))).action == .commit)
        #expect(m.state == .idle)
        let repeatDecision = m.handle(.primaryRepeat)
        #expect(repeatDecision.action == nil)
        #expect(m.state == .idle)
    }

    @Test("Secondary combo mirrors the primary but never consumes")
    func secondaryComboPassesThrough() {
        var m = machine()
        let down = m.handle(.secondaryDown(at: t(0)))
        #expect(down.action == .startDictation)
        #expect(down.disposition == .passThrough)
        #expect(m.state == .pressed(since: t(0), source: .secondary))

        let up = m.handle(.secondaryUp(at: t(150)))    // tap
        #expect(up.disposition == .passThrough)
        #expect(m.state == .latched(source: .secondary))

        let commit = m.handle(.secondaryDown(at: t(2000)))
        #expect(commit.action == .commit)
        #expect(commit.disposition == .passThrough)
    }

    @Test("Secondary hold (release at/after threshold) commits on release")
    func secondaryHoldCommitsOnRelease() {
        var m = machine()
        _ = m.handle(.secondaryDown(at: t(0)))
        let up = m.handle(.secondaryUp(at: t(300)))    // 300ms ≥ 200ms → hold
        #expect(up.action == .commit)
        #expect(up.disposition == .passThrough)
        #expect(m.state == .idle)
    }
}

// MARK: - Property tests (randomized sequences)

@Suite("HotkeyStateMachine invariants")
struct HotkeyPropertyTests {

    /// Generate a random input. Time only ever advances (monotonic), so the
    /// `clock` is threaded through and bumped by a random amount per input.
    private func randomInput(using rng: inout SplitMix64, clock: inout UInt64) -> HotkeyInput {
        clock &+= UInt64.random(in: 0...500, using: &rng)   // 0–500 ms jitter
        let now = MonotonicTime(nanoseconds: clock * 1_000_000)
        switch UInt8.random(in: 0...9, using: &rng) {
        case 0: return .primaryDown(at: now)
        case 1: return .primaryUp(at: now)
        case 2: return .secondaryDown(at: now)
        case 3: return .secondaryUp(at: now)
        case 4: return .escape
        case 5: return .autoStop
        case 6: return .thresholdElapsed(at: now)
        case 7: return .captureFailed
        case 8: return .primaryRepeat
        default: return .tapDisabled(Bool.random(using: &rng) ? .timeout : .userInput)
        }
    }

    private func isPrimaryInput(_ input: HotkeyInput) -> Bool {
        switch input {
        case .primaryDown, .primaryUp, .primaryRepeat: return true
        default: return false
        }
    }

    /// THE load-bearing invariant (PLAN.md §8a): no event sequence ever leaves the
    /// machine in a state that suppresses non-primary input. Pinned as: a
    /// `.consume` disposition is emitted **if and only if** the input is a
    /// primary-trigger input (down, up or repeat) — in every state, after every
    /// history. Which physical events become primary inputs is pinned separately,
    /// over the tracker and machine together, in `HotkeyEventRouterTests`.
    @Test("Fail-open: consume happens iff the input is a primary-trigger input")
    func failOpenConsumeOnlyForPrimaryInputs() {
        for seed in UInt64(1)...500 {
            var rng = SplitMix64(seed: seed)
            var clock: UInt64 = 0
            var m = machine()
            for _ in 0..<200 {
                let input = randomInput(using: &rng, clock: &clock)
                let decision = m.handle(input)
                if decision.disposition == .consume {
                    #expect(isPrimaryInput(input), "non-primary input \(input) was consumed (seed \(seed))")
                }
                if isPrimaryInput(input) {
                    #expect(decision.disposition == .consume, "primary input \(input) passed through (seed \(seed))")
                }
            }
        }
    }

    /// After any history, a non-primary event is never suppressed — the machine
    /// can never get "stuck" eating real keystrokes.
    @Test("No reachable state suppresses a following non-primary input")
    func noStuckSuppression() {
        let probes: [HotkeyInput] = [.escape, .secondaryDown(at: t(0)), .secondaryUp(at: t(0)), .autoStop]
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(seed: seed)
            var clock: UInt64 = 0
            var m = machine()
            for _ in 0..<120 { _ = m.handle(randomInput(using: &rng, clock: &clock)) }
            // Whatever state we landed in, every non-primary probe must pass through.
            for probe in probes {
                var copy = m
                #expect(copy.handle(probe).disposition == .passThrough,
                        "probe \(probe) suppressed from state \(m.state) (seed \(seed))")
            }
        }
    }

    /// Structural safety: commit/cancel always land in idle, and dictation only
    /// ever starts from idle — no double-start, no commit-without-reset.
    @Test("commit/cancel reach idle; startDictation only from idle")
    func actionStateConsistency() {
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(seed: seed)
            var clock: UInt64 = 0
            var m = machine()
            for _ in 0..<200 {
                let before = m.state
                let decision = m.handle(randomInput(using: &rng, clock: &clock))
                switch decision.action {
                case .commit, .cancel:
                    #expect(m.state == .idle, "\(decision.action!) left state \(m.state) (seed \(seed))")
                case .startDictation:
                    #expect(before == .idle, "startDictation from non-idle \(before) (seed \(seed))")
                case nil:
                    break
                }
            }
        }
    }
}
