// @preconcurrency: AVFAudio's tap/converter block types predate Sendable
// annotations; the audio objects they pass are used only within the callback.
@preconcurrency import AVFoundation
import CoreAudio
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
final class MicrophoneCapture: CaptureSource, @unchecked Sendable {
    static let sampleRate = 16_000.0

    // Touched only from the @MainActor start()/stop() methods (the same
    // main-thread discipline as HotkeyMonitor; @unchecked Sendable covers the
    // Sendable continuation + atomic counter crossing into the tap callback).
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// Batches dropped because the consumer fell behind. Monitoring signal for
    /// the dev logger; a nonzero value means ASR lost audio.
    let droppedBatches = AtomicCounter()

    /// Diagnostics: tap==0 → engine/tap never fired; tap>0 && converted==0 →
    /// every conversion failed silently. Read at stop() by the dev logger.
    let tapInvocations = AtomicCounter()
    let convertedBatches = AtomicCounter()

    /// Peak RMS of the RAW hardware buffer (scaled ×1e6), measured before any
    /// conversion. Distinguishes "the device is delivering silence" (peak≈0)
    /// from "the converter is zeroing good audio" (raw peak healthy, converted
    /// rms 0) — the discriminator for silent-capture bugs.
    let rawPeakLevel = AtomicCounter()

    @MainActor
    func start() async throws -> AsyncStream<[Float]> {
        stop()   // tolerate re-start without leaking a tap

        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: permission=\(AVAudioApplication.shared.recordPermission.rawValue)")
        #endif
        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Per-session diagnostics (field bug: cumulative counters carried
        // session 1's real audio peak into session 2, masking its silence —
        // the fallback trigger and the stop() log both need per-session
        // values).
        tapInvocations.reset()
        convertedBatches.reset()
        droppedBatches.reset()
        rawPeakLevel.reset()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        #if DICT_DEV_LOG
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        VizprTranscriptLogger.note(
            "capture: hw format \(hardwareFormat.sampleRate)Hz x\(hardwareFormat.channelCount)ch device=\(device)"
        )
        #endif

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

        // The tap block MUST be formed outside any actor context: a closure
        // created inside this @MainActor method inherits MainActor isolation,
        // and Swift 6 inserts a dynamic executor assertion that traps (SIGTRAP)
        // when AVFAudio invokes the tap on its realtime messenger queue. The
        // nonisolated factory produces an isolation-free closure.
        let tapBlock = Self.makeTapBlock(context: TapContext(
            converter: converter,
            targetFormat: targetFormat,
            hardwareSampleRate: hardwareFormat.sampleRate,
            continuation: continuation,
            taps: tapInvocations,
            converts: convertedBatches,
            dropped: droppedBatches,
            rawPeak: rawPeakLevel
        ))
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)

        engine.prepare()
        try engine.start()
        self.engine = engine
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: engine started, isRunning=\(engine.isRunning)")
        #endif
        return stream
    }

    /// Mid-session failover to the built-in microphone (field case,
    /// 2026-07-06: a phone call owned the AirPods; macOS kept handing us the
    /// AirPods input route, which delivered pure zeros). Tears the engine
    /// down and rebuilds it pinned to the built-in device, feeding the SAME
    /// stream continuation — the consumer never notices. Only the dead air
    /// is lost, and it was dead.
    @MainActor
    func fallBackToBuiltInMic() -> Bool {
        guard let oldEngine = engine, let continuation else { return false }
        guard let builtIn = Self.builtInInputDeviceID() else { return false }

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        // Pin the input node's underlying audio unit to the built-in device
        // BEFORE reading formats or installing the tap.
        var deviceID = builtIn
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(
                  unit, kAudioOutputUnitProperty_CurrentDevice,
                  kAudioUnitScope_Global, 0,
                  &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
              ) == noErr else { return false }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        else { return false }

        let tapBlock = Self.makeTapBlock(context: TapContext(
            converter: converter,
            targetFormat: targetFormat,
            hardwareSampleRate: hardwareFormat.sampleRate,
            continuation: continuation,
            taps: tapInvocations,
            converts: convertedBatches,
            dropped: droppedBatches,
            rawPeak: rawPeakLevel
        ))
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)
        newEngine.prepare()
        guard (try? newEngine.start()) != nil else { return false }
        engine = newEngine
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note(
            "capture: FELL BACK to built-in mic (previous route was silent)")
        #endif
        return true
    }

    /// CoreAudio lookup: the first input-capable device with built-in
    /// transport.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport
            ) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &streamsAddress, 0, nil, &streamsSize
            ) == noErr, streamsSize > 0 else { continue }
            return device
        }
        return nil
    }

    @MainActor
    func stop() {
        #if DICT_DEV_LOG
        if engine != nil {
            let counters = "taps=\(tapInvocations.value) converted=\(convertedBatches.value)"
            let raw = String(format: "rawPeak=%.4f", Double(rawPeakLevel.value) / 1_000_000)
            VizprTranscriptLogger.note(
                "capture: stopping — \(counters) dropped=\(droppedBatches.value) \(raw)"
            )
        }
        #endif
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }

    /// Everything the realtime tap needs, bundled so the nonisolated factory can
    /// take one argument. @unchecked Sendable: the converter is exclusively owned
    /// by the tap block after construction (created fresh per start, captured
    /// nowhere else); everything else is Sendable or immutable.
    private struct TapContext: @unchecked Sendable {
        let converter: AVAudioConverter
        let targetFormat: AVAudioFormat
        let hardwareSampleRate: Double
        let continuation: AsyncStream<[Float]>.Continuation
        let taps: AtomicCounter
        let converts: AtomicCounter
        let dropped: AtomicCounter
        let rawPeak: AtomicCounter
    }

    /// Build the tap callback in a nonisolated context so it carries no actor
    /// isolation (see call site). Runs on AVFAudio's realtime messenger queue:
    /// convert, yield, return — no locks, no waiting (yield with bufferingNewest
    /// never suspends; it drops the oldest batch instead).
    private nonisolated static func makeTapBlock(context: TapContext) -> AVAudioNodeTapBlock {
        { buffer, _ in
            context.taps.increment()

            // Raw-level probe (every 8th buffer): peak RMS of what the hardware
            // actually delivered, before conversion touches it.
            if context.taps.value % 8 == 0, let raw = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for idx in 0..<count { sum += raw[0][idx] * raw[0][idx] }
                let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
                context.rawPeak.storeMax(Int(rms * 1_000_000))
            }

            let ratio = sampleRate / context.hardwareSampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: context.targetFormat, frameCapacity: capacity
            ) else { return }

            // nonisolated(unsafe): the converter invokes its input block
            // synchronously within this call; nothing escapes the frame.
            nonisolated(unsafe) var pulled = false
            var conversionError: NSError?
            context.converter.convert(to: converted, error: &conversionError) { _, status in
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
            context.converts.increment()
            if case .dropped = context.continuation.yield(samples) {
                context.dropped.increment()
            }
        }
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
