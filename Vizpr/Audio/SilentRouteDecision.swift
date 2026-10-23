/// Decides whether a route that has delivered nothing but zeros should be
/// abandoned for the built-in microphone (field case: a phone call owned the
/// AirPods and macOS kept handing us their silent input route).
enum SilentRouteDecision {
    /// How much measured audio must be exactly zero before the route counts as
    /// dead rather than still warming up (Bluetooth routes deliver zeros while
    /// they connect).
    static let evidenceSeconds = 1.3

    /// The evidence window expressed in taps. Taps carry a fixed number of
    /// frames at the hardware sample rate, so a tap's duration depends on the
    /// route; 48 kHz is the fastest common rate and gives the shortest taps,
    /// so every route waits at least `evidenceSeconds`.
    static let minimumMeasuredTaps = Int(
        (evidenceSeconds * 48_000 / Double(MicrophoneCapture.tapBufferFrames)).rounded(.up)
    )

    /// - Parameters:
    ///   - measuredTaps: taps whose raw level has actually been measured.
    ///   - rawPeak: peak raw level over those taps (0 means exactly silent).
    ///   - routeIsBuiltIn: the built-in mic has nothing to fall back to.
    ///   - alreadyAttempted: a failover is tried at most once per session.
    static func shouldFallBack(
        measuredTaps: Int,
        rawPeak: Int,
        routeIsBuiltIn: Bool,
        alreadyAttempted: Bool
    ) -> Bool {
        measuredTaps >= minimumMeasuredTaps
            && rawPeak == 0
            && !routeIsBuiltIn
            && !alreadyAttempted
    }
}
