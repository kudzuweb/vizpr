import AVFoundation
import FluidAudio

enum FluidAudioASRError: Error {
    case bundledModelMissing(String)
    case offlineModeNotAsserted
}

/// Parakeet TDT v2 behind `TranscriptionEngine` (PLAN.md §5 + PR 4).
///
/// The model ships in the app bundle and loads via `AsrModels.load(from:)` — a
/// pure filesystem path. Belt and braces, `prepare()` refuses to run unless
/// FluidAudio's global offline switch is already engaged, so even a future
/// misuse of a downloading API would throw instead of reaching the network
/// (invariant 1: fail loudly if the offline guarantee cannot be confirmed).
///
/// Window config is the PR 0 locked constant (spikes/REPORT.md): 10 s windows,
/// 1 s hypothesis chunks, 2 s contexts, 0.80 confirmation. v2 requires an
/// explicit TdtConfig — its blank token id differs from the v3 default.
actor FluidAudioASR: TranscriptionEngine {

    /// PR 0 locked window config. Treated as a constant, not a tunable.
    /// tdtConfig is explicit because v2's blank token sits at 1024 (its vocab
    /// size); TdtConfig's default of 8192 is for v3 and silently mis-decodes v2.
    static let lockedConfig = SlidingWindowAsrConfig(
        chunkSeconds: 10.0,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 2.0,
        rightContextSeconds: 2.0,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.80,
        tdtConfig: TdtConfig(blankId: 1024)
    )

    private let modelsDirectory: URL
    /// Loaded CoreML models, reused across sessions (the expensive part: ~443 MB
    /// and seconds of load time). The SlidingWindowAsrManager itself is created
    /// fresh per transcribe() call: its input stream is built once at init and
    /// finish() terminates it permanently — reset() does NOT recreate it, so a
    /// reused manager silently ignores all audio after its first session
    /// (observed live: transcription worked exactly once per launch).
    private var models: AsrModels?

    /// - Parameter modelsDirectory: directory holding the v2 `.mlmodelc` set.
    ///   Defaults to the bundled copy at Resources/Models/parakeet-tdt-0.6b-v2.
    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory
            ?? Bundle.main.resourceURL!.appendingPathComponent("Models/parakeet-tdt-0.6b-v2")
    }

    func prepare() async throws {
        guard models == nil else { return }

        // The offline switch must be thrown before any FluidAudio model API is
        // touched (AppDelegate does it at launch); refusing to proceed without
        // it makes the no-download guarantee a checked precondition, not a hope.
        guard DownloadUtils.enforceOffline else {
            throw FluidAudioASRError.offlineModeNotAsserted
        }
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            throw FluidAudioASRError.bundledModelMissing(modelsDirectory.path)
        }

        // encoderPrecision only affects v3 file naming; v2 uses its fixed
        // Encoder.mlmodelc regardless, so the default is fine.
        models = try await AsrModels.load(
            from: modelsDirectory,
            version: .v2
        )
    }

    /// Build a single-session manager wired to the cached models. Cheap: the
    /// models are already loaded; this only constructs the windowing state.
    private func makeSessionManager() async throws -> SlidingWindowAsrManager? {
        guard let models else { return nil }
        let manager = SlidingWindowAsrManager(config: Self.lockedConfig)
        try await manager.loadModels(models)
        return manager
    }

    /// nonisolated: builds the event stream synchronously (satisfying the
    /// protocol's sync shape); all actor state is reached with await inside the
    /// stream's task.
    nonisolated func transcribe(_ audio: AsyncStream<[Float]>) -> AsyncStream<TokenEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let manager = try? await self.makeSessionManager() else {
                    continuation.finish()
                    return
                }
                do {
                    try await manager.startStreaming(source: .microphone)

                    // Forward engine updates as TokenEvents. windowID counts
                    // confirmations: every time text is confirmed, the volatile
                    // window has advanced, so subsequent drafts belong to a new
                    // window and must not replace the old one's finalized text.
                    let updatesTask = Task {
                        var windowID = 0
                        for await update in await manager.transcriptionUpdates {
                            if update.isConfirmed {
                                let tokenConfidences = update.tokenTimings.map(\.confidence)
                                continuation.yield(.finalized(
                                    text: update.text,
                                    confidence: update.confidence,
                                    tokenConfidences: tokenConfidences
                                ))
                                windowID += 1
                            } else {
                                continuation.yield(.draft(windowID: windowID, text: update.text))
                            }
                        }
                    }

                    // Pump session audio in. The manager resamples internally,
                    // but our pipeline already delivers 16 kHz mono Float32.
                    for await samples in audio {
                        try Task.checkCancellation()
                        if let buffer = Self.pcmBuffer(from: samples) {
                            await manager.streamAudio(buffer)
                        }
                    }

                    // Input ended (commit/cancel upstream): finish() flushes the
                    // remaining assembled audio, and that flush publishes the
                    // tail through transcriptionUpdates as confirmed updates —
                    // which the updates task above already forwards. Its return
                    // value is the WHOLE transcript, so emitting it as an event
                    // would duplicate everything already finalized (observed
                    // live: the full session text repeated in the last event).
                    _ = try await manager.finish()
                    updatesTask.cancel()
                } catch {
                    await manager.cancel()
                }
                // Session over: release the single-use manager's model wiring.
                // The loaded models stay cached on the actor for the next session.
                await manager.cleanup()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Wrap raw 16 kHz mono samples in the AVAudioPCMBuffer the manager expects.
    private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
