import Testing
@testable import Vizpr

@Suite("SilentRouteDecision")
struct SilentRouteDecisionTests {
    private let enough = SilentRouteDecision.minimumMeasuredTaps

    @Test("waits for enough measured taps before calling a route silent")
    func tooFewMeasuredTaps() {
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredTaps: enough - 1, rawPeak: 0, routeIsBuiltIn: false, alreadyAttempted: false
        ))
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredTaps: 0, rawPeak: 0, routeIsBuiltIn: false, alreadyAttempted: false
        ))
    }

    @Test("never abandons the built-in mic, even when it is silent")
    func builtInRoute() {
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredTaps: enough * 4, rawPeak: 0, routeIsBuiltIn: true, alreadyAttempted: false
        ))
    }

    @Test("falls back from a silent non-built-in route")
    func silentExternalRoute() {
        #expect(SilentRouteDecision.shouldFallBack(
            measuredTaps: enough, rawPeak: 0, routeIsBuiltIn: false, alreadyAttempted: false
        ))
    }

    @Test("keeps a route that has delivered any signal")
    func healthyRoute() {
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredTaps: enough * 4, rawPeak: 1, routeIsBuiltIn: false, alreadyAttempted: false
        ))
    }

    @Test("tries the failover at most once")
    func alreadyAttempted() {
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredTaps: enough * 4, rawPeak: 0, routeIsBuiltIn: false, alreadyAttempted: true
        ))
    }
}
