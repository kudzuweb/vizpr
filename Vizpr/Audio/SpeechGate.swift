/// Decides which captured batches reach the transcription engine. While the
/// VAD reports speech the gate forwards audio; while it does not, the gate
/// holds the most recent audio back, so the engine is never fed the long
/// silence that precedes an auto-stop. The ASR decodes silence into invented
/// words, so bounding what it hears also bounds what it can invent.
///
/// For a short window after each speech end the gate also accepts a lower
/// bar than the VAD's trigger: soft speech that resumes right after a pause
/// scores under the trigger threshold, so the VAD never fires on it. Audio
/// forwarded on that lower bar is flagged `soft`, and the engine keeps its
/// text only when the decoder is confident in it.
///
/// Pure value type: `AudioPipeline` feeds it the detector's state per batch.
struct SpeechGate {
    /// 1 s. The detector raises `speechActive` on the first 256 ms chunk
    /// scoring at least 0.85 and a soft onset often scores lower first, so the
    /// hold must reach back more than one chunk to keep the start of a word.
    static let preRollSamples = 16_384
    /// 4 s. Until the detector first triggers, the hold is longer, so a quiet
    /// utterance the VAD missed is not lost and a session with no speech still
    /// bounds the silence handed to the decoder.
    static let untriggeredHoldSamples = 64_000
    /// A held chunk at or above this probability is probably a word spoken
    /// after a pause that had not reached the trigger threshold. A soft span
    /// stays open while chunks keep scoring at or above it.
    private static let heldSpeechProbability: Float = 0.5

    /// One batch to forward. `soft` is true when only the lower re-onset
    /// threshold let it through.
    struct Batch: Equatable {
        let samples: [Float]
        let soft: Bool
    }

    /// A soft span opening or closing during a batch.
    enum SoftTransition: Equatable {
        case opened, closed
    }

    struct Output: Equatable {
        /// The batches to forward now, in order.
        var batches: [Batch] = []
        /// `.closed` means the speaker paused: the caller sends a pause mark
        /// after `batches`, so the soft span becomes its own window.
        var softTransition: SoftTransition?
    }

    private struct HeldBatch {
        let samples: [Float]
        /// The batch completed a chunk scoring at least 0.5 while the gate was
        /// already inactive, so it may hold a word the trigger missed. The
        /// batch that flips the gate to inactive never earns this: its chunk
        /// still belongs to the speech that just ended.
        let mayHoldSpeech: Bool
    }

    private var held: [HeldBatch] = []
    private var heldSampleCount = 0
    private var everActive = false
    private var wasActive = false
    /// Captured samples since the batch that flipped the gate to inactive, or
    /// nil when no re-onset window is open. Only a flip from active opens one;
    /// a soft span never does, so noise cannot chain windows.
    private var samplesSinceSpeechEnd: Int?
    private var inSoftSpan = false
    private var consecutiveLowChunks = 0

    /// - Parameters:
    ///   - speechActive: the detector's hysteresis state after the latest chunk.
    ///   - chunkProbability: raw score of the chunk this batch completed, or
    ///     nil when it completed none.
    mutating func feed(_ samples: [Float], speechActive: Bool, chunkProbability: Float?) -> Output {
        if speechActive {
            everActive = true
            wasActive = true
            samplesSinceSpeechEnd = nil
            inSoftSpan = false
            consecutiveLowChunks = 0
            return Output(batches: release(including: samples, soft: false))
        }

        let flipping = wasActive
        wasActive = false
        if flipping {
            samplesSinceSpeechEnd = 0
        } else if let elapsed = samplesSinceSpeechEnd {
            samplesSinceSpeechEnd = elapsed + samples.count
        }

        if inSoftSpan {
            return feedSoftSpan(samples, chunkProbability: chunkProbability)
        }
        if !flipping, reonsetWindowIsOpen, (chunkProbability ?? 0) >= Tuning.reonsetProbability {
            inSoftSpan = true
            consecutiveLowChunks = 0
            return Output(batches: release(including: samples, soft: true), softTransition: .opened)
        }

        let scoredSpeech = (chunkProbability ?? 0) >= Self.heldSpeechProbability
        held.append(HeldBatch(samples: samples, mayHoldSpeech: scoredSpeech && !flipping))
        heldSampleCount += samples.count
        let limit = everActive ? Self.preRollSamples : Self.untriggeredHoldSamples
        while let oldest = held.first, heldSampleCount - oldest.samples.count >= limit {
            held.removeFirst()
            heldSampleCount -= oldest.samples.count
        }
        return Output()
    }

    /// The batches to forward before the stream closes: the hold when the
    /// session never activated or the hold contains probable speech, otherwise
    /// nothing. The hold is cleared either way. Once the session has
    /// triggered, the released audio is flagged soft: it passed no trigger.
    mutating func end() -> [Batch] {
        let released = (!everActive || held.contains(where: \.mayHoldSpeech)) ? held.map(\.samples) : []
        discardHold()
        return released.map { Batch(samples: $0, soft: everActive) }
    }

    private var reonsetWindowIsOpen: Bool {
        guard let elapsed = samplesSinceSpeechEnd else { return false }
        return elapsed <= Tuning.reonsetWindowSamples
    }

    /// Forwards the batch and counts consecutive quiet chunks; the batch that
    /// completes the last quiet chunk closes the span.
    private mutating func feedSoftSpan(_ samples: [Float], chunkProbability: Float?) -> Output {
        var output = Output(batches: [Batch(samples: samples, soft: true)])
        guard let probability = chunkProbability else { return output }
        consecutiveLowChunks = probability < Self.heldSpeechProbability ? consecutiveLowChunks + 1 : 0
        if consecutiveLowChunks >= Tuning.softCloseChunks {
            inSoftSpan = false
            consecutiveLowChunks = 0
            output.softTransition = .closed
        }
        return output
    }

    /// The held batches followed by `samples`, all with the same flag.
    private mutating func release(including samples: [Float], soft: Bool) -> [Batch] {
        let released = (held.map(\.samples) + [samples]).map { Batch(samples: $0, soft: soft) }
        discardHold()
        return released
    }

    private mutating func discardHold() {
        held.removeAll()
        heldSampleCount = 0
    }
}
