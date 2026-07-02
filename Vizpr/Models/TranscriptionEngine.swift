/// Token events flowing out of a transcription engine (PLAN.md §5 + §11).
///
/// FluidAudio runs Parakeet TDT as an offline encoder over overlapping sliding
/// windows: text inside the active window legitimately *revises* as audio
/// accumulates, and commits to final when a window advances past it. The event
/// model mirrors that honestly:
///
/// - `.draft` — the active window's tentative text. A new draft with the same
///   `windowID` REPLACES the previous one (TokenStream's draft-replaces-draft
///   rule); a new `windowID` means the window advanced and a fresh draft began.
/// - `.finalized` — text the engine has committed. Never revised afterward.
///   Carries overall and per-token confidence for the cleanup gate (§1).
enum TokenEvent: Sendable, Equatable {
    case draft(windowID: Int, text: String)
    case finalized(text: String, confidence: Float, tokenConfidences: [Float])
}

/// Abstraction over streaming ASR (PLAN.md §11): an audio-chunk stream goes in,
/// `TokenEvent`s come out. The pipeline depends only on this seam; the default
/// conformer is `FluidAudioASR` (Parakeet TDT v2). Another model of a supported
/// runtime is drop-in via `ModelRegistry`; a new runtime means a new conformer.
protocol TranscriptionEngine: Sendable {
    /// Load models and become ready. Fails loudly if the model assets are
    /// missing or the offline guarantee cannot be asserted (invariant 1).
    func prepare() async throws

    /// Transcribe one dictation session: consume the audio stream (16 kHz mono
    /// Float32 batches) and emit token events until the input ends, then finish
    /// with the engine's final flush. Cancelling the surrounding task stops
    /// transcription promptly.
    func transcribe(_ audio: AsyncStream<[Float]>) -> AsyncStream<TokenEvent>
}
