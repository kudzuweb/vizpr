// @preconcurrency: AVFAudio's tap/converter block types predate Sendable
// annotations; the audio objects they pass are used only within the callback.
@preconcurrency import AVFoundation
import Synchronization

/// Sendable wrapper around a move-only `Atomic` counter so the tap callback
/// (a @Sendable closure) can share it with main-thread readers.
final class AtomicCounter: Sendable {
    private let storage = Atomic<Int>(0)
    func increment() { storage.add(1, ordering: .relaxed) }
    var count: Int { storage.load(ordering: .relaxed) }
}

/// Abstraction over the microphone so the pipeline can be tested with synthetic
/// audio (PLAN.md §8: system APIs behind protocol seams).
protocol AudioSource: Sendable {
    /// Begin capture and return the sample stream: 16 kHz mono Float32, batch
    /// sizes determined by the hardware route. Throws if the mic permission is
    /// missing or the audio engine cannot start.
    @MainActor func start() async throws -> AsyncStream<[Float]>
    @MainActor func stop()
}

enum AudioCaptureError: Error {
    case microphonePermissionDenied
}

/// AVFoundation capture shell (PLAN.md §7): input tap → continuation bridge →
/// `AsyncStream`. The tap callback runs on a realtime audio thread and must
/// never block — the bridge uses drop-oldest backpressure (`bufferingNewest`)
/// with a dropped-batch counter instead of ever waiting on the consumer.
///
/// Engine/tap lifecycle is MainActor-only; the tap callback owns its converter
/// exclusively (created per start, captured only by that closure), so the only
/// cross-thread traffic is the Sendable continuation and an atomic counter.
final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    static let sampleRate = 16_000.0

    // Touched only from the @MainActor start()/stop() methods (the same
    // main-thread discipline as HotkeyMonitor; @unchecked Sendable covers the
    // Sendable continuation + atomic counter crossing into the tap callback).
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// Batches dropped because the consumer fell behind. Monitoring signal for
    /// the dev logger; a nonzero value means ASR lost audio.
    let droppedBatches = AtomicCounter()

    @MainActor
    func start() async throws -> AsyncStream<[Float]> {
        stop()   // tolerate re-start without leaking a tap

        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            // Converter creation only fails for incompatible formats; any mic
            // route AVFoundation offers converts to 16k mono float.
            throw AudioCaptureError.microphonePermissionDenied
        }

        // ~64 batches ≈ 1.5–4 s of headroom depending on route buffer size:
        // enough to absorb consumer hiccups, small enough to bound latency.
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation
        let dropped = droppedBatches

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            // Realtime thread: convert, yield, return. No locks, no allocs beyond
            // the conversion buffer, no waiting (yield with bufferingNewest never
            // suspends — it drops the oldest batch instead).
            let ratio = Self.sampleRate / hardwareFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }
            // nonisolated(unsafe): the converter invokes its input block
            // synchronously within this call; nothing escapes the frame.
            nonisolated(unsafe) var pulled = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if pulled {
                    status.pointee = .noDataNow
                    return nil
                }
                pulled = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil,
                  converted.frameLength > 0,
                  let channel = converted.floatChannelData else { return }

            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            if case .dropped = continuation.yield(samples) {
                dropped.increment()
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        return stream
    }

    @MainActor
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
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
