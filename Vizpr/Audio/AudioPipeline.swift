import CoreML
import FluidAudio

/// Owns the capture→VAD→watchdog loop for one dictation session at a time
/// (PLAN.md §1). Started on `startDictation`, stopped on `commit`/`cancel`, so
/// the mic (and its menu-bar indicator) is live only during sessions.
///
/// Auto-stop is *emitted into the hotkey state machine* via `onAutoStop` — the
/// pipeline never commits anything itself (§6: VAD never decides commits).
/// ASR consumption of the same chunks arrives in PR 4; for now updates feed the
/// watchdog and the dev logger.
@MainActor
final class AudioPipeline {
    private let source: any AudioSource
    private let detector: SpeechDetector
    private let autoStopTimeout: Duration
    private let onAutoStop: () -> Void

    private var sessionTask: Task<Void, Never>?

    init(
        source: any AudioSource,
        detector: SpeechDetector,
        autoStopTimeout: Duration = .seconds(6),
        onAutoStop: @escaping () -> Void
    ) {
        self.source = source
        self.detector = detector
        self.autoStopTimeout = autoStopTimeout
        self.onAutoStop = onAutoStop
    }

    /// Build the production pipeline with the bundled VAD model. Returns nil if
    /// the bundled model fails to load — callers surface that loudly (it means a
    /// broken build, invariant: fail loudly at startup).
    static func makeDefault(onAutoStop: @escaping () -> Void) -> AudioPipeline? {
        guard let model = try? SpeechDetector.loadBundledModel() else { return nil }
        return AudioPipeline(
            source: MicrophoneCapture(),
            detector: SpeechDetector(model: model),
            onAutoStop: onAutoStop
        )
    }

    func start() {
        guard sessionTask == nil else { return }   // one session at a time

        sessionTask = Task { @MainActor [source, detector, autoStopTimeout, onAutoStop] in
            var watchdog = SilenceWatchdog(
                timeout: autoStopTimeout,
                sampleRate: Int(MicrophoneCapture.sampleRate)
            )
            await detector.reset()

            do {
                let stream = try await source.start()
                for await samples in stream {
                    guard !Task.isCancelled else { break }
                    for update in try await detector.process(samples) {
                        #if DICT_DEV_LOG
                        if let event = update.event {
                            VizprTranscriptLogger.note("vad event: \(event.kind) t=\(event.time ?? -1)")
                        }
                        #endif
                        if watchdog.observe(
                            chunkSampleCount: update.chunk.count,
                            speechActive: update.speechActive
                        ) {
                            // Routed through the hotkey machine — the single
                            // commit path. Inert unless the session is latched.
                            onAutoStop()
                        }
                    }
                }
            } catch {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("audio pipeline error: \(error)")
                #endif
            }
        }
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        source.stop()
        Task { await detector.reset() }
    }
}
