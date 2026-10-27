import Testing
@testable import Vizpr

@Suite("SpeechGate")
struct SpeechGateTests {

    /// A batch of `count` samples all equal to `tag`, so tests can tell batches apart.
    private func batch(_ tag: Float, count: Int = 1_600) -> [Float] {
        [Float](repeating: tag, count: count)
    }

    private func tags(_ batches: [SpeechGate.Batch]) -> [Float] {
        batches.compactMap(\.samples.first)
    }

    private func tags(_ output: SpeechGate.Output) -> [Float] {
        tags(output.batches)
    }

    @Test("Activation releases the held batches before the activating batch, in arrival order")
    func activationReleasesHoldInOrder() {
        var gate = SpeechGate()
        #expect(gate.feed(batch(1), speechActive: false, chunkProbability: 0.1).batches.isEmpty)
        #expect(gate.feed(batch(2), speechActive: false, chunkProbability: 0.1).batches.isEmpty)
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
        #expect(released.batches.dropLast().reduce(0) { $0 + $1.samples.count } >= SpeechGate.preRollSamples)
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
        #expect(released.first?.samples.first == 21)
        #expect(released.reduce(0) { $0 + $1.samples.count } == SpeechGate.untriggeredHoldSamples)
        #expect(released.allSatisfy { !$0.soft }, "a session that never triggered releases ordinary audio")
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
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: 0.55)   // flagged, under the re-onset bar
        for tag in 3..<23 {   // 20 batches = 2 s
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.1)
        }
        #expect(gate.end().isEmpty)
    }

    @Test("The batch that flips the gate to inactive never sets the flag")
    func flippingBatchDoesNotSetFlag() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        let flip = gate.feed(batch(1), speechActive: false, chunkProbability: 0.9)
        #expect(flip == SpeechGate.Output(), "the flipping batch opens no soft span")
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

// MARK: Soft spans (re-onset after a speech end)

extension SpeechGateTests {

    private static let chunk = 4_096

    private func chunkBatch(_ tag: Float) -> [Float] {
        [Float](repeating: tag, count: Self.chunk)
    }

    /// A gate that has been active and just flipped to inactive on batch 1.
    private func gateAfterSpeechEnd() -> SpeechGate {
        var gate = SpeechGate()
        _ = gate.feed(chunkBatch(0), speechActive: true, chunkProbability: 0.95)
        _ = gate.feed(chunkBatch(1), speechActive: false, chunkProbability: 0.2)
        return gate
    }

    /// Chunks 24 to 37 of the 2026-10-26 recording: the probabilities the
    /// second sentence scored after the first sentence's speech end.
    private static let recorded: [Float] = [
        0.36, 0.34, 0.20, 0.18, 0.31, 0.66, 0.49, 0.64, 0.35, 0.16, 0.10, 0.10, 0.08, 0.06
    ]

    @Test("The recorded second sentence opens a soft span, is forwarded soft, then closes with one pause")
    func recordedSequence() {
        var gate = SpeechGate()
        var forwarded: [Float] = []
        var transitions: [(chunk: Int, transition: SpeechGate.SoftTransition)] = []
        for (offset, probability) in Self.recorded.enumerated() {
            let chunkNumber = 24 + offset
            // The VAD's state: active through chunk 25, inactive from the flip at chunk 26.
            let output = gate.feed(
                chunkBatch(Float(chunkNumber)), speechActive: chunkNumber <= 25, chunkProbability: probability
            )
            forwarded += tags(output)
            if chunkNumber > 26 {
                #expect(output.batches.allSatisfy { $0.soft }, "chunk \(chunkNumber) forwarded as ordinary audio")
            }
            if let transition = output.softTransition { transitions.append((chunkNumber, transition)) }
        }
        // Chunk 29 opens the span and releases the hold (26 to 28) before it;
        // chunk 34 completes the third low chunk and is the last forwarded.
        #expect(forwarded.suffix(9) == [26, 27, 28, 29, 30, 31, 32, 33, 34])
        #expect(!forwarded.contains(where: { $0 >= 35 }), "chunks 35 to 37 are held")
        #expect(transitions.map(\.chunk) == [29, 34])
        #expect(transitions.map(\.transition) == [.opened, .closed])
    }

    @Test("Noise under the re-onset bar after a speech end forwards nothing")
    func noiseForwardsNothing() {
        var gate = gateAfterSpeechEnd()
        for index in 0..<60 {
            let probability = 0.05 + 0.32 * Float((index * 7) % 10) / 9   // 0.05 to 0.37
            let output = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: probability)
            #expect(output == SpeechGate.Output())
        }
        #expect(gate.end().isEmpty)
    }

    @Test("A chunk after the re-onset window has expired does not open a span")
    func windowExpiry() {
        var inside = gateAfterSpeechEnd()
        let nearEnd = [Float](repeating: 2, count: Tuning.reonsetWindowSamples - 2 * Self.chunk)
        let transition1 = inside.feed(nearEnd, speechActive: false, chunkProbability: 0.1).softTransition
        #expect(transition1 == nil)
        let transition2 = inside.feed(chunkBatch(3), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(transition2 == .opened)

        var outside = gateAfterSpeechEnd()
        let pastEnd = [Float](repeating: 2, count: Tuning.reonsetWindowSamples + 1_600)
        let output = outside.feed(pastEnd, speechActive: false, chunkProbability: 0.7)
        #expect(output == SpeechGate.Output())
    }

    @Test("A soft span never opens a window of its own, but may re-open inside the one a speech end opened")
    func noChaining() {
        // A span that closes inside the window may re-open.
        var gate = gateAfterSpeechEnd()
        let transition3 = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(transition3 == .opened)
        for _ in 0..<2 { _ = gate.feed(chunkBatch(3), speechActive: false, chunkProbability: 0.1) }
        let transition4 = gate.feed(chunkBatch(4), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(transition4 == .closed)
        let transition5 = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(transition5 == .opened)

        // A span that runs past the window and then closes opens no new window.
        var late = gateAfterSpeechEnd()
        let transition6 = late.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(transition6 == .opened)
        let chunksInWindow = Tuning.reonsetWindowSamples / Self.chunk + 2
        for _ in 0..<chunksInWindow { _ = late.feed(chunkBatch(3), speechActive: false, chunkProbability: 0.8) }
        for _ in 0..<2 { _ = late.feed(chunkBatch(4), speechActive: false, chunkProbability: 0.1) }
        let transition7 = late.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(transition7 == .closed)
        let afterClose = late.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.9)
        #expect(afterClose == SpeechGate.Output())
    }

    @Test("A soft span's close emits exactly one pause, after its last batch")
    func closeEmitsOnePause() {
        var gate = gateAfterSpeechEnd()
        _ = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.7)
        var closings = 0
        var lastTag: Float?
        for tag in 3...12 {
            let output = gate.feed(chunkBatch(Float(tag)), speechActive: false, chunkProbability: 0.1)
            if output.softTransition == .closed {
                closings += 1
                lastTag = tags(output).last
            } else if closings > 0 {
                #expect(output.batches.isEmpty, "nothing is forwarded after the close")
            }
        }
        #expect(closings == 1)
        #expect(lastTag == 5, "the batch completing the third low chunk is forwarded before the pause")
    }

    @Test("A chunk at 0.5 or more resets the quiet count, and a batch with no chunk does not advance it")
    func closeCounting() {
        var gate = gateAfterSpeechEnd()
        _ = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.7)
        _ = gate.feed(chunkBatch(3), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(4), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.5)   // resets
        _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: nil)
        let still = gate.feed(chunkBatch(8), speechActive: false, chunkProbability: 0.1)
        #expect(still.softTransition == nil)
        let transition8 = gate.feed(chunkBatch(9), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(transition8 == .closed)
    }

    @Test("Opening releases the held batches and the opening batch, all soft, in order")
    func openingReleasesHold() {
        var gate = gateAfterSpeechEnd()
        _ = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.2)
        let output = gate.feed(chunkBatch(3), speechActive: false, chunkProbability: 0.9)
        #expect(tags(output) == [1, 2, 3])
        #expect(output.batches.allSatisfy { $0.soft })
        #expect(output.softTransition == .opened)
    }

    @Test("A real activation during a soft span turns the rest into ordinary audio")
    func activationEndsSoftSpan() {
        var gate = gateAfterSpeechEnd()
        _ = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.7)
        let output = gate.feed(chunkBatch(3), speechActive: true, chunkProbability: 0.95)
        #expect(tags(output) == [3])
        #expect(output.batches.allSatisfy { !$0.soft })
        // The next speech end is a real flip and opens a fresh window.
        _ = gate.feed(chunkBatch(4), speechActive: false, chunkProbability: 0.2)
        let transition9 = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(transition9 == .opened)
    }

    @Test("end() flags what it releases as soft once the session has triggered")
    func endFlagsSoftAfterTrigger() {
        var gate = SpeechGate()
        _ = gate.feed(chunkBatch(0), speechActive: true, chunkProbability: 0.95)
        _ = gate.feed(chunkBatch(1), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(chunkBatch(2), speechActive: false, chunkProbability: 0.55)
        let released = gate.end()
        #expect(tags(released) == [1, 2])
        #expect(released.allSatisfy { $0.soft })
    }
}
