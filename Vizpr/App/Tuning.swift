/// Development levers: values tuned by measurement, not choices a user makes.
/// Change one here and every consumer follows. User choices live in
/// `VizprSettings`.
enum Tuning {
    /// Longest the commit waits for the tail's last decode, milliseconds.
    /// A cap below the decode time commits the last draft and drops the decode.
    /// Rule: 2 x p90(15 s tail decode) + 100 ms, rounded up to 50 ms. The 2
    /// covers a draft decode still running when the input ends plus the commit
    /// decode queued behind it. Measured 2026-10-25 on the bundled model: p90
    /// of 180.6 ms over 10 runs gives 500.
    static let settleCapMs = 500

    /// Audio the draft track needs before its first decode, milliseconds.
    /// Tails shorter than 1.5 s decode to junk (field-observed; a constant since 2026-10-25).
    static let draftMinTailMs = 1500

    /// Chunk score at or above which the speech gate opens a soft span inside
    /// the re-onset window, below the VAD's 0.85 trigger. Measured 2026-10-27
    /// on one session: room noise peaked at 0.37 (a 0.23 margin) and the two
    /// speech chunks that open the span scored 0.66 and 0.64 (a 0.04 to 0.06
    /// margin). At 0.65 the 0.64 chunk would fail by 0.01. First move if a soft
    /// resumption is missed: 0.55, which gives the speech side 0.09. False
    /// opens are routine (6.9% of logged inactive chunks scored 0.6 or more);
    /// `softSpeechMinConfidence` is what keeps them out of the text.
    static let reonsetProbability: Float = 0.6

    /// How long after a speech end a soft span may open, milliseconds of
    /// captured audio. Rests on one observation: the second sentence's first
    /// qualifying chunk ended 0.77 s after the speech end. False opens scale
    /// with the window length.
    static let reonsetWindowMs = 3_000

    /// `reonsetWindowMs` in samples.
    static var reonsetWindowSamples: Int { reonsetWindowMs * Int(MicrophoneCapture.sampleRate) / 1000 }

    /// Consecutive chunks scoring under 0.5 that close a soft span, about
    /// 0.77 s. Matches the VAD's 0.75 s minimum silence and the silence
    /// `WindowTracker.pauseStartToleranceSamples` assumes before a pause. On the
    /// recorded sequence three closes at 8.70 s, past the last word's end at
    /// 8.56 s; two would close at 8.50 s and clip it.
    static let softCloseChunks = 3

    /// Decoder confidence an entirely soft final or draft needs to keep its
    /// text. Two speech slices decoded at 0.944 and 0.962 and noise slices at
    /// 0.10 to 0.51. 9 of 583 logged finals (1.5%) and 5 of 178 finals of three
    /// words or fewer (2.8%) fall below 0.80 (that log includes some test-suite
    /// traffic). Audio forwarded inside a soft span is audio the gate dropped
    /// before this existed, so the bar cannot lose a word kept before there.
    /// The exception is the trailing hold `SpeechGate.end()` releases after a
    /// trigger, which the previous build kept at any confidence and which is
    /// now held to this bar.
    static let softSpeechMinConfidence: Float = 0.8
}
