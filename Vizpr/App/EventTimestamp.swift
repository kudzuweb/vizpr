/// Reads a CGEvent's own timestamp as the machine's `MonotonicTime`, so a
/// press/release pair is classified by when the keys moved, not by when a busy
/// run loop got around to handling them.
///
/// `CGEventTimestamp` is documented as nanoseconds since system startup, the
/// same clock as `nowMonotonic()`; on Apple Silicon it is not mach ticks (field
/// log 2026-10-23: the raw stamp was within 0.4 ms of uptime in nanoseconds). As
/// a guard against the unit being something else, a stamp that lies in the
/// future or more than `maxAge` in the past falls back to the handling time,
/// which is the old behavior.
enum EventTimestamp {
    /// Longest plausible delay between a key edge and its handling.
    static let maxAge: UInt64 = 30_000_000_000

    static func monotonic(eventNanoseconds: UInt64, handledAt now: MonotonicTime) -> MonotonicTime {
        converted(eventNanoseconds: eventNanoseconds, handledAt: now) ?? now
    }

    /// The event's own time, or nil when the guards reject it (the caller then
    /// uses handling time). Exposed so the dev log can say which path ran.
    static func converted(eventNanoseconds: UInt64, handledAt now: MonotonicTime) -> MonotonicTime? {
        guard eventNanoseconds != 0,
              eventNanoseconds <= now.nanoseconds,
              now.nanoseconds - eventNanoseconds <= maxAge
        else { return nil }
        return MonotonicTime(nanoseconds: eventNanoseconds)
    }
}
