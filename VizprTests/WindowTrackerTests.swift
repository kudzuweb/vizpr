import FluidAudio
import Testing
@testable import Vizpr

@Suite("WindowTracker")
struct WindowTrackerTests {

    private func tracker(
        cadence: Int = 1000, leftContext: Int = 2000, cap: Int = 10_000,
        commitCap: Int? = nil, minTail: Int = 1
    ) -> WindowTracker {
        WindowTracker(
            cadenceFloorSamples: cadence, leftContextSamples: leftContext,
            maxDecodeSamples: cap, maxCommitSamples: commitCap ?? cap, minTailSamples: minTail
        )
    }

    /// Default constants: 2 s context each side, 10 s forced window, 0.5 s minimum window.
    private func defaultTracker() -> WindowTracker { WindowTracker(minTailSamples: 1) }

    @Test("No decode until the floor of new audio accumulates")
    func cadenceGates() {
        var t = tracker()
        t.append(sampleCount: 999)
        #expect(t.takeDecodeRequest() == nil)
        t.append(sampleCount: 1)
        let req = t.takeDecodeRequest()
        #expect(req?.range == 0 ..< 1000)
        #expect(req?.draftStart == 0)
        // Clock resets: immediately asking again yields nothing.
        #expect(t.takeDecodeRequest() == nil)
    }

    @Test("The default floor is 500 ms: no request before it, one at it")
    func defaultFloorIsHalfSecond() {
        var t = WindowTracker(minTailSamples: 1)
        t.append(sampleCount: 7_999)
        #expect(t.takeDecodeRequest() == nil)
        t.append(sampleCount: 1)
        #expect(t.takeDecodeRequest()?.range == 0 ..< 8_000)
    }

    @Test("Confirmation advances the draft start")
    func confirmationAdvances() {
        var t = tracker()
        t.append(sampleCount: 5000)
        _ = t.takeDecodeRequest()
        t.confirm(through: 3000)
        t.append(sampleCount: 1000)
        let req = t.takeDecodeRequest()
        #expect(req?.draftStart == 3000)
        #expect(req?.range.upperBound == 6000)
    }

    @Test("Fully confirmed audio yields no decode and resets the clock")
    func fullyConfirmedSkips() {
        var t = tracker()
        t.append(sampleCount: 2000)
        t.confirm(through: 2000)
        #expect(t.takeDecodeRequest() == nil)
        // The skip consumed the cadence credit: 1 new sample doesn't trigger.
        t.append(sampleCount: 1)
        #expect(t.takeDecodeRequest() == nil)
        t.append(sampleCount: 999)
        #expect(t.takeDecodeRequest() != nil)
    }

    @Test("A sub-threshold unconfirmed tail is suppressed until it grows")
    func minTailSuppresses() {
        var t = tracker(cadence: 1000, minTail: 3000)
        t.append(sampleCount: 2000)          // cadence met, but tail 2000 < 3000
        #expect(t.takeDecodeRequest() == nil)
        t.append(sampleCount: 2000)          // tail now 4000 >= 3000
        #expect(t.takeDecodeRequest()?.range == 0 ..< 4000)
    }

    @Test("Decode range respects the cost cap")
    func capBoundsRange() {
        var t = tracker(cadence: 1000, leftContext: 0, cap: 4000)
        t.append(sampleCount: 20_000)
        let req = t.takeDecodeRequest()
        #expect(req?.range == 16_000 ..< 20_000)
    }

    @Test("Confirmation is monotonic and clamped to appended audio")
    func confirmMonotonicClamped() {
        var t = tracker()
        t.append(sampleCount: 1000)
        t.confirm(through: 800)
        t.confirm(through: 500)          // stale regression ignored
        #expect(t.confirmedBoundary == 800)
        t.confirm(through: 99_999)       // beyond appended audio: clamped
        #expect(t.confirmedBoundary == 1000)
    }

    @Test("Reclaimable prefix tracks boundary minus context, bounded by cap")
    func reclaimableGrows() {
        var t = tracker(cadence: 1000, leftContext: 2000, cap: 10_000)
        t.append(sampleCount: 5000)
        #expect(t.reclaimableSamples == 0)
        t.confirm(through: 3000)
        #expect(t.reclaimableSamples == 1000)   // 3000 - 2000 context
        t.append(sampleCount: 20_000)           // total 25000; cap floor = 15000
        #expect(t.reclaimableSamples == 15_000)
    }

    @Test("The commit plan spans the left context before the boundary to the total, cut at the boundary")
    func commitPlanCarriesContext() {
        var t = tracker(commitCap: 50_000)
        t.append(sampleCount: 9000)
        #expect(t.commitPlan() == WindowTracker.WindowPlan(range: 0 ..< 9000, cutStart: 0, cutEnd: 9000, kind: .commit))
        t.confirm(through: 6000)
        // leftContext is 2000 in this fixture.
        #expect(t.commitPlan() == WindowTracker.WindowPlan(range: 4000 ..< 9000, cutStart: 6000, cutEnd: 9000, kind: .commit))
    }

    @Test("The commit plan is nil when nothing is unconfirmed")
    func commitPlanNilWhenConfirmed() {
        var t = tracker()
        #expect(t.commitPlan() == nil)
        t.append(sampleCount: 3000)
        t.confirm(through: 3000)
        #expect(t.commitPlan() == nil)
    }

    @Test("The commit cap trims from the front at 240,000 while the draft cap stays at 192,000")
    func commitCapWiderThanDraftCap() {
        var t = WindowTracker(minTailSamples: 1)
        t.append(sampleCount: 300_000)
        #expect(t.commitPlan()?.range == 60_000 ..< 300_000)
        #expect(t.commitPlan()?.cutStart == 60_000)
        #expect(t.takeDecodeRequest()?.range == 108_000 ..< 300_000)
    }

    @Test("Reclaimable samples keep the commit cap's worth of audio")
    func reclaimableKeepsCommitCap() {
        var t = WindowTracker(minTailSamples: 1)
        t.append(sampleCount: 300_000)
        #expect(t.reclaimableSamples == 60_000)
        t.confirm(through: 100_000)
        #expect(t.reclaimableSamples == 68_000)   // boundary 100,000 - 32,000 context
    }

    // MARK: Windows

    @Test("A pause plans a window from the boundary to the pause, with 2 s of context before it")
    func pausePlansWindow() {
        var t = defaultTracker()
        t.append(sampleCount: 100_000)
        t.confirm(through: 40_000)
        t.append(sampleCount: 50_000)
        t.notePause()
        #expect(t.takeConfirmPlan() == WindowTracker.WindowPlan(
            range: 8_000 ..< 150_000, cutStart: 40_000, cutEnd: 150_000, kind: .pause
        ))
        // Consumed: the same pause plans nothing twice.
        #expect(t.takeConfirmPlan() == nil)
    }

    @Test("Context never starts before the session")
    func pauseContextClampsAtZero() {
        var t = defaultTracker()
        t.append(sampleCount: 20_000)
        t.notePause()
        #expect(t.takeConfirmPlan()?.range == 0 ..< 20_000)
    }

    @Test("A pause under 0.5 s after the boundary plans nothing and is cleared")
    func shortPauseDropped() {
        var t = defaultTracker()
        t.append(sampleCount: 50_000)
        t.confirm(through: 50_000)
        t.append(sampleCount: 7_999)
        t.notePause()
        #expect(t.takeConfirmPlan() == nil)
        // Cleared, not deferred: more audio does not revive it.
        t.append(sampleCount: 50_000)
        #expect(t.takeConfirmPlan() == nil)
    }

    @Test("A pause exactly 0.5 s after the boundary plans a window")
    func minimumWindowPlans() {
        var t = defaultTracker()
        t.append(sampleCount: 8_000)
        t.notePause()
        #expect(t.takeConfirmPlan()?.kind == .pause)
    }

    @Test("No pending pause and under 12 s of speech plans nothing")
    func noPlanWithoutPause() {
        var t = defaultTracker()
        t.append(sampleCount: 191_999)
        #expect(t.takeConfirmPlan() == nil)
    }

    @Test("12 s of unconfirmed audio plans a forced window that decodes 2 s past its nominal end")
    func forcedWindow() {
        var t = defaultTracker()
        t.append(sampleCount: 192_000)
        #expect(t.takeConfirmPlan() == WindowTracker.WindowPlan(
            range: 0 ..< 192_000, cutStart: 0, cutEnd: 160_000, kind: .forced
        ))
        // Without a confirm the plan would repeat on every wake.
        #expect(t.takeConfirmPlan()?.kind == .forced)
        t.confirm(through: 160_000)
        #expect(t.takeConfirmPlan() == nil)
    }

    @Test("A forced plan wins over a pending pause and clears it")
    func forcedBeatsPause() {
        var t = defaultTracker()
        t.append(sampleCount: 200_000)
        t.notePause()
        #expect(t.takeConfirmPlan()?.kind == .forced)
        t.confirm(through: 160_000)
        #expect(t.takeConfirmPlan() == nil)
    }

    @Test("A forced window keeps its decode, context included, under FluidAudio's 15 s limit")
    func forcedWindowFitsModelLimit() {
        var t = defaultTracker()
        t.append(sampleCount: 500_000)
        t.confirm(through: 300_000)
        let plan = t.takeConfirmPlan()
        #expect(plan?.range == 268_000 ..< 492_000)
        #expect((plan?.range.count ?? .max) <= ASRConstants.maxModelSamples)
    }

    @Test("confirm(through:) moves the boundary to a kept word's end and the draft tail follows")
    func confirmThroughKeptEnd() {
        var t = defaultTracker()
        t.append(sampleCount: 100_000)
        t.notePause()
        let plan = t.takeConfirmPlan()
        #expect(plan?.cutEnd == 100_000)
        t.confirm(through: 96_000)   // the last kept word ended before the pause
        #expect(t.confirmedBoundary == 96_000)
        t.append(sampleCount: 8_000)
        #expect(t.takeDecodeRequest()?.draftStart == 96_000)
    }
}
