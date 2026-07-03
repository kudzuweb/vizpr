import AVFoundation
import FluidAudio
import Testing
@testable import Vizpr

/// Class token for locating the test bundle's resources.
private final class FixtureLocator {}

/// VAD chunk-boundary acceptance (PLAN.md PR 3): run the real Silero model
/// (from the app bundle) over a locally generated WAV fixture padded with known
/// silence, and assert speech start/end land inside the expected windows.
@Suite("VAD boundaries", .serialized)
struct VadBoundaryTests {

    private static let sampleRate = 16_000

    /// Load the checked-in fixture as 16 kHz mono Float32 samples.
    private func fixtureSamples() throws -> [Float] {
        let bundle = Bundle(for: FixtureLocator.self)
        let url = try #require(bundle.url(forResource: "speech-sample", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    @Test("Speech onset and end are detected inside the known padding windows")
    func boundariesLandInExpectedWindows() async throws {
        let speech = try fixtureSamples()
        let leadSilence = [Float](repeating: 0, count: 2 * Self.sampleRate)   // 2 s
        let tailSilence = [Float](repeating: 0, count: 3 * Self.sampleRate)   // 3 s
        let composite = leadSilence + speech + tailSilence

        let detector = SpeechDetector(model: try SpeechDetector.loadBundledModel())
        var events: [(kind: VadEventKind, sampleIndex: Int)] = []
        var processed = 0

        // Feed in uneven batch sizes to exercise the chunker path end-to-end.
        for batch in stride(from: 0, to: composite.count, by: 3210).map({
            Array(composite[$0 ..< min($0 + 3210, composite.count)])
        }) {
            for update in try await detector.process(batch) {
                processed += update.chunk.count
                if let event = update.event {
                    events.append((event.isStart ? .start : .end, processed))
                }
            }
        }

        // Speech starts somewhere inside the fixture's speech region: after the
        // lead silence, before the speech ends. Allow one chunk (4096) of
        // hysteresis slack on each side.
        let speechBegin = leadSilence.count
        let speechFinish = leadSilence.count + speech.count
        let slack = SpeechDetector.chunkSize * 2

        let start = try #require(events.first(where: { $0.kind == .start }),
                                 "no speechStart detected")
        #expect(start.sampleIndex > speechBegin - slack)
        #expect(start.sampleIndex < speechFinish)

        let end = try #require(events.last(where: { $0.kind == .end }),
                               "no speechEnd detected")
        #expect(end.sampleIndex > speechBegin)
        #expect(end.sampleIndex < speechFinish + Self.sampleRate + slack,
                "speechEnd should land within ~1s of hysteresis after speech")

        // And the composite's silence must never read as multiple utterances:
        // exactly one start for this single-utterance fixture.
        #expect(events.filter { $0.kind == .start }.count == 1)
    }

    private enum VadEventKind { case start, end }
}
