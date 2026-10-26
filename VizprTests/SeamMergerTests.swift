import Testing
@testable import Vizpr

/// Fixtures are real artifacts from the 2026-07-03 field logs.
@Suite("SeamMerger")
struct SeamMergerTests {

    private func merged(_ context: String, _ new: String) -> String {
        context + SeamMerger.appendix(context: context, new: new)
    }

    @Test("Plain continuation joins with a space")
    func plainJoin() {
        #expect(merged("I'm going to stop talking now and see if I", "Autostop catches it.")
                == "I'm going to stop talking now and see if I Autostop catches it.")
    }

    @Test("Field fixture: leading comma after a terminated context strips")
    func leadingCommaAfterTerminator() {
        #expect(merged("Let's see how this goes. Three margaritas.",
                       ", a lot of booze, especially how big the margarita can be.")
                == "Let's see how this goes. Three margaritas. "
                    + "a lot of booze, especially how big the margarita can be.")
    }

    @Test("Leading comma after an unterminated context glues")
    func leadingCommaGlues() {
        #expect(merged("Three margaritas", ", a lot of booze")
                == "Three margaritas, a lot of booze")
    }

    @Test("Field fixture: bare period after terminated context drops")
    func barePeriodDrops() {
        #expect(merged("Good work, Fable. I love it.", ".")
                == "Good work, Fable. I love it.")
    }

    @Test("Bare period after unterminated context glues")
    func barePeriodGlues() {
        #expect(merged("Good work, Fable. I love it", ".")
                == "Good work, Fable. I love it.")
    }

    @Test("Genuinely repeated words across finals are kept")
    func realRepeatPreserved() {
        // "I really / really mean it" and "that's final. Final answer." are
        // speech, not a re-decoded seam: windows no longer repeat each other.
        #expect(merged("I really", "really mean it.") == "I really really mean it.")
        #expect(merged("I want it done, and that's final.", "Final answer.")
                == "I want it done, and that's final. Final answer.")
        #expect(merged("one two three", "two three four") == "one two three two three four")
    }

    @Test("Empty and whitespace-only additions append nothing")
    func emptyDrops() {
        #expect(SeamMerger.appendix(context: "hello", new: "").isEmpty)
        #expect(SeamMerger.appendix(context: "hello", new: "   ").isEmpty)
    }

    @Test("Empty context takes the new text verbatim")
    func emptyContext() {
        #expect(SeamMerger.appendix(context: "", new: "Hello there.") == "Hello there.")
    }
}

/// Deterministic PRNG (shared pattern with the other property suites).
private struct SeamRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("SeamMerger invariants")
struct SeamMergerPropertyTests {

    private func words(_ text: String) -> [String] {
        text.split { $0 == " " }.map { String($0.filter(\.isLetter)) }.filter { !$0.isEmpty }
    }

    /// The seam merger must never invent or lose words. Property: for a random
    /// context and a random independent continuation, every word of both
    /// survives into the merged result, in order.
    @Test("Merging never loses or invents spoken words")
    func neverLosesNonOverlapWords() {
        let vocab = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "then"]
        for seed in UInt64(1)...500 {
            var rng = SeamRNG(seed: seed)
            let ctxCount = 1 + Int(rng.next() % 8)
            let incCount = 1 + Int(rng.next() % 8)
            let context = (0..<ctxCount).map { _ in vocab[Int(rng.next() % 10)] }.joined(separator: " ")
            let incoming = (0..<incCount).map { _ in vocab[Int(rng.next() % 10)] }.joined(separator: " ")

            let merged = context + SeamMerger.appendix(context: context, new: incoming)

            let mergedWords = words(merged)
            #expect(mergedWords == words(context) + words(incoming),
                    "merge changed the words (seed \(seed)): \(merged)")
        }
    }
}

@Suite("SentenceSplitter")
struct SentenceSplitterTests {

    @Test("Splits on terminators and rejoins losslessly")
    func losslessSplit() {
        let text = "One. Two! Three? Four"
        let parts = SentenceSplitter.split(text)
        #expect(parts.count == 4)
        #expect(parts.joined() == text)
    }

    @Test("Trailing whitespace stays attached to the closing sentence")
    func whitespaceAttachment() {
        let parts = SentenceSplitter.split("Hello there. General Kenobi. ")
        #expect(parts == ["Hello there. ", "General Kenobi. "])
    }

    @Test("Terminator inside a run of punctuation closes once")
    func punctuationRuns() {
        let parts = SentenceSplitter.split("Wait... what? Yes.")
        #expect(parts.joined() == "Wait... what? Yes.")
        #expect(parts.count == 3)
    }

    @Test("No terminator yields a single sentence")
    func singleSentence() {
        #expect(SentenceSplitter.split("no terminator here") == ["no terminator here"])
    }
}

/// Field regressions from the 2026-07-05 dogfood.
@Suite("SeamMerger echo")
struct SeamMergerEchoTests {
    @Test("A full context echo ahead of the rewrite is stripped")
    func contextEchoStripped() {
        let context = "It's not there. They're both just kind of slow. There's a few seconds before it starts showing."
        let output = context + " I still haven't seen the confirmed words."
        let stripped = SeamMerger.stripContextEcho(context: context, from: output)
        #expect(stripped == "I still haven't seen the confirmed words.",
                "got: \(stripped.debugDescription)")
    }

    @Test("Echo detection survives case/punctuation drift in the copy")
    func echoWithDrift() {
        let stripped = SeamMerger.stripContextEcho(
            context: "and one of them was too cold.",
            from: "And one of them was too cold and one of them was just right."
        )
        #expect(stripped == "and one of them was just right.",
                "got: \(stripped.debugDescription)")
    }

    @Test("Echo detection survives a dropped filler and a normalized contraction in the copy")
    func echoWithFillerAndContractionDrift() {
        // Cleanup removes fillers and may expand contractions when it copies
        // the context, so the alignment must not depend on either.
        let stripped = SeamMerger.stripContextEcho(
            context: "and I think that's gonna feel um different than before.",
            from: "And I think that's going to feel different than before. Then we moved on."
        )
        #expect(stripped == "Then we moved on.", "got: \(stripped.debugDescription)")
    }

    @Test("Output that is nothing but echo strips to empty")
    func echoOnly() {
        let context = "She saw some porridge and she was like oh snap food."
        #expect(SeamMerger.stripContextEcho(context: context, from: context).isEmpty)
    }

    @Test("A rewrite that merely opens with one repeated word is untouched")
    func shortRepeatNotEcho() {
        let stripped = SeamMerger.stripContextEcho(
            context: "that is final.",
            from: "Final answer, and more words."
        )
        #expect(stripped == "Final answer, and more words.")
    }
}
