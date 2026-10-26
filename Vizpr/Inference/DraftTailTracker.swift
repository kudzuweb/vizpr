import FluidAudio

/// Pure bookkeeping for the draft track (PR 4.5, adaptive cadence PR 13) and
/// for the commit-time decode of the unconfirmed tail.
///
/// FluidAudio's sliding-window manager only emits after a full window + right
/// context (~12 s) — its advertised 1 s hypothesis track is dead config in the
/// pinned revision. The draft track fills that gap: it re-decodes the
/// *unconfirmed tail* (all audio since the last confirmation, plus a little
/// confirmed left-context for acoustic continuity) and publishes the result as
/// a `.draft`. The cadence is adaptive: the caller asks for a request as soon
/// as its previous decode has finished, and a request is granted once at least
/// `cadenceFloorSamples` of new audio has arrived, so the effective refresh
/// interval is max(floor, decode time). The decode context is the whole tail,
/// so accuracy grows as the tail does. At commit the same tail is decoded one
/// last time, with a wider cap (`commitRange()`), and becomes its final text.
///
/// This type owns the decisions (what samples to decode, when, what to drop);
/// the actor around it owns the buffers and the model call — keeping the
/// boundary math unit-testable without any inference.
struct DraftTailTracker {
    /// Minimum new audio between two draft decodes (500 ms at 16 kHz). Decodes
    /// are not otherwise paced here: the caller requests the next one when the
    /// previous has finished, so a slow decoder lowers the refresh rate on its
    /// own and a fast one is held to this floor.
    let cadenceFloorSamples: Int
    /// Confirmed audio carried before the tail as acoustic left context (~2 s).
    let leftContextSamples: Int
    /// Decode-cost ceiling: the tail passed to the model is capped at this many
    /// trailing samples (~12 s) so a long latched session cannot make draft
    /// passes arbitrarily expensive.
    let maxDecodeSamples: Int
    /// The ceiling for the commit-time decode (15 s), FluidAudio's single-pass
    /// limit. Wider than `maxDecodeSamples` because a window decode still in
    /// flight at commit is dropped by FluidAudio's `cancel()`, and when it is
    /// the session's first window nothing else covers its first seconds.
    let maxCommitSamples: Int
    /// Minimum unconfirmed tail before drafts are emitted (~1.5 s): decoding a
    /// fraction of a second of a fresh window produces junk ("Just a remark",
    /// field-observed). Below this, skip the pass entirely.
    let minTailSamples: Int

    /// Absolute sample index where unconfirmed audio begins.
    private(set) var confirmedBoundary = 0
    /// Absolute sample count appended so far.
    private(set) var totalSamples = 0
    /// Total at the time of the last draft decode.
    private var lastDecodeTotal = 0

    init(
        cadenceFloorSamples: Int = 8_000,
        leftContextSamples: Int = 32_000,
        maxDecodeSamples: Int = 192_000,
        maxCommitSamples: Int = ASRConstants.maxModelSamples,
        minTailSamples: Int = 24_000
    ) {
        self.cadenceFloorSamples = cadenceFloorSamples
        self.leftContextSamples = leftContextSamples
        self.maxDecodeSamples = maxDecodeSamples
        self.maxCommitSamples = maxCommitSamples
        self.minTailSamples = minTailSamples
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

    /// The absolute range the commit-time decode should cover: everything
    /// unconfirmed, trimmed from the front to `maxCommitSamples`. Nil when
    /// nothing is unconfirmed.
    func commitRange() -> Range<Int>? {
        let start = max(confirmedBoundary, totalSamples - maxCommitSamples)
        return start < totalSamples ? start ..< totalSamples : nil
    }

    /// How much of the front of a session buffer is no longer needed by any
    /// future decode. A draft decode starts at max(boundary − leftContext,
    /// total − draft cap) and the commit decode at max(boundary, total − commit
    /// cap); the commit cap is the wider, so the buffer keeps what it needs.
    /// All terms only grow, so everything before the current start is
    /// permanently reclaimable. The buffer owner trims to this.
    var reclaimableSamples: Int {
        max(0, max(confirmedBoundary - leftContextSamples, totalSamples - maxCommitSamples))
    }
}
