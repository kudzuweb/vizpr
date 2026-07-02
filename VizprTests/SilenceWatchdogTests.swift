import Testing
@testable import Vizpr

/// The watchdog is clocked by observed samples (the audio stream is the clock),
/// so these tests are exact arithmetic — the fake-clock requirement from the
/// plan's acceptance criteria is satisfied by construction.
@Suite("SilenceWatchdog")
struct SilenceWatchdogTests {

    private let rate = 16_000
    private let chunk = 4096   // 256 ms

    private func watchdog(seconds: Int = 2) -> SilenceWatchdog {
        SilenceWatchdog(timeout: .seconds(seconds), sampleRate: rate)
    }

    @Test("Fires exactly once when continuous silence reaches the timeout")
    func firesAtTimeout() {
        var dog = watchdog(seconds: 2)   // 32000 samples ≈ 7.8 chunks
        var fires = 0
        for _ in 0..<20 {
            if dog.observe(chunkSampleCount: chunk, speechActive: false) { fires += 1 }
        }
        #expect(fires == 1)
    }

    @Test("Fires at the exact chunk that crosses the threshold, not before")
    func firesAtExactBoundary() {
        var dog = watchdog(seconds: 2)   // 32000 samples; chunk 4096 → fires on chunk 8 (32768)
        for step in 1...7 {
            let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
            #expect(!fired, "fired early at chunk \(step)")
        }
        let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
        #expect(fired)
    }

    @Test("Speech resets the silence run and re-arms the watchdog")
    func speechResets() {
        var dog = watchdog(seconds: 1)   // 16000 samples ≈ 3.9 chunks
        for _ in 0..<3 {
            let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
            #expect(!fired)
        }
        // Speech just before the threshold: run resets.
        let firedOnSpeech = dog.observe(chunkSampleCount: chunk, speechActive: true)
        #expect(!firedOnSpeech)
        for _ in 0..<3 {
            let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
            #expect(!fired)
        }
        // A fresh full run of silence fires again.
        let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
        #expect(fired)
    }

    @Test("Never-spoken latched session still times out from session start")
    func firesWithoutAnySpeech() {
        var dog = watchdog(seconds: 1)
        var fired = false
        for _ in 0..<10 {
            if dog.observe(chunkSampleCount: chunk, speechActive: false) { fired = true }
        }
        #expect(fired)
    }

    @Test("After firing, stays quiet until speech re-arms it")
    func oneFirePerSilenceRun() {
        var dog = watchdog(seconds: 1)
        var fires = 0
        for _ in 0..<50 {
            if dog.observe(chunkSampleCount: chunk, speechActive: false) { fires += 1 }
        }
        #expect(fires == 1)
        _ = dog.observe(chunkSampleCount: chunk, speechActive: true)
        for _ in 0..<50 {
            if dog.observe(chunkSampleCount: chunk, speechActive: false) { fires += 1 }
        }
        #expect(fires == 2)
    }

    @Test("reset starts a fresh session run")
    func resetStartsFresh() {
        var dog = watchdog(seconds: 1)
        for _ in 0..<3 { _ = dog.observe(chunkSampleCount: chunk, speechActive: false) }
        dog.reset()
        // Only one chunk of the previous run's silence should not count.
        let fired = dog.observe(chunkSampleCount: chunk, speechActive: false)
        #expect(!fired)
    }

    @Test("Auto-stop through the machine commits only from latched")
    func autoStopIntegratesWithMachine() {
        // The full path: watchdog fires → .autoStop into the machine. Latched
        // commits; push-to-talk (holding) ignores it — §6's single commit path.
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200), state: .latched(source: .fn))
        var dog = watchdog(seconds: 1)
        var committed = false
        for _ in 0..<10 {
            if dog.observe(chunkSampleCount: chunk, speechActive: false) {
                committed = machine.handle(.autoStop).action == .commit
            }
        }
        #expect(committed)
        #expect(machine.state == .idle)

        var holdingMachine = HotkeyStateMachine(holdThreshold: .milliseconds(200), state: .holding(source: .fn))
        #expect(holdingMachine.handle(.autoStop).action == nil)
        #expect(holdingMachine.state == .holding(source: .fn))
    }
}
