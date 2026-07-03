/// Pure auto-stop timing (PLAN.md §6): after `timeout` of continuous VAD
/// silence, emit one auto-stop signal. The signal is fed into the hotkey state
/// machine — which commits only from `latched`, so push-to-talk sessions and
/// non-sessions are unaffected by design, not by logic here.
///
/// Time is measured in *samples observed*, not wall-clock: the audio stream is
/// its own clock (16 kHz mono), which makes the watchdog fully deterministic in
/// tests and immune to scheduling jitter. One fire per silence run; speech
/// re-arms it.
struct SilenceWatchdog {
    /// Samples of continuous silence that trigger auto-stop.
    let timeoutSamples: Int

    private var silentSamples = 0
    private var fired = false

    /// - Parameters:
    ///   - timeout: silence duration before auto-stop (user-tunable in Settings).
    ///   - sampleRate: stream sample rate; 16 kHz for the VAD pipeline.
    init(timeout: Duration, sampleRate: Int) {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        self.timeoutSamples = Int(seconds * Double(sampleRate))
    }

    /// Observe one processed chunk. `speechActive` is the VAD's hysteresis state
    /// (`VadStreamState.triggered`), not the raw per-chunk probability — so brief
    /// dips inside an utterance don't count as silence.
    /// Returns true exactly once per silence run when the timeout elapses.
    mutating func observe(chunkSampleCount: Int, speechActive: Bool) -> Bool {
        if speechActive {
            silentSamples = 0
            fired = false
            return false
        }
        silentSamples += chunkSampleCount
        guard !fired, silentSamples >= timeoutSamples else { return false }
        fired = true
        return true
    }

    /// New session: silence accumulates from zero (a latched session where the
    /// user never speaks still auto-stops after the timeout).
    mutating func reset() {
        silentSamples = 0
        fired = false
    }
}
