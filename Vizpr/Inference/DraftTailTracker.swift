/// Pure bookkeeping for the draft track (PR 4.5).
///
/// FluidAudio's sliding-window manager only emits after a full window + right
/// context (~12 s) — its advertised 1 s hypothesis track is dead config in the
/// pinned revision. The draft track fills that gap: every ~1 s of new audio it
/// re-decodes the *unconfirmed tail* (all audio since the last confirmation,
/// plus a little confirmed left-context for acoustic continuity) and publishes
/// the result as a `.draft`. One second is the refresh cadence; the decode
/// context is the whole tail, so accuracy grows as the tail does.
///
/// This type owns the decisions (what samples to decode, when, what to drop);
/// the actor around it owns the buffers and the model call — keeping the
/// boundary math unit-testable without any inference.
struct DraftTailTracker {
    /// New-audio accumulation that triggers a draft decode (~1 s at 16 kHz).
    let cadenceSamples: Int
    /// Confirmed audio carried before the tail as acoustic left context (~2 s).
    let leftContextSamples: Int
    /// Decode-cost ceiling: the tail passed to the model is capped at this many
    /// trailing samples (~12 s) so a long latched session cannot make draft
    /// passes arbitrarily expensive.
    let maxDecodeSamples: Int

    /// Absolute sample index where unconfirmed audio begins.
    private(set) var confirmedBoundary = 0
    /// Absolute sample count appended so far.
    private(set) var totalSamples = 0
    /// Total at the time of the last draft decode.
    private var lastDecodeTotal = 0

    init(
        cadenceSamples: Int = 16_000,
        leftContextSamples: Int = 32_000,
        maxDecodeSamples: Int = 192_000
    ) {
        self.cadenceSamples = cadenceSamples
        self.leftContextSamples = leftContextSamples
        self.maxDecodeSamples = maxDecodeSamples
    }

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

    /// Confirmed text now covers audio up to this absolute sample. Monotonic:
    /// regressions (stale confirmations) are ignored.
    mutating func confirm(through sample: Int) {
        confirmedBoundary = max(confirmedBoundary, min(sample, totalSamples))
    }

    /// Ask whether a draft decode is due; consuming the request resets the
    /// cadence clock.
    mutating func takeDecodeRequest() -> DecodeRequest? {
        guard totalSamples - lastDecodeTotal >= cadenceSamples else { return nil }
        guard totalSamples > confirmedBoundary else {
            // Nothing unconfirmed: skip, but reset the clock so a burst of
            // confirmed-only audio doesn't fire a decode the instant new
            // speech arrives with a stale cadence credit.
            lastDecodeTotal = totalSamples
            return nil
        }

        let contextStart = max(0, confirmedBoundary - leftContextSamples)
        let start = max(contextStart, totalSamples - maxDecodeSamples)
        lastDecodeTotal = totalSamples
        return DecodeRequest(range: start ..< totalSamples, draftStart: confirmedBoundary)
    }

    /// How much of the front of a session buffer is no longer needed by any
    /// future decode. A decode starts at max(boundary − leftContext, total − cap),
    /// and both terms only grow, so everything before the current start is
    /// permanently reclaimable. The buffer owner trims to this.
    var reclaimableSamples: Int {
        max(0, max(confirmedBoundary - leftContextSamples, totalSamples - maxDecodeSamples))
    }
}
