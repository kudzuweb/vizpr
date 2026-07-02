import CoreML
import FluidAudio

/// Thin wrapper over FluidAudio's `VadManager` (Silero VAD) — PLAN.md §5: VAD's
/// role is narrow (chunking, silence trimming, latched auto-stop input). It
/// never decides commits; the key does.
///
/// The model is loaded from the app bundle via the `vadModel:` initializer,
/// which has **no download path at all** — stronger than relying on the offline
/// flag (invariant 1). Chunk-boundary math lives in the pure `AudioChunker`.
actor SpeechDetector {
    /// One VAD inference result attached to the chunk that produced it.
    struct Update: Sendable {
        let chunk: [Float]
        let event: VadStreamEvent?
        /// Hysteresis speech state after this chunk — drives the silence watchdog.
        let speechActive: Bool
    }

    static let chunkSize = VadManager.chunkSize   // 4096 samples = 256 ms @ 16 kHz

    private let vad: VadManager
    private let segmentation: VadSegmentationConfig
    private var chunker = AudioChunker(chunkSize: SpeechDetector.chunkSize)
    private var streamState: VadStreamState?

    /// `sending`: MLModel is not Sendable; ownership transfers into the actor
    /// (callers pass a freshly loaded model and keep no reference).
    init(model: sending MLModel, segmentation: VadSegmentationConfig = .default) {
        self.vad = VadManager(config: .default, vadModel: model)
        self.segmentation = segmentation
    }

    /// Load the Silero VAD model shipped in the app bundle. Fails loudly if the
    /// bundle is malformed — a build problem, not a runtime condition.
    static func loadBundledModel() throws -> MLModel {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Models/silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try MLModel(contentsOf: url)
    }

    /// Feed captured samples; returns one `Update` per completed 256 ms chunk
    /// (possibly none, possibly several if the consumer lagged).
    func process(_ samples: [Float]) async throws -> [Update] {
        var current: VadStreamState
        if let existing = streamState {
            current = existing
        } else {
            current = await vad.makeStreamState()
        }
        var updates: [Update] = []
        for chunk in chunker.append(samples) {
            let result = try await vad.processStreamingChunk(
                chunk, state: current, config: segmentation, returnSeconds: true
            )
            current = result.state
            updates.append(Update(
                chunk: chunk,
                event: result.event,
                speechActive: result.state.triggered
            ))
        }
        streamState = current
        return updates
    }

    /// Forget stream state between dictation sessions.
    func reset() {
        chunker.reset()
        streamState = nil
    }
}
