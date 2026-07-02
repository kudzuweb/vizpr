import CoreML
import FluidAudio

/// Owns the capture→VAD→watchdog loop for one dictation session at a time
/// (PLAN.md §1). Started on `startDictation`, stopped on `commit`/`cancel`, so
/// the mic (and its menu-bar indicator) is live only during sessions.
///
/// Auto-stop is *emitted into the hotkey state machine* via `onAutoStop` — the
/// pipeline never commits anything itself (§6: VAD never decides commits).
/// The same capture stream fans out to the transcription engine; its token
/// events feed the dev logger until TokenStream lands (PR 5).
@MainActor
final class AudioPipeline {
    private let source: any CaptureSource
    private let detector: SpeechDetector
    private let engine: (any TranscriptionEngine)?
    private let autoStopTimeout: Duration
    private let onAutoStop: () -> Void

    private var sessionTask: Task<Void, Never>?

    init(
        source: any CaptureSource,
        detector: SpeechDetector,
        engine: (any TranscriptionEngine)? = nil,
        autoStopTimeout: Duration = .seconds(6),
        onAutoStop: @escaping () -> Void
    ) {
        self.source = source
        self.detector = detector
        self.engine = engine
        self.autoStopTimeout = autoStopTimeout
        self.onAutoStop = onAutoStop
    }

    /// Build the production pipeline with the bundled VAD model. Returns nil if
    /// the bundled model fails to load — callers surface that loudly (it means a
    /// broken build, invariant: fail loudly at startup).
    static func makeDefault(
        engine: (any TranscriptionEngine)?,
        onAutoStop: @escaping () -> Void
    ) -> AudioPipeline? {
        guard let model = try? SpeechDetector.loadBundledModel() else { return nil }
        return AudioPipeline(
            source: MicrophoneCapture(),
            detector: SpeechDetector(model: model),
            engine: engine,
            onAutoStop: onAutoStop
        )
    }

    func start() {
        guard sessionTask == nil else { return }   // one session at a time

        sessionTask = Task { @MainActor [source, detector, engine, autoStopTimeout, onAutoStop] in
            var watchdog = SilenceWatchdog(
                timeout: autoStopTimeout,
                sampleRate: Int(MicrophoneCapture.sampleRate)
            )
            await detector.reset()

            // Fan the capture stream out to the transcription engine. Until
            // TokenStream (PR 5), events go to the dev logger — enough to
            // dogfood live transcription end to end.
            let fanOut = Self.startEngineFanOut(engine: engine)

            #if DICT_DEV_LOG
            var chunkCount = 0
            #endif

            do {
                let stream = try await source.start()
                for await samples in stream {
                    guard !Task.isCancelled else { break }
                    fanOut.audio?.yield(samples)
                    for update in try await detector.process(samples) {
                        #if DICT_DEV_LOG
                        chunkCount += 1
                        Self.logUpdate(update, chunkCount: chunkCount)
                        #endif
                        if watchdog.observe(
                            chunkSampleCount: update.chunk.count,
                            speechActive: update.speechActive
                        ) {
                            #if DICT_DEV_LOG
                            VizprTranscriptLogger.note("watchdog fired -> autoStop (chunk \(chunkCount))")
                            #endif
                            // Routed through the hotkey machine — the single
                            // commit path. Inert unless the session is latched.
                            onAutoStop()
                        }
                    }
                }
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("audio stream ended after \(chunkCount) chunks")
                #endif
            } catch {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("audio pipeline error: \(error)")
                #endif
            }

            // Session over: end the engine's input so it flushes its tail and
            // finishes its event stream, then let it drain.
            fanOut.audio?.finish()
            await fanOut.events?.value
        }
    }

    /// Start a transcription session on the engine (if any): returns the audio
    /// continuation to feed and the event-draining task to await at session end.
    private static func startEngineFanOut(
        engine: (any TranscriptionEngine)?
    ) -> (audio: AsyncStream<[Float]>.Continuation?, events: Task<Void, Never>?) {
        guard let engine else { return (nil, nil) }
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(256)
        )
        let task = Task { @MainActor in
            for await event in engine.transcribe(stream) {
                #if DICT_DEV_LOG
                switch event {
                case let .draft(windowID, text):
                    VizprTranscriptLogger.note("asr draft w\(windowID): \(text)")
                case let .finalized(text, confidence, _):
                    VizprTranscriptLogger.note(
                        String(format: "asr final (conf %.2f): ", confidence) + text
                    )
                }
                #else
                _ = event
                #endif
            }
        }
        return (continuation, task)
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        source.stop()
        Task { await detector.reset() }
        #if DICT_DEV_LOG
        if let capture = source as? MicrophoneCapture, capture.droppedBatches.value > 0 {
            VizprTranscriptLogger.note("dropped audio batches this run: \(capture.droppedBatches.value)")
        }
        #endif
    }

    #if DICT_DEV_LOG
    /// Per-chunk diagnostics: VAD events as they happen, plus one line per
    /// second (4 chunks × 256 ms) of raw level + probability — separates
    /// capture problems (rms≈0) from detection problems (rms healthy, prob low).
    private static func logUpdate(_ update: SpeechDetector.Update, chunkCount: Int) {
        if let event = update.event {
            VizprTranscriptLogger.note("vad event: \(event.kind) t=\(event.time ?? -1)")
        }
        if chunkCount % 4 == 0 {
            VizprTranscriptLogger.note(String(
                format: "vad chunk %d: rms=%.4f prob=%.2f active=%d",
                chunkCount, rms(update.chunk), update.probability, update.speechActive ? 1 : 0
            ))
        }
    }

    /// Root-mean-square level of a chunk — diagnostics only.
    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
    #endif
}
