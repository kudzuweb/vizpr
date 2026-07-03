/// Orchestrates the cleanup leg of the pipeline (PLAN.md §1, §6): the single
/// entry point for ASR token events into the display path. It runs the vocab
/// pre-pass, forwards events to the `TokenStream`, and — confidence-gated —
/// launches cleanup invocations whose generation-tagged results are applied
/// back to the live region (post-pass authoritative).
///
/// Cleanup is invoked only on low-confidence spans and at sentence boundaries;
/// fully high-confidence mid-sentence text skips the LLM entirely. Invocations
/// are launched through `TokenStream.launchCleanup`, so a commit cancels every
/// in-flight cleanup structurally (strict cancel).
actor SmartCleanup {
    private let tokenStream: TokenStream
    private let engine: any CleanupEngine
    private let vocabulary: Vocabulary
    /// Finalized-span confidence at/above which the text is trusted and cleanup
    /// is skipped unless a sentence just closed.
    private let confidenceThreshold: Float
    private let codeMode: Bool

    init(
        tokenStream: TokenStream,
        engine: any CleanupEngine,
        vocabulary: Vocabulary = .empty,
        confidenceThreshold: Float = 0.85,
        codeMode: Bool = false
    ) {
        self.tokenStream = tokenStream
        self.engine = engine
        self.vocabulary = vocabulary
        self.confidenceThreshold = confidenceThreshold
        self.codeMode = codeMode
    }

    /// Feed one ASR event. Applies the vocab pre-pass, forwards to the token
    /// stream, and gates a cleanup invocation on finalized events.
    func ingest(_ event: TokenEvent) async {
        switch event {
        case let .draft(windowID, text):
            // Pre-pass normalizes both legs' display (§4): drafts too.
            await tokenStream.apply(.draft(windowID: windowID, text: vocabulary.apply(to: text)))

        case let .finalized(text, confidence, tokenConfidences):
            let normalized = vocabulary.apply(to: text)
            await tokenStream.apply(.finalized(
                text: normalized, confidence: confidence, tokenConfidences: tokenConfidences
            ))
            if shouldClean(text: normalized, confidence: confidence, tokens: tokenConfidences) {
                await launchCleanup()
            }
        }
    }

    // MARK: Gating

    /// Confidence gate (§1): clean when the span is low-confidence OR a sentence
    /// just closed (sentence boundaries are where punctuation/segmentation edits
    /// matter most). Skip fully high-confidence mid-sentence text.
    private func shouldClean(text: String, confidence: Float, tokens: [Float]) -> Bool {
        if confidence < confidenceThreshold { return true }
        if let minToken = tokens.min(), minToken < confidenceThreshold { return true }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, last == "." || last == "!" || last == "?" { return true }
        return false
    }

    // MARK: Invocation

    private func launchCleanup() async {
        // Snapshot the live region and its generation together, so the result
        // is applied only if nothing has changed since (stale results dropped).
        let input = await tokenStream.cleanupInput()
        guard !input.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let context = CleanupContext(
            surroundingText: input.settledContext.isEmpty ? nil : input.settledContext,
            bundleID: nil,
            codeMode: codeMode,
            vocabularyHint: vocabulary.promptHint()
        )
        let request = CleanupRequest(text: input.text, context: context)

        // Launched through the stream so commit()/cancel() cancels it.
        await tokenStream.launchCleanup { [engine, vocabulary, tokenStream] in
            guard let result = try? await engine.clean(request) else { return }
            // POST-PASS is authoritative: re-fix any canonical form the model
            // un-fixed (§4, post wins ties). Then apply, generation-gated.
            let cleaned = vocabulary.apply(to: result.text)
            await tokenStream.applyCleanup(
                expectedGeneration: input.generation, rewrittenLive: cleaned
            )
        }
    }
}
