import Testing
@testable import Vizpr

@Suite("EventTimestamp")
struct EventTimestampTests {
    private let now = MonotonicTime(nanoseconds: 100_000_000_000)

    @Test("A recent stamp is used as nanoseconds, unscaled")
    func usesStampAsNanoseconds() {
        // Field values 2026-10-23: the stamp trailed uptime by about 0.4 ms.
        let stamp = EventTimestamp.monotonic(eventNanoseconds: 99_960_000_000, handledAt: now)
        #expect(stamp.nanoseconds == 99_960_000_000)
    }

    @Test("A stamp in the future falls back to the handling time")
    func futureFallsBack() {
        let stamp = EventTimestamp.monotonic(eventNanoseconds: 100_000_000_001, handledAt: now)
        #expect(stamp == now)
    }

    @Test("A stamp far in the past falls back to the handling time")
    func staleFallsBack() {
        let stamp = EventTimestamp.monotonic(eventNanoseconds: 1, handledAt: now)
        #expect(stamp == now)
    }

    @Test("A zero timestamp falls back to the handling time, including soon after boot")
    func zeroFallsBack() {
        for uptime in [UInt64(5_000_000_000), 60_000_000_000] {
            let handled = MonotonicTime(nanoseconds: uptime)
            #expect(EventTimestamp.monotonic(eventNanoseconds: 0, handledAt: handled) == handled)
        }
    }
}
