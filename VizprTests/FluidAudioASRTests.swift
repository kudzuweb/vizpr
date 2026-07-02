import AVFoundation
import FluidAudio
import Testing
@testable import Vizpr

/// Class token for locating the test bundle's resources.
private final class ASRFixtureLocator {}

/// Whether the bundled ASR model is present in the host app bundle. The model
/// is fetched by scripts/fetch-models.sh (too large for git); without it these
/// tests can't run — better an explicit skip than a misleading failure.
private var bundledASRModelPresent: Bool {
    guard let url = Bundle.main.resourceURL?
        .appendingPathComponent("Models/parakeet-tdt-0.6b-v2") else { return false }
    return FileManager.default.fileExists(atPath: url.path)
}

/// Golden token-event acceptance for the ASR engine (PLAN.md PR 4): fixture
/// WAV through the real bundled Parakeet v2, tolerant to dedup nondeterminism
/// at window seams. Also the zero-network check: `DownloadUtils.enforceOffline`
/// is asserted before loading, so any code path that tried to reach the network
/// would throw instead — a passing transcription is proof of offline load.
@Suite("FluidAudioASR", .serialized, .enabled(if: bundledASRModelPresent,
       "bundled ASR model missing — run scripts/fetch-models.sh and rebuild"))
struct FluidAudioASRTests {

    private static let sampleRate = 16_000

    /// Fixture speech as 16 kHz mono Float32 (same loader as the VAD tests).
    private func fixtureSamples() throws -> [Float] {
        let bundle = Bundle(for: ASRFixtureLocator.self)
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

    @Test("Fixture WAV produces sane token events offline")
    func goldenTokenEvents() async throws {
        // The offline switch must hold for the whole load+transcribe path; with
        // it set, any download attempt in FluidAudio throws OfflineError.
        DownloadUtils.enforceOffline = true

        // ~12.6 s composite: enough audio that the 10 s confirmation context is
        // exceeded and real confirmed events (with per-token confidence) occur.
        let speech = try fixtureSamples()
        let gap = [Float](repeating: 0, count: Self.sampleRate / 2)
        var composite: [Float] = gap
        for _ in 0..<4 { composite += speech + gap }
        composite += [Float](repeating: 0, count: Self.sampleRate)

        let engine = FluidAudioASR()
        try await engine.prepare()

        let (audio, feeder) = AsyncStream.makeStream(of: [Float].self)
        let batchSize = 3210   // deliberately unaligned with any window size
        let feedTask = Task {
            for start in stride(from: 0, to: composite.count, by: batchSize) {
                feeder.yield(Array(composite[start ..< min(start + batchSize, composite.count)]))
            }
            feeder.finish()
        }

        struct Final {
            let text: String
            let confidence: Float
            let tokenConfidences: [Float]
        }
        var drafts: [(windowID: Int, text: String)] = []
        var finals: [Final] = []
        for await event in engine.transcribe(audio) {
            switch event {
            case let .draft(windowID, text): drafts.append((windowID, text))
            case let .finalized(text, confidence, tokenConfidences):
                finals.append(Final(
                    text: text, confidence: confidence, tokenConfidences: tokenConfidences
                ))
            }
        }
        feedTask.cancel()

        // Golden expectations, tolerant to window-seam nondeterminism AND to
        // Parakeet's inverse text normalization: the fixture says "testing one
        // two three four five", which the model legitimately renders as
        // "testing 12345". Accept spoken or numeric form.
        let transcript = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(transcript.contains("testing"), "transcript lost the lead word: \(transcript)")
        let digitForm = transcript.filter(\.isNumber).contains("12345")
        let wordHits = ["one", "two", "three", "four", "five"].filter(transcript.contains).count
        #expect(digitForm || wordHits >= 3,
                "transcript missed the counted numbers in either form: \(transcript)")

        // Confidence present and sane on finalized events.
        #expect(!finals.isEmpty)
        for final in finals {
            #expect(final.confidence > 0 && final.confidence <= 1.0)
            for tokenConfidence in final.tokenConfidences {
                #expect(tokenConfidence > 0 && tokenConfidence <= 1.0)
            }
        }
        // At least one mid-stream confirmation carried per-token confidence
        // (the finish() flush legitimately has none).
        #expect(finals.contains { !$0.tokenConfidences.isEmpty },
                "no confirmed event carried per-token confidence")

        // Draft windows only ever advance (draft-replaces-draft is per window).
        let windowIDs = drafts.map(\.windowID)
        #expect(windowIDs == windowIDs.sorted(), "draft windowIDs regressed")
    }
}
