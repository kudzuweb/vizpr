import Testing
@testable import Vizpr

@Suite("DraftTailTracker")
struct DraftTailTrackerTests {

    private func tracker(
        cadence: Int = 1000, leftContext: Int = 2000, cap: Int = 10_000, minTail: Int = 1
    ) -> DraftTailTracker {
        DraftTailTracker(
            cadenceSamples: cadence, leftContextSamples: leftContext,
            maxDecodeSamples: cap, minTailSamples: minTail
        )
    }

    @Test("No decode until a full cadence of new audio accumulates")
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
}
