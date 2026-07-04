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

    @Test("Field fixture: word overlap at the seam is trimmed")
    func overlapTrimmed() {
        #expect(merged("We don't say accidental discharge. We say negligent discharge",
                       "negligent discharge for a reason.")
                == "We don't say accidental discharge. We say negligent discharge for a reason.")
    }

    @Test("Overlap comparison ignores case and punctuation")
    func overlapNormalized() {
        #expect(merged("I think this is going to translate into a good UI.",
                       "a good ui. Nice.")
                == "I think this is going to translate into a good UI. Nice.")
    }

    @Test("Genuinely repeated emphasis words are NOT deleted")
    func realRepeatPreserved() {
        // Review finding: a user saying "…that's final. Final answer." must keep
        // the second "Final" — the surface forms differ ("final." vs "Final"),
        // so a 1-word match is not trimmed.
        #expect(merged("I want it done, and that's final.", "Final answer.")
                == "I want it done, and that's final. Final answer.")
    }

    @Test("Single-word overlap trims only on exact (case+punct) raw match")
    func singleWordExactOnly() {
        // Exact raw repeat = seam artifact → trim.
        #expect(merged("go to the store", "store now")
                == "go to the store now")
        // Differing surface form = real speech → keep.
        #expect(merged("go to the Store", "store now")
                == "go to the Store store now")
    }

    @Test("Internal whitespace of retained speech is preserved")
    func whitespaceFidelity() {
        // The retained portion after the trimmed overlap word keeps its internal
        // spacing byte-faithfully (slicing the original string, not rejoining
        // split words). The seam separator itself normalizes to one space.
        #expect(merged("one two three", "three  four   five")
                == "one two three four   five")
    }

    @Test("Fully duplicated text appends nothing")
    func fullDuplicateDrops() {
        let context = "one two three"
        #expect(SeamMerger.appendix(context: context, new: "two three").isEmpty)
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

    /// The seam merger may drop text ONLY at a genuine overlap; it must never
    /// invent or lose words otherwise. Property: for a random context and a
    /// random independent continuation, every non-overlap word of the incoming
    /// text survives into the merged result.
    @Test("Merging never loses non-overlapping spoken words")
    func neverLosesNonOverlapWords() {
        let vocab = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "then"]
        for seed in UInt64(1)...500 {
            var rng = SeamRNG(seed: seed)
            let ctxCount = 1 + Int(rng.next() % 8)
            let incCount = 1 + Int(rng.next() % 8)
            let context = (0..<ctxCount).map { _ in vocab[Int(rng.next() % 10)] }.joined(separator: " ")
            let incoming = (0..<incCount).map { _ in vocab[Int(rng.next() % 10)] }.joined(separator: " ")

            let merged = context + SeamMerger.appendix(context: context, new: incoming)

            // Any incoming word beyond the trimmed prefix must appear in merged.
            // Conservatively: the merged word-count is at least the context's,
            // and merged ends with a suffix of the incoming words.
            let mergedWords = words(merged)
            let contextWords = words(context)
            let incomingWords = words(incoming)
            #expect(mergedWords.count >= contextWords.count,
                    "merge lost context words (seed \(seed)): \(merged)")
            #expect(mergedWords.count <= contextWords.count + incomingWords.count,
                    "merge invented words (seed \(seed)): \(merged)")
            // The tail of merged equals a suffix of incoming (overlap only trims
            // a prefix of incoming, never reorders or drops from its tail).
            let tail = Array(mergedWords.suffix(incomingWords.count))
            #expect(incomingWords.suffix(tail.count).map { $0.lowercased() } == tail.map { $0.lowercased() },
                    "merge reordered/dropped incoming tail (seed \(seed)): \(merged)")
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

/// Field regressions from the 2026-07-04 PR 9 dogfood: windowed finals
/// re-covering the previous window's tail with a filler or punctuation
/// variation rendered the words twice.
@Suite("SeamMerger filler-tolerant overlap")
struct SeamMergerFillerTests {
    @Test("A filler inside the overlap does not break the match")
    func fillerInOverlap() {
        let merged = SeamMerger.appendix(
            context: "Sorry about that. Otherwise, we're",
            new: "Otherwise, uh we're coming along here"
        )
        #expect(merged == " coming along here", "got: \(merged.debugDescription)")
    }

    @Test("Trailing punctuation on the context side still matches one word")
    func punctuationSingleWord() {
        let merged = SeamMerger.appendix(
            context: "I do like the confirmation.",
            new: "confirmation lag whatever thing"
        )
        #expect(merged == " lag whatever thing", "got: \(merged.debugDescription)")
    }

    @Test("Real repeated speech with different casing is preserved")
    func emphasisRepeatPreserved() {
        let merged = SeamMerger.appendix(context: "that's final.", new: "Final answer.")
        #expect(merged.contains("Final answer"), "emphasis repeat was eaten: \(merged.debugDescription)")
    }
}
