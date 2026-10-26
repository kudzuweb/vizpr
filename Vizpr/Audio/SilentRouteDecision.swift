/// Decides whether a route that has delivered nothing but zeros should be
/// abandoned for the built-in microphone (field case: a phone call owned the
/// AirPods and macOS kept handing us their silent input route).
enum SilentRouteDecision {
    /// How much measured audio must be exactly zero before the route counts as
    /// dead rather than still warming up (Bluetooth routes deliver zeros while
    /// they connect).
    static let evidenceSeconds = 1.3

    static func shouldFallBack(evidence: RouteEvidence, alreadyAttempted: Bool) -> Bool {
        shouldFallBack(
            measuredFrames: evidence.measuredFrames,
            hardwareSampleRate: evidence.hardwareSampleRate,
            rawPeak: evidence.rawPeak,
            route: evidence.route,
            alreadyAttempted: alreadyAttempted
        )
    }

    /// - Parameters:
    ///   - measuredFrames: hardware frames whose raw level has been measured.
    ///   - hardwareSampleRate: the rate those frames are at, so the evidence is
    ///     judged in seconds whatever the route's tap size.
    ///   - rawPeak: peak raw level over those frames (0 means exactly silent).
    ///   - route: only a route positively identified as non-built-in qualifies:
    ///     the built-in mic has nothing to fall back to, and an unidentified
    ///     route gives no reason to believe a swap would help.
    ///   - alreadyAttempted: a failover is tried at most once per session.
    static func shouldFallBack(
        measuredFrames: Int,
        hardwareSampleRate: Double,
        rawPeak: Int,
        route: InputRoute,
        alreadyAttempted: Bool
    ) -> Bool {
        guard route == .external, hardwareSampleRate > 0 else { return false }
        return Double(measuredFrames) / hardwareSampleRate >= evidenceSeconds
            && rawPeak == 0
            && !alreadyAttempted
    }
}
