/// Decides which captured batches reach the transcription engine. While the
/// VAD reports speech the gate forwards audio; while it does not, the gate
/// holds the most recent audio back, so the engine is never fed the long
/// silence that precedes an auto-stop. The ASR decodes silence into invented
/// words, so bounding what it hears also bounds what it can invent.
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
    /// after a pause that had not reached the trigger threshold.
    private static let heldSpeechProbability: Float = 0.5

    private var held: [[Float]] = []
    private var heldSampleCount = 0
    private var everActive = false
    private var heldSpeech = false

    /// - Parameters:
    ///   - speechActive: the detector's hysteresis state after the latest chunk.
    ///   - probability: raw score of that chunk. A batch that completed no chunk
    ///     passes the previous values.
    /// - Returns: the batches to forward now, in order.
    mutating func feed(_ samples: [Float], speechActive: Bool, probability: Float) -> [[Float]] {
        if speechActive {
            everActive = true
            heldSpeech = false
            let released = held + [samples]
            discardHold()
            return released
        }
        held.append(samples)
        heldSampleCount += samples.count
        if probability >= Self.heldSpeechProbability { heldSpeech = true }
        let limit = everActive ? Self.preRollSamples : Self.untriggeredHoldSamples
        while let oldest = held.first, heldSampleCount - oldest.count >= limit {
            held.removeFirst()
            heldSampleCount -= oldest.count
        }
        return []
    }

    /// The batches to forward before the stream closes: the hold when the
    /// session never activated or the hold contains probable speech, otherwise
    /// nothing. The hold is cleared either way.
    mutating func end() -> [[Float]] {
        let released = (!everActive || heldSpeech) ? held : []
        discardHold()
        return released
    }

    private mutating func discardHold() {
        held.removeAll()
        heldSampleCount = 0
    }
}
