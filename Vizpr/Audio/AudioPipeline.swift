import CoreML
import FluidAudio

/// Owns the capture→VAD→watchdog loop for one dictation session at a time
/// (PLAN.md §1). Started on `startDictation`, stopped on `commit`/`cancel`, so
/// the mic (and its menu-bar indicator) is live only during sessions.
///
/// Auto-stop is *emitted into the hotkey state machine* via `onAutoStop` — the
/// pipeline never commits anything itself (§6: VAD never decides commits).
/// The VAD also decides which audio the transcription engine hears: captured
/// batches pass through a `SpeechGate`, which holds back silence so the ASR
/// never decodes the long quiet stretch before an auto-stop. Token events are
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
    /// i.e. AFTER every event (including the commit-time tail final, which
    /// arrives later than the commit action) has been delivered to
    /// onTokenEvent. The dev logger writes its dictation record here; a
    /// commit-time write would miss the tail final (field-observed: short
    /// dictations logged empty raw_asr_text — nothing finalizes before the
    /// tail decode unless the session crosses the 10 s window).
    private let onSessionDrained: (@Sendable (Int) async -> Void)?
    /// Fired at stop() when the mic delivered PURE SILENCE for a session
    /// with real length — the AirPods held-route trap (rms 0.0000; second
    /// field occurrence 2026-07-06 burned a whole test session). The caller
    /// surfaces a notice; fail-silent here would look like broken dictation.
    var onSilentSession: (() -> Void)?
    /// Fired when the session cannot capture audio: the source failed to start
    /// (permission denied, engine would not run) or a failover left no engine.
    /// The caller surfaces it; fail-silent would look like a hung hotkey.
    var onCaptureFailure: (() -> Void)?
    /// Live setting (PR 11): attempt the built-in-mic failover when the
    /// selected route delivers silence (default on).
    var silentInputFallback = true

    #if DICT_DEV_LOG
    /// Reports session timing marks (PR 13 latency audit) with the instant
    /// they happened, so a hop to the receiver cannot skew them.
    var onDevTimingMark: (@Sendable (DevTimingMark, ContinuousClock.Instant) -> Void)?
    /// Reports the session's total captured sample count when the capture loop
    /// ends, for the dictation record's `audio_ms`.
    var onDevCapturedSamples: (@Sendable (Int) -> Void)?
    /// Receives the raw and gated audio of each session (last-session audio save).
    var lastSessionAudio: LastSessionAudio?
    #endif

    private var sessionTask: Task<Void, Never>?

    init(
        source: any CaptureSource,
        detector: SpeechDetector,
        engine: (any TranscriptionEngine)? = nil,
        autoStopTimeout: Duration,
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
        autoStopTimeout: Duration,
        onTokenEvent: (@Sendable (TokenEvent) async -> Void)? = nil,
        onSessionDrained: (@Sendable (Int) async -> Void)? = nil,
        onAutoStop: @escaping () -> Void
    ) -> AudioPipeline? {
        guard let model = try? SpeechDetector.loadBundledModel() else { return nil }
        return AudioPipeline(
            source: MicrophoneCapture(),
            detector: SpeechDetector(model: model),
            engine: engine,
            autoStopTimeout: autoStopTimeout,
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
        let onDevCapturedSamples = self.onDevCapturedSamples
        let lastSessionAudio = self.lastSessionAudio
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
            var capturedSamples = 0
            #endif
            var fallbackAttempted = false
            var gate = SpeechGate()
            var speechActive = false

            let stream = await openCapture()
            do {
                for await samples in stream {
                    guard !Task.isCancelled else { break }
                    #if DICT_DEV_LOG
                    sessionChunks += 1
                    capturedSamples += samples.count
                    if sessionChunks == 1 { onDevTimingMark?(.captureStarted, .now) }
                    lastSessionAudio?.appendRaw(samples, epoch: epoch)
                    #endif
                    // Dead-air failover (field case: a phone call owned the
                    // AirPods; the route delivered zeros) -> swap to the
                    // built-in mic once, same stream, session continues.
                    if self.silentInputFallback,
                       let capture = source as? any FailoverCapableSource,
                       SilentRouteDecision.shouldFallBack(
                           evidence: capture.routeEvidence, alreadyAttempted: fallbackAttempted
                       ) {
                        fallbackAttempted = true
                        await self.fallBack(capture)
                    }
                    let updates = try await detector.process(samples)
                    if let latest = updates.last {
                        speechActive = latest.speechActive
                    }
                    for batch in gate.feed(
                        samples, speechActive: speechActive, chunkProbability: updates.last?.probability
                    ) {
                        #if DICT_DEV_LOG
                        lastSessionAudio?.appendGated(batch, epoch: epoch)
                        #endif
                        fanOut.audio?.yield(.samples(batch))
                    }
                    for update in updates {
                        // After the gate's batches, so the engine has every
                        // sample of the utterance when it sees the mark.
                        if update.event?.kind == .speechEnd {
                            fanOut.audio?.yield(.pause)
                        }
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

            #if DICT_DEV_LOG
            onDevCapturedSamples?(capturedSamples)
            #endif

            // Session over: release any held audio that may contain speech,
            // then end the engine's input so it finalizes its tail and
            // finishes its event stream, then let it drain. Runs even when the
            // session task was cancelled by stop() — cancellation only breaks
            // the capture loop above; the tail decode must still complete.
            for batch in gate.end() {
                #if DICT_DEV_LOG
                lastSessionAudio?.appendGated(batch, epoch: epoch)
                #endif
                fanOut.audio?.yield(.samples(batch))
            }
            fanOut.audio?.finish()
            await fanOut.events?.value
            await onSessionDrained?(epoch)
        }
    }

    /// Starts capture. A source that cannot start is reported through
    /// `onCaptureFailure`, and the session continues with an already-ended
    /// stream so the usual flush and drain still run.
    private func openCapture() async -> AsyncStream<[Float]> {
        do {
            return try await source.start()
        } catch {
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("audio capture failed to start: \(error)")
            #endif
            reportCaptureFailure()
            return AsyncStream { $0.finish() }
        }
    }

    private func fallBack(_ capture: any FailoverCapableSource) async {
        switch await capture.fallBackToBuiltInMic() {
        case .switched:
            break
        case .unchanged:
            #if DICT_DEV_LOG
            VizprTranscriptLogger.note("capture: failover to built-in mic not possible, keeping the current route")
            #endif
        case .lost:
            reportCaptureFailure()
        }
    }

    /// A failure after the user already stopped the session is not a failure.
    private func reportCaptureFailure() {
        guard !Task.isCancelled else { return }
        onCaptureFailure?()
    }

    /// Start a transcription session on the engine (if any): returns the audio
    /// continuation to feed and the event-draining task to await at session end.
    private static func startEngineFanOut(
        engine: (any TranscriptionEngine)?,
        onTokenEvent: (@Sendable (TokenEvent) async -> Void)?
    ) -> (audio: AsyncStream<AudioInput>.Continuation?, events: Task<Void, Never>?) {
        guard let engine else { return (nil, nil) }
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioInput.self, bufferingPolicy: .bufferingNewest(256)
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
