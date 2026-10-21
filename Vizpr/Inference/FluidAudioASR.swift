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

    // MARK: Draft track (PR 4.5)
    //
    // The sliding-window manager's advertised 1s hypothesis updates are dead
    // config in the pinned revision — nothing consumes hypothesisChunkSeconds,
    // so its first output arrives only after chunk+rightContext (~12s of audio;
    // field-measured). The draft track fills the gap: a second, stateless batch
    // decode over the unconfirmed tail, published as .draft events. Decoding runs
    // in its own task, decoupled from audio ingestion, and refreshes as fast as
    // the decoder sustains (floor: DraftTailTracker.cadenceFloorSamples).
    // One session at a time (enforced by AudioPipeline); this state is reset in
    // beginSession().
    private var batchManager: AsrManager?
    private var tailTracker = DraftTailTracker()
    private var sessionBuffer: [Float] = []
    private var bufferStartSample = 0
    private var confirmedWindows = 0
    private var lastDraftText = ""
    /// True while tail drafts may be published. Closed (under actor
    /// serialization) before the end-of-session flush, so no tail draft can be
    /// yielded after the flush's finals.
    private var draftsOpen = false

    /// Audio covered by one confirmed window (locked config: 10 s @ 16 kHz).
    /// Confirmations don't carry reliable session-absolute sample positions, so
    /// the boundary advances by one window per confirmation — exact for the
    /// steady state, approximate only during the end-of-session flush, where
    /// drafts no longer matter.
    private static let samplesPerConfirmedWindow = Int(lockedConfig.chunkSeconds * 16_000)

    /// Live setting (PR 11): min audio before the first draft decode —
    /// Mauria's "first draft faster?" lever. Applies from the next session.
    private var draftMinTailSamples = 24_000

    func setDraftMinTail(milliseconds: Int) {
        draftMinTailSamples = max(1, milliseconds) * 16   // 16 kHz
    }

    private func beginSession() {
        tailTracker = DraftTailTracker(minTailSamples: draftMinTailSamples)
        sessionBuffer.removeAll(keepingCapacity: true)
        bufferStartSample = 0
        confirmedWindows = 0
        lastDraftText = ""
        draftsOpen = true
    }

    private func closeDrafts() {
        draftsOpen = false
    }

    /// A draft decode the draft task should run now.
    private struct DraftPlan {
        let samples: [Float]
        let windowID: Int
    }

    /// Ingest session audio. Buffer bookkeeping only; never decodes.
    private func ingest(_ samples: [Float]) {
        sessionBuffer.append(contentsOf: samples)
        tailTracker.append(sampleCount: samples.count)
        trimBuffer()
    }

    /// A decode plan if a draft pass is due, or nil. The slice is copied here,
    /// inside the actor call, so later trims cannot invalidate it.
    private func takeDraftPlan() -> DraftPlan? {
        guard let request = tailTracker.takeDecodeRequest() else { return nil }
        // Decode from the unconfirmed boundary (not the left-context start):
        // including confirmed audio would re-transcribe already-final text into
        // the draft. The cost is slightly weaker acoustics on the first word
        // after a confirmation — acceptable for display-only drafts.
        let start = max(request.draftStart, request.range.lowerBound) - bufferStartSample
        let end = request.range.upperBound - bufferStartSample
        guard start >= 0, end <= sessionBuffer.count, start < end else { return nil }
        let slice = Array(sessionBuffer[start ..< end])
        trimBuffer()
        return DraftPlan(samples: slice, windowID: confirmedWindows)
    }

    /// Publish a tail draft unless drafts are closed or the text repeats the
    /// last one. Yields inside the actor so that `closeDrafts()` strictly
    /// orders against it.
    private func emitTailDraft(
        _ text: String, windowID: Int, to continuation: AsyncStream<TokenEvent>.Continuation
    ) {
        guard draftsOpen, shouldEmitDraft(text) else { return }
        continuation.yield(.draft(windowID: windowID, text: text))
    }

    private func trimBuffer() {
        let reclaimable = tailTracker.reclaimableSamples - bufferStartSample
        if reclaimable > 0, reclaimable <= sessionBuffer.count {
            sessionBuffer.removeFirst(reclaimable)
            bufferStartSample += reclaimable
        }
    }

    /// A confirmed update arrived: the window advanced past another chunk.
    private func noteConfirmation() {
        confirmedWindows += 1
        tailTracker.confirm(through: confirmedWindows * Self.samplesPerConfirmedWindow)
    }

    /// Deduplicate consecutive identical drafts (silence produces repeats).
    private func shouldEmitDraft(_ text: String) -> Bool {
        guard text != lastDraftText else { return false }
        lastDraftText = text
        return true
    }

    /// Stateless draft decode of the unconfirmed tail. Errors are swallowed —
    /// a failed draft pass costs one refresh, never the session.
    private func decodeDraft(_ samples: [Float]) async -> String? {
        guard let batchManager else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: await batchManager.decoderLayerCount)
            let result = try await batchManager.transcribe(samples, decoderState: &state)
            return result.text
        } catch {
            return nil
        }
    }

    /// - Parameter modelsDirectory: directory holding the v2 `.mlmodelc` set.
    ///   Defaults to the bundled copy at Resources/Models/parakeet-tdt-0.6b-v2.
    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory
            ?? Bundle.main.resourceURL!.appendingPathComponent("Models/parakeet-tdt-0.6b-v2")
    }

    /// Single-flight load. Actor reentrancy makes a plain `guard models == nil`
    /// racy: the launch warm and an eager first dictation can both pass the
    /// guard and load the ~443 MB model set twice. Every caller awaits the one
    /// shared task instead. A failed load stays cached — prepare failure means
    /// a broken bundle, and the app fails loudly rather than retrying.
    private var prepareTask: Task<Void, any Error>?

    func prepare() async throws {
        if prepareTask == nil {
            prepareTask = Task { try await performPrepare() }
        }
        try await prepareTask!.value
    }

    private func performPrepare() async throws {
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
        let loaded = try await AsrModels.load(
            from: modelsDirectory,
            version: .v2
        )
        models = loaded

        // Long-lived batch decoder for the draft track. Stateless per call
        // (fresh TdtDecoderState each decode), so unlike the sliding-window
        // manager it is safely reusable across sessions. Default ASRConfig:
        // loadModels auto-adapts the blank token to the loaded model version.
        let batch = AsrManager(config: .default)
        try await batch.loadModels(loaded)
        batchManager = batch
    }

    /// Build a single-session manager wired to the cached models. Awaits the
    /// (single-flight) model load first, so a dictation begun before the launch
    /// warm finishes blocks briefly instead of producing an empty session; once
    /// warm, this only constructs the windowing state.
    private func makeSessionManager() async throws -> SlidingWindowAsrManager? {
        try await prepare()
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
                    await self.beginSession()
                    try await manager.startStreaming(source: .microphone)

                    let updatesTask = self.startUpdatesTask(
                        manager: manager, continuation: continuation
                    )

                    // Draft task: decodes the unconfirmed tail whenever woken,
                    // independent of audio ingestion. Wakes that arrive during
                    // a decode coalesce into one, so a decode starts as soon as
                    // the previous finishes and the floor of new audio has
                    // arrived (takeDraftPlan returns nil until then).
                    let (wakeups, wake) = AsyncStream.makeStream(
                        of: Void.self, bufferingPolicy: .bufferingNewest(1)
                    )
                    let draftTask = self.startDraftTask(wakeups: wakeups, continuation: continuation)
                    defer {
                        wake.finish()
                        draftTask.cancel()
                    }

                    // Pump session audio into the confirmed track and the
                    // draft buffer, then wake the draft task.
                    for await samples in audio {
                        try Task.checkCancellation()
                        if let buffer = Self.pcmBuffer(from: samples) {
                            await manager.streamAudio(buffer)
                        }
                        await self.ingest(samples)
                        wake.yield()
                    }

                    // Stop tail drafts before the flush so none can land after
                    // the flush's finals. The draft task is not awaited: that
                    // would delay the flush by up to one decode.
                    wake.finish()
                    await self.closeDrafts()
                    draftTask.cancel()

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

    /// Forwards confirmed-track updates as TokenEvents.
    private nonisolated func startUpdatesTask(
        manager: SlidingWindowAsrManager, continuation: AsyncStream<TokenEvent>.Continuation
    ) -> Task<Void, Never> {
        // Forward confirmed-track updates as TokenEvents. windowID
        // counts confirmations: once text confirms, the window has
        // advanced, so later drafts belong to a new window and must
        // not replace the old one's finalized text. (The manager
        // can also emit its own sub-threshold updates as drafts.)
        Task {
            for await update in await manager.transcriptionUpdates {
                if update.isConfirmed {
                    let tokenConfidences = update.tokenTimings.map(\.confidence)
                    continuation.yield(.finalized(
                        text: update.text,
                        confidence: update.confidence,
                        tokenConfidences: tokenConfidences
                    ))
                    await self.noteConfirmation()
                } else if await self.shouldEmitDraft(update.text) {
                    continuation.yield(.draft(
                        windowID: await self.confirmedWindows, text: update.text
                    ))
                }
            }
        }
    }

    /// Runs one draft decode per wake: plan, decode, publish.
    private nonisolated func startDraftTask(
        wakeups: AsyncStream<Void>, continuation: AsyncStream<TokenEvent>.Continuation
    ) -> Task<Void, Never> {
        Task {
            for await _ in wakeups {
                guard let plan = await self.takeDraftPlan(),
                      let text = await self.decodeDraft(plan.samples) else { continue }
                await self.emitTailDraft(text, windowID: plan.windowID, to: continuation)
            }
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
