import Testing
@testable import Vizpr

@Suite("SpeechGate")
struct SpeechGateTests {

    /// A batch of `count` samples all equal to `tag`, so tests can tell batches apart.
    private func batch(_ tag: Float, count: Int = 1_600) -> [Float] {
        [Float](repeating: tag, count: count)
    }

    private func tags(_ batches: [[Float]]) -> [Float] {
        batches.compactMap(\.first)
    }

    @Test("Activation releases the held batches before the activating batch, in arrival order")
    func activationReleasesHoldInOrder() {
        var gate = SpeechGate()
        #expect(gate.feed(batch(1), speechActive: false, chunkProbability: 0.1).isEmpty)
        #expect(gate.feed(batch(2), speechActive: false, chunkProbability: 0.1).isEmpty)
        let released = gate.feed(batch(3), speechActive: true, chunkProbability: 0.9)
        #expect(tags(released) == [1, 2, 3])
        #expect(tags(gate.feed(batch(4), speechActive: true, chunkProbability: 0.9)) == [4])
    }

    @Test("While inactive after activation the hold keeps at least the pre-roll and drops the oldest beyond it")
    func inactiveHoldKeepsPreRoll() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        // 12 batches of 1,600 = 19,200 samples; the pre-roll is 16,384, so the
        // hold keeps 11 batches (17,600) and drops the oldest one.
        for tag in 1...12 {
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.1)
        }
        let released = gate.feed(batch(13), speechActive: true, chunkProbability: 0.9)
        #expect(tags(released) == [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
        #expect(released.dropLast().reduce(0) { $0 + $1.count } >= SpeechGate.preRollSamples)
    }

    @Test("end() returns nothing after an activated session whose hold scored under 0.5")
    func endDiscardsSilentHold() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        for tag in 1...5 {
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.49)
        }
        #expect(gate.end().isEmpty)
    }

    @Test("end() returns the hold after an activated session whose hold scored 0.5 or more")
    func endReturnsHeldSpeech() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: 0.5)
        _ = gate.feed(batch(3), speechActive: false, chunkProbability: 0.2)
        #expect(tags(gate.end()) == [1, 2, 3])
        #expect(gate.end().isEmpty, "end() clears the hold")
    }

    @Test("A session that never activates holds up to the untriggered limit and end() returns it")
    func neverActivatedHoldsFourSeconds() {
        var gate = SpeechGate()
        // 60 batches of 1,600 = 96,000 samples; the limit is 64,000, so the
        // hold keeps 40 batches (64,000) and drops the oldest 20.
        for tag in 1...60 {
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0)
        }
        let released = gate.end()
        #expect(released.count == 40)
        #expect(released.first?.first == 21)
        #expect(released.reduce(0) { $0 + $1.count } == SpeechGate.untriggeredHoldSamples)
    }

    @Test("Activation clears the held-speech flag")
    func activationClearsHeldSpeech() {
        var gate = SpeechGate()
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.7)
        _ = gate.feed(batch(2), speechActive: true, chunkProbability: 0.9)
        _ = gate.feed(batch(3), speechActive: false, chunkProbability: 0.1)
        #expect(gate.end().isEmpty)
    }

    @Test("A flagged batch trimmed out of the hold by 2 s of low-scoring batches no longer releases it")
    func trimmedFlagDoesNotRelease() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: 0.9)   // flagged
        for tag in 3..<23 {   // 20 batches = 2 s
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.1)
        }
        #expect(gate.end().isEmpty)
    }

    @Test("The batch that flips the gate to inactive never sets the flag")
    func flippingBatchDoesNotSetFlag() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.9)
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: nil)
        #expect(gate.end().isEmpty)
    }

    @Test("A batch that completed no chunk never sets the flag")
    func noChunkDoesNotSetFlag() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: nil)
        #expect(gate.end().isEmpty)
    }
}
