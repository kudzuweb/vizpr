import Testing
@testable import Vizpr

@Suite("SilentRouteDecision")
struct SilentRouteDecisionTests {
    private func decide(
        seconds: Double, rate: Double = 48_000, rawPeak: Int = 0,
        route: InputRoute = .external, alreadyAttempted: Bool = false
    ) -> Bool {
        SilentRouteDecision.shouldFallBack(
            measuredFrames: Int(seconds * rate), hardwareSampleRate: rate,
            rawPeak: rawPeak, route: route, alreadyAttempted: alreadyAttempted
        )
    }

    @Test("waits for the evidence window before calling a route silent")
    func tooLittleMeasuredAudio() {
        #expect(!decide(seconds: 1.0))
        #expect(!decide(seconds: 0))
        #expect(decide(seconds: 1.4))
    }

    @Test("the window is the same in seconds at 16 kHz and at 96 kHz")
    func windowIsInSecondsAtAnyRate() {
        #expect(!decide(seconds: 1.0, rate: 96_000))
        #expect(decide(seconds: 1.4, rate: 96_000))
        #expect(!decide(seconds: 1.0, rate: 16_000))
        #expect(decide(seconds: 1.4, rate: 16_000))
    }

    @Test("never abandons the built-in mic, even when it is silent")
    func builtInRoute() {
        #expect(!decide(seconds: 5, route: .builtIn))
    }

    @Test("does not fail over from a route it could not identify")
    func unidentifiedRoute() {
        #expect(!decide(seconds: 5, route: .unidentified))
    }

    @Test("does not fail over before the sample rate is known")
    func unknownSampleRate() {
        #expect(!SilentRouteDecision.shouldFallBack(
            measuredFrames: 1_000_000, hardwareSampleRate: 0, rawPeak: 0,
            route: .external, alreadyAttempted: false
        ))
    }

    @Test("falls back from a silent non-built-in route")
    func silentExternalRoute() {
        #expect(decide(seconds: 2))
    }

    @Test("keeps a route that has delivered any signal")
    func healthyRoute() {
        #expect(!decide(seconds: 5, rawPeak: 1))
    }

    @Test("tries the failover at most once")
    func alreadyAttempted() {
        #expect(!decide(seconds: 5, alreadyAttempted: true))
    }
}
