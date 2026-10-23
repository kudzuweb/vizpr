import CoreML
import FluidAudio

/// Owns the capture→VAD→watchdog loop for one dictation session at a time
/// (PLAN.md §1). Started on `startDictation`, stopped on `commit`/`cancel`, so
/// the mic (and its menu-bar indicator) is live only during sessions.
///
/// Auto-stop is *emitted into the hotkey state machine* via `onAutoStop` — the
/// pipeline never commits anything itself (§6: VAD never decides commits).
/// The capture stream fans out to the transcription engine; token events are
/// handed to `onTokenEvent` (SmartCleanup → TokenStream in production), with
/// the dev logger observing alongside.
@MainActor
final class AudioPipeline {
    private let source: any CaptureSource
    private let detector: SpeechDetector
    private let engine: (any TranscriptionEngine)?
    /// var: live setting (PR 11) — captured per session at start(), so a
    /// change applies from the NEXT session.
    private var autoStopTimeout: Duration

    func setAutoStopTimeout(_ timeout: Duration) {
        autoStopTimeout = timeout
    }
    private let onAutoStop: () -> Void
    /// Consumer for ASR token events (SmartCleanup.ingest in production; nil
    /// falls back to dev-log-only, useful in bring-up).
    private let onTokenEvent: (@Sendable (TokenEvent) async -> Void)?
    /// Fires once per session after the engine's event stream fully drains —
    /// i.e. AFTER every event (including the commit-time flush finals, which
    /// arrive later than the commit action) has been delivered to
    /// onTokenEvent. The dev logger writes its dictation record here; a
    /// commit-time write would miss the flush (field-observed: short
    /// dictations logged empty raw_asr_text — nothing finalizes before the
    /// flush unless the session crosses the 10 s confirmation window).
    private let onSessionDrained: (@Sendable (Int) async -> Void)?
    /// Fired at stop() when the mic delivered PURE SILENCE for a session
    /// with real length — the AirPods held-route trap (rms 0.0000; second
    /// field occurrence 2026-07-06 burned a whole test session). The caller
    /// surfaces a notice; fail-silent here would look like broken dictation.
    var onSilentSession: (() -> Void)?
    /// Live setting (PR 11): attempt the built-in-mic failover when the
    /// selected route delivers silence (default on).
    var silentInputFallback = true

    #if DICT_DEV_LOG
    /// Reports session timing marks (PR 13 latency audit) with the instant
    /// they happened, so a hop to the receiver cannot skew them.
    var onDevTimingMark: (@Sendable (DevTimingMark, ContinuousClock.Instant) -> Void)?
    #endif

    private var sessionTask: Task<Void, Never>?

    init(
        source: any CaptureSource,
        detector: SpeechDetector,
        engine: (any TranscriptionEngine)? = nil,
        autoStopTimeout: Duration = .seconds(6),
        onTokenEvent: (@Sendable (TokenEvent) async -> Void)? = nil,
        onSessionDrained: (@Sendable (Int) async -> Void)? = nil,
        onAutoStop: @escaping () -> Void
    ) {
        self.source = source
        self.detector = detector
        self.engine = engine
        self.autoStopTimeout = autoStopTimeout
        self.onTokenEvent = onTokenEvent
        self.onSessionDrained = onSessionDrained
        self.onAutoStop = onAutoStop
    }

    /// Build the production pipeline with the bundled VAD model. Returns nil if
    /// the bundled model fails to load — callers surface that loudly (it means a
    /// broken build, invariant: fail loudly at startup).
    static func makeDefault(
        engine: (any TranscriptionEngine)?,
        onTokenEvent: (@Sendable (TokenEvent) async -> Void)? = nil,
        onSessionDrained: (@Sendable (Int) async -> Void)? = nil,
        onAutoStop: @escaping () -> Void
    ) -> AudioPipeline? {
        guard let model = try? SpeechDetector.loadBundledModel() else { return nil }
        return AudioPipeline(
            source: MicrophoneCapture(),
            detector: SpeechDetector(model: model),
            engine: engine,
            onTokenEvent: onTokenEvent,
            onSessionDrained: onSessionDrained,
            onAutoStop: onAutoStop
        )
    }

    /// - Parameter sessionEpoch: echoed back through onSessionDrained so a
    ///   late drain from a superseded session is attributable (SettleGate).
    func start(sessionEpoch: Int = 0) {
        guard sessionTask == nil else { return }   // one session at a time

        #if DICT_DEV_LOG
        // Captured by value here (a capture list cannot sit inside #if).
        let onDevTimingMark = self.onDevTimingMark
        #endif
        sessionTask = Task { @MainActor [source, detector, engine, autoStopTimeout, onAutoStop, onTokenEvent, onSessionDrained] in
            let epoch = sessionEpoch
            var watchdog = SilenceWatchdog(
                timeout: autoStopTimeout,
                sampleRate: Int(MicrophoneCapture.sampleRate)
            )
            await detector.reset()

            // Fan the capture stream out to the transcription engine. Until
            // TokenStream (PR 5), events go to the dev logger — enough to
            // dogfood live transcription end to end.
            let fanOut = Self.startEngineFanOut(engine: engine, onTokenEvent: onTokenEvent)

            #if DICT_DEV_LOG
            var chunkCount = 0
            var sessionChunks = 0
            #endif
            var fallbackAttempted = false

            do {
                let stream = try await source.start()
                for await samples in stream {
                    guard !Task.isCancelled else { break }
                    #if DICT_DEV_LOG
                    sessionChunks += 1
                    if sessionChunks == 1 { onDevTimingMark?(.captureStarted, .now) }
                    #endif
                    // Dead-air failover (field case: a phone call owned the
                    // AirPods; the route delivered zeros) -> swap to the
                    // built-in mic once, same stream, session continues.
                    if self.silentInputFallback,
                       let capture = source as? MicrophoneCapture,
                       SilentRouteDecision.shouldFallBack(
                           measuredTaps: capture.measuredTaps.value,
                           rawPeak: capture.rawPeakLevel.value,
                           routeIsBuiltIn: capture.routeIsBuiltIn,
                           alreadyAttempted: fallbackAttempted
                       ) {
                        fallbackAttempted = true
                        _ = await capture.fallBackToBuiltInMic()
                    }
                    fanOut.audio?.yield(samples)
                    for update in try await detector.process(samples) {
                        #if DICT_DEV_LOG
                        chunkCount += 1
                        Self.logUpdate(update, chunkCount: chunkCount)
                        if update.event?.kind == .speechStart {
                            onDevTimingMark?(.speechOnset, .now)
                        }
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
            // finishes its event stream, then let it drain. Runs even when the
            // session task was cancelled by stop() — cancellation only breaks
            // the capture loop above; the flush must still complete.
            fanOut.audio?.finish()
            await fanOut.events?.value
            await onSessionDrained?(epoch)
        }
    }

    /// Start a transcription session on the engine (if any): returns the audio
    /// continuation to feed and the event-draining task to await at session end.
    private static func startEngineFanOut(
        engine: (any TranscriptionEngine)?,
        onTokenEvent: (@Sendable (TokenEvent) async -> Void)?
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
                #endif
                await onTokenEvent?(event)
            }
        }
        return (continuation, task)
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        source.stop()
        Task { await detector.reset() }
        if let capture = source as? MicrophoneCapture,
           capture.rawPeakLevel.value == 0, capture.tapInvocations.value > 20 {
            onSilentSession?()
        }
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
