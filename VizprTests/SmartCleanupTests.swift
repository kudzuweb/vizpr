import Testing
@testable import Vizpr

/// A controllable fake CleanupEngine: records requests, returns a scripted
/// transform, and can gate completion so tests can observe cancellation.
private actor FakeCleanupEngine: CleanupEngine {
    private(set) var requests: [CleanupRequest] = []
    private let transform: @Sendable (String) -> String
    private let holdUntilCancelled: Bool

    init(holdUntilCancelled: Bool = false, transform: @escaping @Sendable (String) -> String = { $0 }) {
        self.transform = transform
        self.holdUntilCancelled = holdUntilCancelled
    }

    func prepare() async throws {}

    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        requests.append(request)
        if holdUntilCancelled {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        }
        return CleanupResult(text: transform(request.text))
    }

    var requestCount: Int { requests.count }
    var lastRequest: CleanupRequest? { requests.last }
}

@Suite("SmartCleanup")
struct SmartCleanupTests {

    private func vocab(_ pairs: [(String, String)]) -> Vocabulary {
        Vocabulary(entries: pairs.map { VocabularyEntry(pattern: $0.0, replacement: $0.1, kind: .canonical) })
    }

    /// Give async cleanup tasks a beat to run to completion.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    @Test("Vocab pre-pass normalizes text before it reaches the display")
    func prePassApplied() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine()
        let smart = SmartCleanup(tokenStream: ts, engine: engine, vocabulary: vocab([("github", "GitHub")]))
        await ts.beginSession()

        await smart.ingest(.finalized(text: "push to github", confidence: 0.99, tokenConfidences: [0.99]))
        #expect(await ts.live == "push to GitHub")
    }

    @Test("High-confidence mid-sentence text skips the LLM")
    func highConfidenceSkips() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine()
        let smart = SmartCleanup(tokenStream: ts, engine: engine)
        await ts.beginSession()

        await smart.ingest(.finalized(text: "no terminator here", confidence: 0.99, tokenConfidences: [0.99]))
        await settle()
        #expect(await engine.requestCount == 0)
    }

    @Test("Low-confidence span triggers cleanup")
    func lowConfidenceTriggers() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine { $0.uppercased() }
        let smart = SmartCleanup(tokenStream: ts, engine: engine)
        await ts.beginSession()

        await smart.ingest(.finalized(text: "helo wrld", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()
        #expect(await engine.requestCount == 1)
        #expect(await ts.live == "HELO WRLD")
    }

    @Test("A closed sentence triggers cleanup even at high confidence")
    func sentenceBoundaryTriggers() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine { $0 + " [cleaned]" }
        let smart = SmartCleanup(tokenStream: ts, engine: engine)
        await ts.beginSession()

        await smart.ingest(.finalized(text: "This is done.", confidence: 0.99, tokenConfidences: [0.99]))
        await settle()
        #expect(await engine.requestCount == 1)
    }

    @Test("A low per-token confidence triggers cleanup even if the span average is high")
    func perTokenConfidenceTriggers() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine()
        let smart = SmartCleanup(tokenStream: ts, engine: engine)
        await ts.beginSession()

        await smart.ingest(.finalized(text: "one shaky word", confidence: 0.95, tokenConfidences: [0.99, 0.3, 0.99]))
        await settle()
        #expect(await engine.requestCount == 1)
    }

    @Test("Post-pass beats the model: a re-un-fixed canonical is re-fixed")
    func postPassAuthoritative() async {
        let ts = TokenStream()
        // The model lowercases GitHub back; the post-pass must restore it.
        let engine = FakeCleanupEngine { $0.replacingOccurrences(of: "GitHub", with: "github") }
        let smart = SmartCleanup(tokenStream: ts, engine: engine, vocabulary: vocab([("github", "GitHub")]))
        await ts.beginSession()

        await smart.ingest(.finalized(text: "ship to github now.", confidence: 0.5, tokenConfidences: [0.5]))
        await settle()
        #expect(await ts.live == "ship to GitHub now.")
    }

    @Test("Cleanup passes settled context and the vocab hint to the engine")
    func contextForwarded() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine()
        let smart = SmartCleanup(tokenStream: ts, engine: engine, vocabulary: vocab([("api", "API")]))
        await ts.beginSession()
        // Build several settled sentences so there's a settled context tail.
        await smart.ingest(.finalized(text: "First sentence.", confidence: 0.5, tokenConfidences: [0.5]))
        await smart.ingest(.finalized(text: "Second sentence.", confidence: 0.5, tokenConfidences: [0.5]))
        await smart.ingest(.finalized(text: "Third low span.", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()

        let request = await engine.lastRequest
        #expect(request?.context.vocabularyHint == "API")
        #expect(request?.context.surroundingText?.isEmpty == false)
    }

    @Test("Commit cancels an in-flight cleanup and its late result never applies")
    func commitCancelsInFlight() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine(holdUntilCancelled: true)
        let smart = SmartCleanup(tokenStream: ts, engine: engine)
        await ts.beginSession()

        await smart.ingest(.finalized(text: "text pending cleanup.", confidence: 0.4, tokenConfidences: [0.4]))
        try? await Task.sleep(nanoseconds: 20_000_000)   // let the cleanup start and block
        let committed = await ts.commit()
        #expect(committed == "text pending cleanup.")
        await settle()
        // Session sealed; nothing the cancelled cleanup could do applies.
        #expect(await ts.currentSnapshot() == .empty)
    }
}
