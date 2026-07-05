import Testing
@testable import Vizpr

/// A controllable fake CleanupEngine: records requests, returns a scripted
/// transform, and can gate completion so tests can observe cancellation.
private actor FakeCleanupEngine: CleanupEngine {
    private(set) var requests: [CleanupRequest] = []
    private let transform: @Sendable (String) -> String
    private let holdUntilCancelled: Bool
    private let delayNanos: UInt64

    init(
        holdUntilCancelled: Bool = false,
        delayNanos: UInt64 = 0,
        transform: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.transform = transform
        self.holdUntilCancelled = holdUntilCancelled
        self.delayNanos = delayNanos
    }

    func prepare() async throws {}

    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        requests.append(request)
        if holdUntilCancelled {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            throw CancellationError()
        }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        return CleanupResult(text: transform(request.text))
    }

    var requestCount: Int { requests.count }
    var lastRequest: CleanupRequest? { requests.last }
}

/// An engine whose clean() always throws — for the failed-disposition path.
private struct ExplodingCleanupEngine: CleanupEngine {
    struct Boom: Error {}
    func prepare() async throws {}
    func clean(_ request: CleanupRequest) async throws -> CleanupResult { throw Boom() }
}

/// An engine that copies the surrounding context into its rewrite — the
/// field-observed 4B failure mode (2026-07-05: a settled paragraph rendered
/// and committed twice).
private struct EchoingCleanupEngine: CleanupEngine {
    var echoOnly = false
    func prepare() async throws {}
    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        guard request.text.contains("helo wrld") else {
            return CleanupResult(text: request.text)
        }
        let echo = request.context.surroundingText ?? ""
        return CleanupResult(text: echoOnly ? echo : echo + " " + request.text.uppercased())
    }
}

/// Collects CleanupOutcomes delivered through SmartCleanup's onOutcome seam.
private actor OutcomeBox {
    private(set) var outcomes: [CleanupOutcome] = []
    func add(_ outcome: CleanupOutcome) { outcomes.append(outcome) }
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

    @Test("An applied cleanup reports .applied with the post-passed output")
    func outcomeApplied() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine { $0.uppercased() }
        let box = OutcomeBox()
        let smart = SmartCleanup(
            tokenStream: ts, engine: engine, onOutcome: { await box.add($0) }
        )
        await ts.beginSession()

        await smart.ingest(.finalized(text: "helo wrld", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()
        let outcomes = await box.outcomes
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.disposition == .applied)
        #expect(outcomes.first?.output == "HELO WRLD")
        #expect(outcomes.first?.input == "helo wrld")
    }

    @Test("A result arriving after the live region changed reports .stale")
    func outcomeStale() async {
        let ts = TokenStream()
        // Engine slow enough that a second finalized span lands (advancing the
        // generation) before the first cleanup's result comes back.
        let engine = FakeCleanupEngine(delayNanos: 60_000_000) { $0.uppercased() }
        let box = OutcomeBox()
        let smart = SmartCleanup(
            tokenStream: ts, engine: engine, onOutcome: { await box.add($0) }
        )
        await ts.beginSession()

        await smart.ingest(.finalized(text: "helo wrld", confidence: 0.4, tokenConfidences: [0.4]))
        try? await Task.sleep(nanoseconds: 20_000_000)   // cleanup in flight
        // High confidence, no terminator: advances the generation without
        // launching a second cleanup.
        await smart.ingest(.finalized(text: "more words", confidence: 0.99, tokenConfidences: [0.99]))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let outcomes = await box.outcomes
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.disposition == .stale)
    }

    @Test("A commit-cancelled cleanup reports .cancelled")
    func outcomeCancelled() async {
        let ts = TokenStream()
        let engine = FakeCleanupEngine(holdUntilCancelled: true)
        let box = OutcomeBox()
        let smart = SmartCleanup(
            tokenStream: ts, engine: engine, onOutcome: { await box.add($0) }
        )
        await ts.beginSession()

        await smart.ingest(.finalized(text: "pending text.", confidence: 0.4, tokenConfidences: [0.4]))
        try? await Task.sleep(nanoseconds: 20_000_000)   // cleanup starts and blocks
        _ = await ts.commit()
        await settle()

        let outcomes = await box.outcomes
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.disposition == .cancelled)
        #expect(outcomes.first?.output == nil)
    }

    @Test("An engine error reports .failed with the error — never silently")
    func outcomeFailed() async {
        let ts = TokenStream()
        let box = OutcomeBox()
        let smart = SmartCleanup(
            tokenStream: ts, engine: ExplodingCleanupEngine(), onOutcome: { await box.add($0) }
        )
        await ts.beginSession()

        await smart.ingest(.finalized(text: "will explode.", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()

        let outcomes = await box.outcomes
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.disposition == .failed)
        #expect(outcomes.first?.errorDescription?.isEmpty == false)
        // Fail-open: the raw span is still displayed.
        #expect(await ts.live == "will explode.")
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

@Suite("SmartCleanup context echo")
struct SmartCleanupEchoTests {
    /// Give async cleanup tasks a beat to run to completion.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    @Test("An echoed settled context never duplicates on the display")
    func echoStrippedBeforeApply() async {
        let ts = TokenStream()
        let smart = SmartCleanup(tokenStream: ts, engine: EchoingCleanupEngine())
        await ts.beginSession()
        await smart.ingest(.finalized(text: "First sentence.", confidence: 0.99, tokenConfidences: [0.99]))
        await smart.ingest(.finalized(text: "Second sentence.", confidence: 0.99, tokenConfidences: [0.99]))
        await settle()
        await smart.ingest(.finalized(text: "helo wrld", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()

        let displayed = await ts.currentSnapshot().displayed
        let firsts = displayed.lowercased().components(separatedBy: "first sentence").count - 1
        #expect(firsts <= 1, "settled context echoed into the display: \(displayed)")
    }

    @Test("Echo-only output fails open: live text survives")
    func echoOnlyFailsOpen() async {
        let ts = TokenStream()
        let box = OutcomeBox()
        let smart = SmartCleanup(
            tokenStream: ts, engine: EchoingCleanupEngine(echoOnly: true),
            onOutcome: { await box.add($0) }
        )
        await ts.beginSession()
        await smart.ingest(.finalized(text: "First sentence.", confidence: 0.99, tokenConfidences: [0.99]))
        await smart.ingest(.finalized(text: "Second sentence.", confidence: 0.99, tokenConfidences: [0.99]))
        await settle()
        await smart.ingest(.finalized(text: "helo wrld", confidence: 0.4, tokenConfidences: [0.4]))
        await settle()

        let displayed = await ts.currentSnapshot().displayed
        #expect(displayed.contains("helo wrld"), "live text erased by echo-only output: \(displayed)")
        let failed = await box.outcomes.contains { $0.disposition == .failed }
        #expect(failed, "echo-only output not reported as failed")
    }
}
