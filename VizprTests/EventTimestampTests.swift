import Testing
@testable import Vizpr

@Suite("EventTimestamp")
struct EventTimestampTests {
    private let appleSilicon = (numer: UInt32(125), denom: UInt32(3))
    private let now = MonotonicTime(nanoseconds: 100_000_000_000)

    @Test("Mach ticks are scaled by the timebase into nanoseconds")
    func scalesTicks() {
        // 2_400_000_000 ticks * 125/3 = 100_000_000_000 ns
        let ticks: UInt64 = 2_400_000_000 - 24_000_000     // 40 ms earlier in ticks
        let stamp = EventTimestamp.monotonic(eventTicks: ticks, handledAt: now, timebase: appleSilicon)
        #expect(stamp.nanoseconds == ticks * 125 / 3)
        #expect(stamp < now)
    }

    @Test("A stamp in the future falls back to the handling time")
    func futureFallsBack() {
        let stamp = EventTimestamp.monotonic(eventTicks: 100_000_000_000, handledAt: now, timebase: appleSilicon)
        #expect(stamp == now)
    }

    @Test("A stamp far in the past falls back to the handling time")
    func staleFallsBack() {
        let stamp = EventTimestamp.monotonic(eventTicks: 1, handledAt: now, timebase: appleSilicon)
        #expect(stamp == now)
    }

    @Test("A zero timestamp falls back to the handling time, including soon after boot")
    func zeroFallsBack() {
        for uptime in [UInt64(5_000_000_000), 60_000_000_000] {
            let handled = MonotonicTime(nanoseconds: uptime)
            #expect(EventTimestamp.monotonic(eventTicks: 0, handledAt: handled, timebase: (1, 1)) == handled)
        }
    }
}
