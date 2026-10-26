import FluidAudio

/// Pure bookkeeping for the engine's windows, its draft track (PR 4.5,
/// adaptive cadence PR 13) and the commit-time decode of the unconfirmed tail.
///
/// Audio before `confirmedBoundary` is final text; audio after it is not. The
/// engine confirms a window at each pause the VAD reports (`notePause`), or on
/// a clock when speech runs 12 s without one. Every decode is given
/// `leftContextSamples` of audio before its window for acoustic context, and
/// `TimedCut` keeps only the words that start inside the window, so no decode
/// repeats another's words. A forced window also decodes `rightContextSamples`
/// past its nominal end so the cut can land in a gap between words.
///
/// Between confirmations the draft track re-decodes the *unconfirmed tail* and
/// publishes it as a `.draft`. The cadence is adaptive: the caller asks for a
/// request as soon as its previous decode has finished, and a request is
/// granted once at least `cadenceFloorSamples` of new audio has arrived, so the
/// effective refresh interval is max(floor, decode time). At commit the tail
/// is decoded one last time, with a wider cap (`commitPlan()`), and becomes its
/// final text.
///
/// This type owns the decisions (what samples to decode, when, what to drop);
/// the actor around it owns the buffers and the model call — keeping the
/// boundary math unit-testable without any inference.
struct WindowTracker {
    /// Minimum new audio between two draft decodes (500 ms at 16 kHz). Decodes
    /// are not otherwise paced here: the caller requests the next one when the
    /// previous has finished, so a slow decoder lowers the refresh rate on its
    /// own and a fast one is held to this floor.
    let cadenceFloorSamples: Int
    /// Confirmed audio decoded before each window as acoustic left context (2 s).
    let leftContextSamples: Int
    /// Audio decoded past a forced window's nominal end (2 s), so the cut can
    /// land in a gap between words instead of in one.
    let rightContextSamples: Int
    /// The clock window: speech this long without a pause is confirmed anyway (10 s).
    let forcedWindowSamples: Int
    /// A pause closes a window only if it follows at least this much
    /// unconfirmed audio (0.5 s), so a pause right after a confirmation plans nothing.
    let minWindowSamples: Int
    /// Decode-cost ceiling: the tail passed to the model for a draft is capped
    /// at this many trailing samples (~12 s) so a long latched session cannot
    /// make draft passes arbitrarily expensive.
    let maxDecodeSamples: Int
    /// The ceiling for the commit-time decode (15 s), FluidAudio's single-pass
    /// limit. A pause window never reaches it: the forced window fires first
    /// and keeps unconfirmed audio under 12 s, so a window plus its left
    /// context stays under the limit.
    let maxCommitSamples: Int
    /// Minimum unconfirmed tail before drafts are emitted (~1.5 s): decoding a
    /// fraction of a second of a fresh window produces junk ("Just a remark",
    /// field-observed). Below this, skip the pass entirely.
    let minTailSamples: Int

    /// Absolute sample index where unconfirmed audio begins.
    private(set) var confirmedBoundary = 0
    /// The boundary sits at a pause (or the session's start), not inside speech.
    private(set) var boundaryIsPause = true
    /// Absolute sample count appended so far.
    private(set) var totalSamples = 0
    /// Total at the time of the last draft decode.
    private var lastDecodeTotal = 0
    /// The sample count at the most recent pause mark not yet turned into a plan.
    private var pendingPause: Int?

    init(
        cadenceFloorSamples: Int = 8_000,
        leftContextSamples: Int = 32_000,
        rightContextSamples: Int = 32_000,
        forcedWindowSamples: Int = 160_000,
        minWindowSamples: Int = 8_000,
        maxDecodeSamples: Int = 192_000,
        maxCommitSamples: Int = ASRConstants.maxModelSamples,
        minTailSamples: Int
    ) {
        self.cadenceFloorSamples = cadenceFloorSamples
        self.leftContextSamples = leftContextSamples
        self.rightContextSamples = rightContextSamples
        self.forcedWindowSamples = forcedWindowSamples
        self.minWindowSamples = minWindowSamples
        self.maxDecodeSamples = maxDecodeSamples
        self.maxCommitSamples = maxCommitSamples
        self.minTailSamples = minTailSamples
    }

    /// One decode over `range` whose words are kept by where they start in
    /// `cutStart ..< cutEnd`; the rest of the range is context.
    struct WindowPlan: Equatable {
        enum Kind: Equatable {
            case pause, forced, commit
        }

        let range: Range<Int>
        let cutStart: Int
        let cutEnd: Int
        let kind: Kind
        /// `cutStart` is a pause (or the session's start), not a point inside
        /// speech.
        var cutStartIsPause = false

        /// How far before `cutStart` a word may start and still be kept. At a
        /// pause the 0.75 s of audio before the boundary scored as silence, so
        /// no word of the previous window can start in the tolerance. A forced
        /// boundary is the end of the previous window's last kept word, inside
        /// speech, so a tolerance there could keep that word a second time.
        var startTolerance: Int { cutStartIsPause ? WindowTracker.pauseStartToleranceSamples : 0 }
    }

    /// 0.25 s: more than the frame-level disagreement between two decodes of
    /// one word, well under the 0.75 s of silence a pause requires.
    static let pauseStartToleranceSamples = 4_000

    /// The absolute range a draft decode should cover right now, or nil if a
    /// decode isn't due (not enough new audio, or nothing unconfirmed).
    /// Range start includes left context; `draftStart` marks where unconfirmed
    /// audio begins inside it.
    struct DecodeRequest: Equatable {
        let range: Range<Int>
        let draftStart: Int
    }

    mutating func append(sampleCount: Int) {
        totalSamples += sampleCount
    }

    /// The speaker paused at the current end of the appended audio.
    mutating func notePause() {
        pendingPause = totalSamples
    }

    /// A window is due: 12 s of speech without a pause (forced), else a pause
    /// that follows at least `minWindowSamples` of unconfirmed audio. Consumes
    /// the pending pause either way, so a pause too soon after a confirmation
    /// cannot fire later. The forced check runs first, which keeps a pause
    /// plan from covering more than 12 s of unconfirmed audio plus its context;
    /// a forced plan keeps a pending pause that lies at least
    /// `minWindowSamples` past its nominal end.
    mutating func takeConfirmPlan() -> WindowPlan? {
        let contextStart = max(0, confirmedBoundary - leftContextSamples)
        if totalSamples - confirmedBoundary >= forcedWindowSamples + rightContextSamples {
            let cutEnd = confirmedBoundary + forcedWindowSamples
            // A pause far enough past the cut survives: the next call plans
            // its window from the new boundary. Any earlier pause is covered
            // by the forced window.
            if let pause = pendingPause, pause - cutEnd < minWindowSamples {
                pendingPause = nil
            }
            return WindowPlan(
                range: contextStart ..< cutEnd + rightContextSamples,
                cutStart: confirmedBoundary,
                cutEnd: cutEnd,
                kind: .forced,
                cutStartIsPause: boundaryIsPause
            )
        }
        guard let pause = pendingPause else { return nil }
        pendingPause = nil
        guard pause - confirmedBoundary >= minWindowSamples else { return nil }
        return WindowPlan(
            range: contextStart ..< pause, cutStart: confirmedBoundary, cutEnd: pause, kind: .pause,
            cutStartIsPause: boundaryIsPause
        )
    }

    /// Confirmed text now covers audio up to this absolute sample. Monotonic:
    /// regressions (stale confirmations) are ignored. `atPause` says the new
    /// boundary is a pause, which the next window's cut tolerates.
    mutating func confirm(through sample: Int, atPause: Bool = false) {
        let advanced = min(sample, totalSamples)
        guard advanced > confirmedBoundary else { return }
        confirmedBoundary = advanced
        boundaryIsPause = atPause
    }

    /// Ask whether a draft decode is due; consuming the request resets the
    /// floor clock.
    mutating func takeDecodeRequest() -> DecodeRequest? {
        guard totalSamples - lastDecodeTotal >= cadenceFloorSamples else { return nil }
        guard totalSamples - confirmedBoundary >= minTailSamples else {
            // Too little unconfirmed audio to decode usefully (nothing new, or
            // just a sub-threshold fragment of a fresh window). Skip, but reset
            // the clock so confirmed-only audio doesn't leave a stale cadence
            // credit that fires the instant real speech arrives.
            lastDecodeTotal = totalSamples
            return nil
        }

        let contextStart = max(0, confirmedBoundary - leftContextSamples)
        let start = max(contextStart, totalSamples - maxDecodeSamples)
        lastDecodeTotal = totalSamples
        return DecodeRequest(range: start ..< totalSamples, draftStart: confirmedBoundary)
    }

    /// The commit-time decode: everything unconfirmed, with left context,
    /// trimmed from the front to `maxCommitSamples`. Nil when nothing is
    /// unconfirmed.
    func commitPlan() -> WindowPlan? {
        guard confirmedBoundary < totalSamples else { return nil }
        let start = max(confirmedBoundary - leftContextSamples, totalSamples - maxCommitSamples, 0)
        return WindowPlan(
            range: start ..< totalSamples,
            cutStart: max(confirmedBoundary, start),
            cutEnd: totalSamples,
            kind: .commit,
            cutStartIsPause: boundaryIsPause && start <= confirmedBoundary
        )
    }

    /// How much of the front of a session buffer is no longer needed by any
    /// future decode. Every decode starts at max(boundary − leftContext, …) and
    /// the commit decode at max(boundary − leftContext, total − commit cap),
    /// which is the widest, so the buffer keeps what it needs. All terms only
    /// grow, so everything before the current start is permanently
    /// reclaimable. The buffer owner trims to this.
    var reclaimableSamples: Int {
        max(0, max(confirmedBoundary - leftContextSamples, totalSamples - maxCommitSamples))
    }
}
