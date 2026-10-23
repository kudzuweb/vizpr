// @preconcurrency: AVFAudio's tap/converter block types predate Sendable
// annotations; the audio objects they pass are used only within the callback.
@preconcurrency import AVFoundation
import Synchronization

/// Sendable wrapper around a move-only `Atomic` counter so the tap callback
/// (a @Sendable closure) can share it with main-thread readers.
final class AtomicCounter: Sendable {
    private let storage = Atomic<Int>(0)
    func increment() { storage.add(1, ordering: .relaxed) }
    func reset() { storage.store(0, ordering: .relaxed) }
    func storeMax(_ candidate: Int) {
        var current = storage.load(ordering: .relaxed)
        while candidate > current {
            let (exchanged, original) = storage.weakCompareExchange(
                expected: current, desired: candidate,
                successOrdering: .relaxed, failureOrdering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }
    var value: Int { storage.load(ordering: .relaxed) }
}

/// Abstraction over the microphone so the pipeline can be tested with synthetic
/// audio (PLAN.md §8: system APIs behind protocol seams).
protocol CaptureSource: Sendable {
    /// Begin capture and return the sample stream: 16 kHz mono Float32, batch
    /// sizes determined by the hardware route. Throws if the mic permission is
    /// missing or the audio engine cannot start.
    func start() async throws -> AsyncStream<[Float]>
    /// Returns immediately; teardown happens asynchronously but always ahead
    /// of any later `start()`.
    func stop()
}

enum AudioCaptureError: Error {
    case microphonePermissionDenied
    case cannotConfigureInput
}

/// AVFoundation capture shell (PLAN.md §7): input tap → continuation bridge →
/// `AsyncStream`. The tap callback runs on a realtime audio thread and must
/// never block — the bridge uses drop-oldest backpressure (`bufferingNewest`)
/// with a dropped-batch counter instead of ever waiting on the consumer.
///
/// Engine lifecycle lives in `CaptureEngineController` (off the main thread);
/// this type adds the microphone permission and exposes the session counters.
final class MicrophoneCapture: CaptureSource {
    static let sampleRate = 16_000.0
    /// Frames per tap callback, at the hardware sample rate.
    static let tapBufferFrames: AVAudioFrameCount = 4096

    private let counters: CaptureCounters
    private let controller: CaptureEngineController

    init() {
        let counters = CaptureCounters()
        self.counters = counters
        controller = CaptureEngineController(factory: MicrophoneEngineFactory(counters: counters))
    }

    var droppedBatches: AtomicCounter { counters.dropped }
    var tapInvocations: AtomicCounter { counters.tapInvocations }
    var rawPeakLevel: AtomicCounter { counters.rawPeak }
    var measuredTaps: AtomicCounter { counters.measuredTaps }

    /// Whether the input device in use is the built-in microphone.
    var routeIsBuiltIn: Bool { controller.route == .builtIn }

    func start() async throws -> AsyncStream<[Float]> {
        // Taken before the permission prompt so a stop during it cancels this start.
        let ticket = controller.makeStartTicket()
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: permission=\(AVAudioApplication.shared.recordPermission.rawValue)")
        #endif
        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        return try await controller.start(ticket)
    }

    func stop() {
        controller.stop()
    }

    func fallBackToBuiltInMic() async -> FailoverResult {
        await controller.fallBackToBuiltInMic()
    }

    /// Resolve mic permission, prompting once if undetermined. The prompt only
    /// ever appears here — after the user initiated a dictation — never at launch.
    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }
}
