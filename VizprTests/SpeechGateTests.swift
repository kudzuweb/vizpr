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

    /// Ends speech the way the detector does: the flipping batch opens a
    /// trailing span, and three quiet chunks close it. After this the hold is
    /// empty and the gate behaves as it did before the span.
    private func endSpeech(_ gate: inout SpeechGate) {
        for tag in 100...103 {
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: tag == 100 ? 0.2 : 0.1)
        }
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
        endSpeech(&gate)
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
        endSpeech(&gate)
        for tag in 1...5 {
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.49)
        }
        #expect(gate.end().isEmpty)
    }

    @Test("end() returns the hold after an activated session whose hold scored 0.5 or more")
    func endReturnsHeldSpeech() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        endSpeech(&gate)
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
        endSpeech(&gate)
        _ = gate.feed(batch(3), speechActive: false, chunkProbability: 0.1)
        #expect(gate.end().isEmpty)
    }

    @Test("A flagged batch trimmed out of the hold by 2 s of low-scoring batches no longer releases it")
    func trimmedFlagDoesNotRelease() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        endSpeech(&gate)
        _ = gate.feed(batch(1), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(batch(2), speechActive: false, chunkProbability: 0.55)   // flagged, under the re-onset bar
        for tag in 3..<23 {   // 20 batches = 2 s
            _ = gate.feed(batch(Float(tag)), speechActive: false, chunkProbability: 0.1)
        }
        #expect(gate.end().isEmpty)
    }

    @Test("The batch that flips the gate to inactive is forwarded soft and opens a trailing span")
    func flippingBatchOpensTrailingSpan() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        let flip = gate.feed(batch(1), speechActive: false, chunkProbability: 0.9)
        #expect(tags(flip) == [1])
        #expect(flip.batches.allSatisfy { $0.soft })
        #expect(flip.softTransition == .trailingOpened)
        #expect(gate.end().isEmpty, "the flipping batch leaves nothing in the hold")
    }

    @Test("A batch that completed no chunk never sets the flag")
    func noChunkDoesNotSetFlag() {
        var gate = SpeechGate()
        _ = gate.feed(batch(0), speechActive: true, chunkProbability: 0.9)
        endSpeech(&gate)
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

    /// A gate that was active, flipped to inactive on batch 1, and closed its
    /// trailing span on batch 4 (three quiet chunks), so its window is open.
    private func gateAfterTrailingClose() -> SpeechGate {
        var gate = SpeechGate()
        _ = gate.feed(chunkBatch(0), speechActive: true, chunkProbability: 0.95)
        _ = gate.feed(chunkBatch(1), speechActive: false, chunkProbability: 0.2)
        for tag in 2...4 { _ = gate.feed(chunkBatch(Float(tag)), speechActive: false, chunkProbability: 0.1) }
        return gate
    }

    /// Chunks 24 to 37 of the 2026-10-26 recording: the probabilities the
    /// second sentence scored after the first sentence's speech end.
    private static let recorded: [Float] = [
        0.36, 0.34, 0.20, 0.18, 0.31, 0.66, 0.49, 0.64, 0.35, 0.16, 0.10, 0.10, 0.08, 0.06
    ]

    /// Chunks 12 to 34 of the 2026-10-27 recording, whose soft sentence the
    /// detector ended at chunk 16 while it was still being spoken.
    private static let recordedMurmur: [Float] = [
        0.71, 0.58, 0.43, 0.49, 0.66, 0.70, 0.35, 0.96, 0.68, 0.58, 0.46, 0.32,
        0.23, 0.18, 0.10, 0.07, 0.05, 0.04, 0.04, 0.03, 0.02, 0.02, 0.01
    ]

    @Test("A trailing span after a speech end forwards three quiet chunks soft and closes with one pause")
    func trailingSpanFollowsSpeechEnd() {
        var gate = SpeechGate()
        _ = gate.feed(chunkBatch(0), speechActive: true, chunkProbability: 0.95)
        let flip = gate.feed(chunkBatch(1), speechActive: false, chunkProbability: 0.2)
        #expect(tags(flip) == [1])
        #expect(flip.batches.allSatisfy { $0.soft })
        #expect(flip.softTransition == .trailingOpened)
        for tag in 2...4 {
            let output = gate.feed(chunkBatch(Float(tag)), speechActive: false, chunkProbability: 0.1)
            #expect(tags(output) == [Float(tag)])
            #expect(output.batches.allSatisfy { $0.soft })
            #expect(output.softTransition == (tag == 4 ? .closed : nil))
        }
        #expect(gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.1) == SpeechGate.Output())
    }

    @Test("The 2026-10-27 murmur is forwarded through its last word and closes with one pause")
    func recordedMurmur() {
        var gate = SpeechGate()
        var transitions: [(chunk: Int, transition: SpeechGate.SoftTransition)] = []
        for (offset, probability) in Self.recordedMurmur.enumerated() {
            let chunkNumber = 12 + offset
            let active = (12...15).contains(chunkNumber) || (19...22).contains(chunkNumber)
            let output = gate.feed(
                chunkBatch(Float(chunkNumber)), speechActive: active, chunkProbability: probability
            )
            if let transition = output.softTransition { transitions.append((chunkNumber, transition)) }
            switch chunkNumber {
            case 12...15, 19...22:
                #expect(tags(output) == [Float(chunkNumber)])
                #expect(output.batches.allSatisfy { !$0.soft }, "chunk \(chunkNumber) should be ordinary")
            case 16...18, 23...26:
                #expect(tags(output) == [Float(chunkNumber)])
                #expect(output.batches.allSatisfy { $0.soft }, "chunk \(chunkNumber) should be soft")
            default:
                #expect(output.batches.isEmpty, "chunk \(chunkNumber) should be held")
            }
        }
        #expect(transitions.map(\.chunk) == [16, 23, 26])
        #expect(transitions.map(\.transition) == [.trailingOpened, .trailingOpened, .closed])
    }

    @Test("The recorded second sentence joins the first sentence's trailing span, which closes with one pause")
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
            if chunkNumber >= 26 {
                #expect(output.batches.allSatisfy { $0.soft }, "chunk \(chunkNumber) forwarded as ordinary audio")
            }
            if let transition = output.softTransition { transitions.append((chunkNumber, transition)) }
        }
        // Chunks 29 (0.66) and 31 (0.64) reset the quiet count, so chunk 34
        // completes the third low chunk and closes the span.
        #expect(forwarded == (24...34).map(Float.init))
        #expect(!forwarded.contains(where: { $0 >= 35 }), "chunks 35 to 37 are held")
        #expect(transitions.map(\.chunk) == [26, 34])
        #expect(transitions.map(\.transition) == [.trailingOpened, .closed])
    }

    @Test("Noise under the re-onset bar after a trailing close forwards nothing")
    func noiseForwardsNothing() {
        var gate = gateAfterTrailingClose()
        for index in 0..<60 {
            let probability = 0.05 + 0.32 * Float((index * 7) % 10) / 9   // 0.05 to 0.37
            let output = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: probability)
            #expect(output == SpeechGate.Output())
        }
        #expect(gate.end().isEmpty)
    }

    @Test("The re-onset window is counted from the trailing close: open at 2.9 s, shut at 3.1 s")
    func windowStartsAtTrailingClose() {
        // The filler holds the quiet audio before the chunk that arrives
        // `seconds` after the closing batch, which the chunk's own samples end.
        func openedChunk(arrivingAt seconds: Double) -> SpeechGate.SoftTransition? {
            var gate = gateAfterTrailingClose()
            let filler = [Float](repeating: 5, count: Int(seconds * 16_000) - Self.chunk)
            _ = gate.feed(filler, speechActive: false, chunkProbability: 0.1)
            return gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.7).softTransition
        }
        #expect(openedChunk(arrivingAt: 2.9) == .opened)
        #expect(openedChunk(arrivingAt: 3.1) == nil)
    }

    @Test("A re-onset span may re-open inside the window a trailing close opened")
    func reopensInsideWindow() {
        var gate = gateAfterTrailingClose()
        let firstOpen = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(firstOpen == .opened)
        for _ in 0..<2 { _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.1) }
        let closed = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(closed == .closed)
        let reopened = gate.feed(chunkBatch(8), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(reopened == .opened)
    }

    @Test("A re-onset span that closes after the window has expired opens no new window")
    func reonsetCloseOpensNoWindow() {
        var gate = gateAfterTrailingClose()
        let open = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(open == .opened)
        let chunksInWindow = Tuning.reonsetWindowSamples / Self.chunk + 2
        for _ in 0..<chunksInWindow { _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.8) }
        for _ in 0..<2 { _ = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: 0.1) }
        let close = gate.feed(chunkBatch(8), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(close == .closed)
        let afterClose = gate.feed(chunkBatch(9), speechActive: false, chunkProbability: 0.9)
        #expect(afterClose == SpeechGate.Output())
    }

    @Test("A soft span's close emits exactly one pause, after its last batch")
    func closeEmitsOnePause() {
        var gate = gateAfterTrailingClose()
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7)
        var closings = 0
        var lastTag: Float?
        for tag in 6...15 {
            let output = gate.feed(chunkBatch(Float(tag)), speechActive: false, chunkProbability: 0.1)
            if output.softTransition == .closed {
                closings += 1
                lastTag = tags(output).last
            } else if closings > 0 {
                #expect(output.batches.isEmpty, "nothing is forwarded after the close")
            }
        }
        #expect(closings == 1)
        #expect(lastTag == 8, "the batch completing the third low chunk is forwarded before the pause")
    }

    @Test("A chunk at 0.5 or more resets the quiet count, and a batch with no chunk does not advance it")
    func closeCounting() {
        var gate = gateAfterTrailingClose()
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7)
        _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(8), speechActive: false, chunkProbability: 0.5)   // resets
        _ = gate.feed(chunkBatch(9), speechActive: false, chunkProbability: 0.1)
        _ = gate.feed(chunkBatch(10), speechActive: false, chunkProbability: nil)
        let still = gate.feed(chunkBatch(11), speechActive: false, chunkProbability: 0.1)
        #expect(still.softTransition == nil)
        let closedAfterReset = gate.feed(chunkBatch(12), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(closedAfterReset == .closed)
    }

    @Test("Opening releases the held batches and the opening batch, all soft, in order")
    func openingReleasesHold() {
        var gate = gateAfterTrailingClose()
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.2)
        let output = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: 0.9)
        #expect(tags(output) == [5, 6, 7])
        #expect(output.batches.allSatisfy { $0.soft })
        #expect(output.softTransition == .opened)
    }

    @Test("A real activation during a soft span turns the rest into ordinary audio")
    func activationEndsSoftSpan() {
        var gate = gateAfterTrailingClose()
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.7)
        let output = gate.feed(chunkBatch(6), speechActive: true, chunkProbability: 0.95)
        #expect(tags(output) == [6])
        #expect(output.batches.allSatisfy { !$0.soft })
        // The next speech end opens a fresh trailing span, and its close a fresh window.
        let flip = gate.feed(chunkBatch(7), speechActive: false, chunkProbability: 0.2)
        #expect(flip.softTransition == .trailingOpened)
        for tag in 8...9 { _ = gate.feed(chunkBatch(Float(tag)), speechActive: false, chunkProbability: 0.1) }
        let closed = gate.feed(chunkBatch(10), speechActive: false, chunkProbability: 0.1).softTransition
        #expect(closed == .closed)
        let openedAfterActivation = gate.feed(chunkBatch(11), speechActive: false, chunkProbability: 0.7).softTransition
        #expect(openedAfterActivation == .opened)
    }

    @Test("end() flags what it releases as soft once the session has triggered")
    func endFlagsSoftAfterTrigger() {
        var gate = gateAfterTrailingClose()
        _ = gate.feed(chunkBatch(5), speechActive: false, chunkProbability: 0.2)
        _ = gate.feed(chunkBatch(6), speechActive: false, chunkProbability: 0.55)
        let released = gate.end()
        #expect(tags(released) == [5, 6])
        #expect(released.allSatisfy { $0.soft })
    }
}
