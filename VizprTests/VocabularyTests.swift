import Foundation
import Testing
@testable import Vizpr

@Suite("Vocabulary")
struct VocabularyTests {

    private func entry(
        _ pattern: String, _ replacement: String, _ kind: VocabularyEntry.Kind = .canonical
    ) -> VocabularyEntry {
        VocabularyEntry(pattern: pattern, replacement: replacement, kind: kind)
    }
    private func vocab(_ entries: [VocabularyEntry]) -> Vocabulary { Vocabulary(entries: entries) }

    @Test("Canonical form normalizes case-insensitively")
    func canonicalForm() {
        let vocab = vocab([entry("kubernetes", "Kubernetes", .canonical), entry("github", "GitHub", .canonical)])
        #expect(vocab.apply(to: "deploy to kubernetes via github")
                == "deploy to Kubernetes via GitHub")
        #expect(vocab.apply(to: "KUBERNETES and GitHub") == "Kubernetes and GitHub")
    }

    @Test("Sounds-like maps a multi-word mishearing to a term")
    func soundsLike() {
        let vocab = vocab([entry("pie dantic", "Pydantic", .soundsLike), entry("aye pee eye", "API", .soundsLike)])
        #expect(vocab.apply(to: "use pie dantic for the aye pee eye")
                == "use Pydantic for the API")
    }

    @Test("Longest phrase wins over a shorter overlapping pattern")
    func longestFirst() {
        let vocab = vocab([entry("pie", "Pie", .canonical), entry("pie dantic", "Pydantic", .soundsLike)])
        #expect(vocab.apply(to: "pie dantic model") == "Pydantic model")
        #expect(vocab.apply(to: "a pie chart") == "a Pie chart")
    }

    @Test("Surrounding punctuation and spacing are preserved exactly")
    func preservesFormatting() {
        let vocab = vocab([entry("github", "GitHub", .canonical)])
        #expect(vocab.apply(to: "  (github),  done.") == "  (GitHub),  done.")
        #expect(vocab.apply(to: "github") == "GitHub")
    }

    @Test("Word-boundary aware: substrings inside words are not matched")
    func wordBoundary() {
        let vocab = vocab([entry("cat", "CAT", .canonical)])
        #expect(vocab.apply(to: "the cat concatenates") == "the CAT concatenates")
    }

    @Test("Post-pass beats the model: re-fixes an un-fixed canonical")
    func postPassAuthoritative() {
        let vocab = vocab([entry("kubernetes", "Kubernetes", .canonical)])
        // The model 'corrected' Kubernetes back to lowercase; post-pass re-fixes.
        #expect(vocab.apply(to: "scale kubernetes now") == "scale Kubernetes now")
    }

    @Test("Empty vocabulary is a no-op")
    func emptyIsNoop() {
        #expect(Vocabulary.empty.apply(to: "unchanged text.") == "unchanged text.")
    }

    @Test("Idempotent: applying twice equals applying once")
    func idempotent() {
        let vocab = vocab([entry("github", "GitHub", .canonical), entry("pie dantic", "Pydantic", .soundsLike)])
        let once = vocab.apply(to: "github and pie dantic")
        #expect(vocab.apply(to: once) == once)
    }

    @Test("Prompt hint lists the terms, de-duplicated")
    func promptHint() {
        let vocab = vocab([
            entry("kubernetes", "Kubernetes", .canonical),
            entry("k8s", "Kubernetes", .soundsLike),
            entry("github", "GitHub", .canonical)
        ])
        #expect(vocab.promptHint() == "Kubernetes, GitHub")
    }

    @Test("Tokenizer round-trips arbitrary text losslessly when no entries match")
    func losslessTokenize() {
        let vocab = vocab([entry("zzz", "ZZZ", .canonical)])
        let samples = ["", "   ", "hello, world!", "tabs\tand\nnewlines", "a.b.c", "café résumé 42"]
        for sample in samples {
            #expect(vocab.apply(to: sample) == sample, "not lossless: \(sample.debugDescription)")
        }
    }
}

@Suite("VocabularyStore")
struct VocabularyStoreTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vizpr-vocab-\(UUID().uuidString)/vocabulary.json")
    }

    @Test("Missing file loads as empty, not an error")
    func missingFileEmpty() throws {
        let store = VocabularyStore(url: tempURL())
        #expect(try store.load().entries.isEmpty)
    }

    @Test("Save then load round-trips entries")
    func roundTrip() throws {
        let store = VocabularyStore(url: tempURL())
        let vocab = Vocabulary(entries: [
            VocabularyEntry(pattern: "github", replacement: "GitHub", kind: .canonical),
            VocabularyEntry(pattern: "pie dantic", replacement: "Pydantic", kind: .soundsLike)
        ])
        try store.save(vocab)
        #expect(try store.load() == vocab)
    }

    @Test("Malformed JSON throws rather than losing terms silently")
    func malformedThrows() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{ not an array".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try VocabularyStore(url: url).load() }
    }
}
