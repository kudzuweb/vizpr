import Darwin

/// Converts a CGEvent's own timestamp into the machine's `MonotonicTime`, so a
/// press/release pair is classified by when the keys moved, not by when a busy
/// run loop got around to handling them.
///
/// CGEvent timestamps are mach absolute time, which is nanoseconds only on
/// Intel; on Apple Silicon one tick is 125/3 ns. The conversion is therefore
/// done with `mach_timebase_info`. As a guard against the unit being something
/// else, a converted stamp that lies in the future or more than `maxAge` in
/// the past falls back to the handling time, which is the old behavior.
enum EventTimestamp {
    /// Longest plausible delay between a key edge and its handling.
    static let maxAge: UInt64 = 30_000_000_000

    static func monotonic(
        eventTicks: UInt64,
        handledAt now: MonotonicTime,
        timebase: (numer: UInt32, denom: UInt32) = Self.systemTimebase
    ) -> MonotonicTime {
        converted(eventTicks: eventTicks, handledAt: now, timebase: timebase) ?? now
    }

    /// The converted stamp, or nil when the guards reject it (the caller then
    /// uses handling time). Exposed so the dev log can say which path ran.
    static func converted(
        eventTicks: UInt64,
        handledAt now: MonotonicTime,
        timebase: (numer: UInt32, denom: UInt32) = Self.systemTimebase
    ) -> MonotonicTime? {
        guard eventTicks != 0, timebase.denom != 0 else { return nil }
        let (scaled, overflow) = eventTicks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !overflow else { return nil }
        let stamp = scaled / UInt64(timebase.denom)
        guard stamp <= now.nanoseconds, now.nanoseconds - stamp <= maxAge else { return nil }
        return MonotonicTime(nanoseconds: stamp)
    }

    static let systemTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()
}
