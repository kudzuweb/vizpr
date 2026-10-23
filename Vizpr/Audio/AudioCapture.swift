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
    func start() async throws -> AsyncStream<[Float]>
    /// Returns immediately; teardown happens asynchronously but always ahead
    /// of any later `start()`.
    func stop()
}

enum AudioCaptureError: Error {
    case microphonePermissionDenied
    case cannotConfigureInput
}

/// What a mid-session failover left behind.
enum FailoverResult: Sendable {
    /// Capture now runs on the replacement engine.
    case switched
    /// The replacement could not be built; the original engine still captures.
    case unchanged
    /// The original engine was stopped and the replacement would not start, so
    /// the stream has ended.
    case lost
}

/// AVFoundation capture shell (PLAN.md §7): input tap → continuation bridge →
/// `AsyncStream`. The tap callback runs on a realtime audio thread and must
/// never block — the bridge uses drop-oldest backpressure (`bufferingNewest`)
/// with a dropped-batch counter instead of ever waiting on the consumer.
///
/// Engine/tap lifecycle runs on one private serial queue, never the main thread:
/// a cold `engine.start()` blocks for ~2 s, which would stall the UI and the
/// hotkey tap. The tap callback owns its converter exclusively (created per
/// start, captured only by that closure), so the only cross-thread traffic is
/// the Sendable continuation and the atomic counters.
final class MicrophoneCapture: CaptureSource, @unchecked Sendable {
    static let sampleRate = 16_000.0
    /// Frames per tap callback, at the hardware sample rate.
    static let tapBufferFrames: AVAudioFrameCount = 4096

    /// Serializes every engine mutation. `stop()` enqueues here too, so a stop
    /// always lands before any later start, and a stop requested while a start
    /// is still queued tears down the engine that start created.
    private let queue = DispatchQueue(label: "com.kudzuweb.vizpr.audio-capture", qos: .userInitiated)

    // Touched only on `queue` (@unchecked Sendable covers the Sendable
    // continuation + atomic counters crossing into the tap callback).
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

    /// Taps whose raw level was measured. `rawPeakLevel == 0` means "silent"
    /// only once this is large enough: before the first measurement the peak
    /// reads 0 on every route.
    let measuredTaps = AtomicCounter()

    private let builtInRoute = Mutex(false)

    /// Whether the input device in use is the built-in microphone. Set when
    /// the engine starts and again after a failover; false when the device
    /// could not be identified.
    var routeIsBuiltIn: Bool { builtInRoute.withLock { $0 } }

    func start() async throws -> AsyncStream<[Float]> {
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: permission=\(AVAudioApplication.shared.recordPermission.rawValue)")
        #endif
        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        // A stop that arrived during the permission prompt found nothing to
        // tear down; honor it here instead of starting an engine nobody owns.
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.startEngine() })
            }
        }
    }

    private func startEngine() throws -> AsyncStream<[Float]> {
        stopEngine()   // tolerate re-start without leaking a tap

        // Per-session diagnostics (field bug: cumulative counters carried
        // session 1's real audio peak into session 2, masking its silence —
        // the fallback trigger and the stop() log both need per-session
        // values).
        tapInvocations.reset()
        convertedBatches.reset()
        droppedBatches.reset()
        rawPeakLevel.reset()
        measuredTaps.reset()

        // The continuation is stored only once the engine runs, so a failed
        // start leaves no half-built state behind.
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(64)
        )
        guard let engine = makeEngine(pinnedTo: nil, feeding: continuation) else {
            continuation.finish()
            throw AudioCaptureError.cannotConfigureInput
        }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        self.engine = engine
        self.continuation = continuation
        builtInRoute.withLock { $0 = Self.isBuiltIn(Self.currentInputDeviceID(of: engine.inputNode)) }
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: engine started, isRunning=\(engine.isRunning)")
        #endif
        return stream
    }

    /// Builds an engine with its tap installed and prepared but not started, so
    /// a caller can swap engines without touching the running one until the
    /// replacement is known to be configurable. Nil when the input cannot be
    /// pinned or converted to 16 kHz mono.
    private func makeEngine(
        pinnedTo device: AudioDeviceID?,
        feeding continuation: AsyncStream<[Float]>.Continuation
    ) -> AVAudioEngine? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var deviceID = device {
            // Pin the input node's underlying audio unit BEFORE reading
            // formats or installing the tap.
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(
                      unit, kAudioOutputUnitProperty_CurrentDevice,
                      kAudioUnitScope_Global, 0,
                      &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
                  ) == noErr else { return nil }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        #if DICT_DEV_LOG
        // Device name resolves OFF the hot path (PR 13): AVCaptureDevice
        // discovery cost real milliseconds per session start for a log
        // decoration. Same line, logged a beat later.
        Task.detached(priority: .utility) {
            let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
            VizprTranscriptLogger.note(
                "capture: hw format \(hardwareFormat.sampleRate)Hz x\(hardwareFormat.channelCount)ch device=\(device)"
            )
        }
        #endif

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            // Converter creation only fails for incompatible formats; any mic
            // route AVFoundation offers converts to 16k mono float.
            return nil
        }

        // The tap block MUST be formed outside any actor context: a closure
        // created inside an actor-isolated method inherits that isolation,
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
            rawPeak: rawPeakLevel,
            measured: measuredTaps
        ))
        input.installTap(onBus: 0, bufferSize: Self.tapBufferFrames, format: hardwareFormat, block: tapBlock)
        engine.prepare()
        return engine
    }

    /// Mid-session failover to the built-in microphone (field case,
    /// 2026-07-06: a phone call owned the AirPods; macOS kept handing us the
    /// AirPods input route, which delivered pure zeros). Feeds the SAME stream
    /// continuation, so the consumer never notices; only the dead air is lost.
    /// The replacement is fully built before the running engine is touched, so
    /// an unusable built-in device leaves capture exactly as it was.
    func fallBackToBuiltInMic() async -> FailoverResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.swapToBuiltInEngine()) }
        }
    }

    private func swapToBuiltInEngine() -> FailoverResult {
        guard let oldEngine = engine, let continuation,
              let builtIn = Self.builtInInputDeviceID(),
              let replacement = makeEngine(pinnedTo: builtIn, feeding: continuation)
        else { return .unchanged }

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        do {
            try replacement.start()
        } catch {
            // The old engine is already down, so nothing is left to capture.
            replacement.inputNode.removeTap(onBus: 0)
            stopEngine()
            return .lost
        }
        engine = replacement
        builtInRoute.withLock { $0 = true }
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note(
            "capture: FELL BACK to built-in mic (previous route was silent)")
        #endif
        return .switched
    }

    /// The device the engine's input node is currently bound to.
    private static func currentInputDeviceID(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, &size
        ) == noErr else { return nil }
        return deviceID
    }

    private static func isBuiltIn(_ device: AudioDeviceID?) -> Bool {
        guard let device else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
            && transport == kAudioDeviceTransportTypeBuiltIn
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
            guard isBuiltIn(device) else { continue }

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

    func stop() {
        queue.async { self.stopEngine() }
    }

    private func stopEngine() {
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
        let measured: AtomicCounter
    }

    /// Build the tap callback in a nonisolated context so it carries no actor
    /// isolation (see call site). Runs on AVFAudio's realtime messenger queue:
    /// convert, yield, return — no locks, no waiting (yield with bufferingNewest
    /// never suspends; it drops the oldest batch instead).
    private nonisolated static func makeTapBlock(context: TapContext) -> AVAudioNodeTapBlock {
        { buffer, _ in
            context.taps.increment()

            // Raw-level probe: peak RMS of what the hardware actually delivered,
            // before conversion touches it. Measured on every tap (a sum over
            // one buffer) so a zero peak is evidence, not an unmeasured default.
            if let raw = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for idx in 0..<count { sum += raw[0][idx] * raw[0][idx] }
                let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
                context.rawPeak.storeMax(Int(rms * 1_000_000))
                context.measured.increment()
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
