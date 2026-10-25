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
    private var vocabulary: Vocabulary
    /// Finalized-span confidence at/above which the text is trusted and cleanup
    /// is skipped unless a sentence just closed.
    private let confidenceThreshold: Float
    private let codeMode: Bool
    /// Observation seam for per-invocation outcomes (§14): every launched
    /// cleanup reports exactly one CleanupOutcome here — applied, stale,
    /// cancelled, or failed. The dev logger consumes it in Debug; unset, the
    /// outcome is dropped (Release behavior: cleanup failure fails open, the
    /// span stays raw).
    private let onOutcome: (@Sendable (CleanupOutcome) async -> Void)?
    /// Per-session field context (PR 10): AX surrounding text and bundle id
    /// captured at session start; code mode derived from the bundle id.
    private var sessionField: FieldContext = .empty
    private var sessionCodeMode = false
    private var sessionStyleRules: String?
    /// Live settings (PR 11).
    private var enabled = true
    private var codeModeOverride = false

    init(
        tokenStream: TokenStream,
        engine: any CleanupEngine,
        vocabulary: Vocabulary = .empty,
        confidenceThreshold: Float = 0.85,
        codeMode: Bool = false,
        onOutcome: (@Sendable (CleanupOutcome) async -> Void)? = nil
    ) {
        self.tokenStream = tokenStream
        self.engine = engine
        self.vocabulary = vocabulary
        self.confidenceThreshold = confidenceThreshold
        self.codeMode = codeMode
        self.onOutcome = onOutcome
    }

    /// Warm the underlying engine (model load) ahead of the first invocation.
    func prepareEngine() async throws {
        try await engine.prepare()
    }

    /// Adopt the focused field's context for this session (PR 10). A session
    /// begun without this (or with .empty) is fully functional — cleanup just
    /// runs context-less (acceptance).
    func beginSession(
        field: FieldContext, vocabulary: Vocabulary? = nil, styleRules: String? = nil
    ) {
        // PR 11: the resolved per-context vocabulary (global + assigned
        // bucket) and its style rules ride in with the session.
        if let vocabulary { self.vocabulary = vocabulary }
        sessionStyleRules = styleRules
        sessionField = field
        sessionCodeMode = codeMode || codeModeOverride
            || CodeDetector.isCodeSurface(bundleID: field.bundleID)
    }

    /// Live settings (PR 11): cleanup can be disabled entirely (§14 toggle;
    /// the disabled path still runs the vocab pre-pass — display/injection
    /// keep working, just uncleaned), and code mode can be forced on.
    func setRuntime(enabled: Bool, codeModeOverride: Bool) {
        self.enabled = enabled
        self.codeModeOverride = codeModeOverride
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
            if enabled, shouldClean(text: normalized, confidence: confidence, tokens: tokenConfidences) {
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

        // Surrounding text = the focused field's vicinity (AX, PR 10) plus
        // the settled tail of this dictation — both are what precedes the
        // span being cleaned.
        let surrounding = [
            sessionField.surroundingText,
            input.settledContext.isEmpty ? nil : input.settledContext,
        ].compactMap { $0 }.joined(separator: "\n")
        let context = CleanupContext(
            surroundingText: surrounding.isEmpty ? nil : surrounding,
            bundleID: sessionField.bundleID,
            codeMode: sessionCodeMode,
            vocabularyHint: vocabulary.promptHint(),
            styleRules: sessionStyleRules
        )
        let request = CleanupRequest(text: input.text, context: context)

        // Launched through the stream so commit()/cancel() cancels it. Every
        // path reports its disposition through onOutcome — cleanup failures
        // are fail-open for the display (span stays raw) but never silent.
        await tokenStream.launchCleanup { [engine, vocabulary, tokenStream, onOutcome] in
            #if DICT_DEV_LOG
            let started = ContinuousClock.now
            #endif
            func elapsedMs() -> Int? {
                #if DICT_DEV_LOG
                let parts = (ContinuousClock.now - started).components
                return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
                #else
                return nil
                #endif
            }
            do {
                let result = try await engine.clean(request)
                // POST-PASS is authoritative: re-fix any canonical form the
                // model un-fixed (§4, post wins ties). Then strip any echo of
                // the settled context the model copied into its rewrite
                // (field catch: an echoed context duplicated a settled
                // paragraph on screen AND in the commit). Then apply,
                // generation-gated: a stale result drops.
                let cleaned = SeamMerger.stripContextEcho(
                    context: input.settledContext,
                    from: vocabulary.apply(to: result.text)
                )
                // Output that was NOTHING BUT echo strips to empty — applying
                // it would erase the user's live text. Fail open instead.
                guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else {
                    await onOutcome?(CleanupOutcome(
                        input: request.text, output: nil,
                        generation: input.generation, disposition: .failed,
                        errorDescription: "output was context echo only",
                        durationMs: elapsedMs()
                    ))
                    return
                }
                let applied = await tokenStream.applyCleanup(
                    expectedGeneration: input.generation, rewrittenLive: cleaned
                )
                await onOutcome?(CleanupOutcome(
                    input: request.text, output: cleaned,
                    generation: input.generation,
                    disposition: applied ? .applied : .stale,
                    durationMs: elapsedMs()
                ))
            } catch is CancellationError {
                await onOutcome?(CleanupOutcome(
                    input: request.text, output: nil,
                    generation: input.generation, disposition: .cancelled,
                    durationMs: elapsedMs()
                ))
            } catch {
                await onOutcome?(CleanupOutcome(
                    input: request.text, output: nil,
                    generation: input.generation, disposition: .failed,
                    errorDescription: String(describing: error),
                    durationMs: elapsedMs()
                ))
            }
        }
    }
}

/// The outcome of one cleanup invocation, reported through SmartCleanup's
/// `onOutcome` seam (§14 per-invocation records). `failed` extends the plan's
/// applied|stale|cancelled set: surfacing engine errors (instead of the try?
/// that used to swallow them) is the reason the seam exists.
struct CleanupOutcome: Sendable, Equatable {
    enum Disposition: String, Sendable {
        case applied, stale, cancelled, failed
    }

    let input: String
    let output: String?
    let generation: Int
    let disposition: Disposition
    var errorDescription: String?
    /// Wall time of the invocation; measured in dev-log builds only.
    var durationMs: Int?
}
