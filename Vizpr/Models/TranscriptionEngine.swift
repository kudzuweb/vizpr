/// Token events flowing out of a transcription engine (PLAN.md §5 + §11).
///
/// Parakeet TDT is an offline encoder, so text inside the unconfirmed tail
/// legitimately *revises* as audio accumulates, and commits to final when the
/// engine closes a window over it (at a pause, or after 12 s of speech without
/// one). The event model mirrors that honestly:
///
/// - `.draft` — the unconfirmed tail's tentative text. A new draft with the
///   same `windowID` REPLACES the previous one (TokenStream's
///   draft-replaces-draft rule); a new `windowID` means a window closed and a
///   fresh draft began.
/// - `.finalized` — text the engine has committed. Never revised afterward,
///   and never repeating the words of an earlier final. Carries overall and
///   per-token confidence for the cleanup gate (§1).
enum TokenEvent: Sendable, Equatable {
    case draft(windowID: Int, text: String)
    case finalized(text: String, confidence: Float, tokenConfidences: [Float])
}

/// One element of a session's audio input. `.samples` is 16 kHz mono Float32
/// audio. `.pause` says the speaker has paused: every sample fed before it
/// belongs to a completed utterance, so the engine may close a window there.
/// It carries no position because the engine's own sample count when it
/// receives the mark is the position. An engine that does not window by
/// pauses ignores it.
enum AudioInput: Sendable {
    case samples([Float])
    case pause
}

/// Abstraction over streaming ASR (PLAN.md §11): an audio stream goes in,
/// `TokenEvent`s come out. The pipeline depends only on this seam; the default
/// conformer is `FluidAudioASR` (Parakeet TDT v2). Another model of a supported
/// runtime is drop-in via `ModelRegistry`; a new runtime means a new conformer.
protocol TranscriptionEngine: Sendable {
    /// Load models and become ready. Fails loudly if the model assets are
    /// missing or the offline guarantee cannot be asserted (invariant 1).
    func prepare() async throws

    /// Transcribe one dictation session: consume the audio stream (sample
    /// batches, with a `.pause` mark at each pause in the speech) and emit token events until the input ends. After the
    /// input ends the engine finalizes the unconfirmed tail with one more tail
    /// decode and emits no further drafts. Cancelling the surrounding task
    /// stops transcription promptly.
    func transcribe(_ audio: AsyncStream<AudioInput>) -> AsyncStream<TokenEvent>
}
