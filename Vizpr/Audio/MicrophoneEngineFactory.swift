// @preconcurrency: AVFAudio's tap/converter block types predate Sendable
// annotations; the audio objects they pass are used only within the callback.
@preconcurrency import AVFoundation
import CoreAudio

/// The counters one capture session shares between the realtime tap and the
/// readers on other threads. All atomic, so reading from the main actor is safe.
final class CaptureCounters: Sendable {
    /// Batches dropped because the consumer fell behind. Monitoring signal for
    /// the dev logger; a nonzero value means ASR lost audio.
    let dropped = AtomicCounter()

    /// Diagnostics: tap==0 → engine/tap never fired; tap>0 && converted==0 →
    /// every conversion failed silently. Read at stop() by the dev logger.
    let tapInvocations = AtomicCounter()
    let converted = AtomicCounter()

    /// Peak RMS of the RAW hardware buffer (scaled ×1e6), measured before any
    /// conversion. Distinguishes "the device is delivering silence" (peak≈0)
    /// from "the converter is zeroing good audio" (raw peak healthy, converted
    /// rms 0) — the discriminator for silent-capture bugs.
    let rawPeak = AtomicCounter()

    /// Hardware frames whose raw level was measured. `rawPeak == 0` means
    /// "silent" only once this covers enough time: before the first measurement
    /// the peak reads 0 on every route. The tap stores the peak first and
    /// publishes this count with release ordering; readers use
    /// `valueAcquiring`.
    let measuredFrames = AtomicCounter()

    /// Per-session diagnostics (field bug: cumulative counters carried
    /// session 1's real audio peak into session 2, masking its silence — the
    /// fallback trigger and the stop() log both need per-session values).
    func reset() {
        tapInvocations.reset()
        converted.reset()
        dropped.reset()
        rawPeak.reset()
        measuredFrames.reset()
    }
}

/// Builds AVAudioEngine-backed capture engines: input tap → converter →
/// stream continuation.
struct MicrophoneEngineFactory: CaptureEngineFactory {
    let counters: CaptureCounters

    func makeEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine? {
        counters.reset()
        return makeEngine(pinnedTo: nil, feeding: continuation)
    }

    func makeBuiltInEngine(feeding continuation: AsyncStream<[Float]>.Continuation) -> CaptureEngine? {
        guard let builtIn = Self.builtInInputDeviceID() else { return nil }
        return makeEngine(pinnedTo: builtIn, feeding: continuation)
    }

    private func makeEngine(
        pinnedTo device: AudioDeviceID?,
        feeding continuation: AsyncStream<[Float]>.Continuation
    ) -> CaptureEngine? {
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
            sampleRate: MicrophoneCapture.sampleRate,
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
            counters: counters
        ))
        input.installTap(
            onBus: 0, bufferSize: MicrophoneCapture.tapBufferFrames,
            format: hardwareFormat, block: tapBlock
        )
        engine.prepare()
        return MicrophoneEngine(
            engine: engine, hardwareSampleRate: hardwareFormat.sampleRate,
            pinnedToBuiltIn: device != nil, counters: counters
        )
    }

    /// The first input-capable device with built-in transport.
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
            guard MicrophoneEngine.isBuiltIn(device) == true else { continue }

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

    /// Everything the realtime tap needs, bundled so the nonisolated factory can
    /// take one argument. @unchecked Sendable: the converter is exclusively owned
    /// by the tap block after construction (created fresh per start, captured
    /// nowhere else); everything else is Sendable or immutable.
    private struct TapContext: @unchecked Sendable {
        let converter: AVAudioConverter
        let targetFormat: AVAudioFormat
        let hardwareSampleRate: Double
        let continuation: AsyncStream<[Float]>.Continuation
        let counters: CaptureCounters
    }

    /// Build the tap callback in a nonisolated context so it carries no actor
    /// isolation (see call site). Runs on AVFAudio's realtime messenger queue:
    /// convert, yield, return — no locks, no waiting (yield with bufferingNewest
    /// never suspends; it drops the oldest batch instead).
    private nonisolated static func makeTapBlock(context: TapContext) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let counters = context.counters
            counters.tapInvocations.increment()

            // Raw-level probe: peak RMS of what the hardware actually delivered,
            // before conversion touches it. Measured on every tap (a sum over
            // one buffer) so a zero peak is evidence, not an unmeasured default.
            if let raw = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for idx in 0..<count { sum += raw[0][idx] * raw[0][idx] }
                let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
                counters.rawPeak.storeMax(Int(rms * 1_000_000))
                counters.measuredFrames.addReleasing(count)
            }

            let ratio = MicrophoneCapture.sampleRate / context.hardwareSampleRate
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
            counters.converted.increment()
            if case .dropped = context.continuation.yield(samples) {
                counters.dropped.increment()
            }
        }
    }
}

/// A prepared AVAudioEngine with its tap installed.
private final class MicrophoneEngine: CaptureEngine {
    private let engine: AVAudioEngine
    let hardwareSampleRate: Double
    private let pinnedToBuiltIn: Bool
    private let counters: CaptureCounters

    init(engine: AVAudioEngine, hardwareSampleRate: Double, pinnedToBuiltIn: Bool, counters: CaptureCounters) {
        self.engine = engine
        self.hardwareSampleRate = hardwareSampleRate
        self.pinnedToBuiltIn = pinnedToBuiltIn
        self.counters = counters
    }

    var route: InputRoute {
        if pinnedToBuiltIn { return .builtIn }
        guard let device = currentInputDeviceID(), let builtIn = Self.isBuiltIn(device) else {
            return .unidentified
        }
        return builtIn ? .builtIn : .external
    }

    func start() throws {
        try engine.start()
        #if DICT_DEV_LOG
        VizprTranscriptLogger.note("capture: engine started, isRunning=\(engine.isRunning)")
        #endif
    }

    func stop() {
        #if DICT_DEV_LOG
        if engine.isRunning {
            let taps = "taps=\(counters.tapInvocations.value) converted=\(counters.converted.value)"
            let raw = String(format: "rawPeak=%.4f", Double(counters.rawPeak.value) / 1_000_000)
            VizprTranscriptLogger.note(
                "capture: stopping — \(taps) dropped=\(counters.dropped.value) \(raw)"
            )
        }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The device the engine's input node is currently bound to.
    private func currentInputDeviceID() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, &size
        ) == noErr else { return nil }
        return deviceID
    }

    /// Nil when the transport type could not be read.
    static func isBuiltIn(_ device: AudioDeviceID) -> Bool? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}
