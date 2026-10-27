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

    private struct Final {
        let text: String
        let confidence: Float
        let tokenConfidences: [Float]
    }

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

        let (audio, feeder) = AsyncStream.makeStream(of: AudioInput.self)
        let batchSize = 3210   // deliberately unaligned with any window size
        let feedTask = Task {
            for start in stride(from: 0, to: composite.count, by: batchSize) {
                feeder.yield(.samples(Array(composite[start ..< min(start + batchSize, composite.count)]), soft: false))
                // Drafts decode concurrently with ingestion and stop at end of
                // input, so feed at a pace that gives the draft task time to
                // run, as live capture does.
                try? await Task.sleep(for: .milliseconds(40))
            }
            feeder.finish()
        }

        var drafts: [(windowID: Int, text: String)] = []
        var finals: [Final] = []
        var draftPrecededFinal = false
        for await event in engine.transcribe(audio) {
            switch event {
            case let .draft(windowID, text):
                drafts.append((windowID, text))
                if finals.isEmpty { draftPrecededFinal = true }
            case let .finalized(text, confidence, tokenConfidences):
                finals.append(Final(
                    text: text, confidence: confidence, tokenConfidences: tokenConfidences
                ))
            }
        }
        feedTask.cancel()

        // The draft track (PR 4.5): live drafts must exist and must arrive
        // before the first ~12s confirmation — this was the field-measured
        // "no text for 12 seconds" gap.
        #expect(!drafts.isEmpty, "draft track produced no drafts")
        #expect(draftPrecededFinal, "no draft arrived before the first confirmation")

        assertGoldenExpectations(finals: finals, drafts: drafts)
    }

    @Test("A second session on the same engine still transcribes")
    func secondSessionStillTranscribes() async throws {
        // Field regression from when the engine used FluidAudio's single-use
        // sliding-window manager: a reused manager made every session after
        // the first a silent no-op. The engine must produce events for BOTH
        // sequential sessions.
        DownloadUtils.enforceOffline = true
        let speech = try fixtureSamples()
        let gap = [Float](repeating: 0, count: Self.sampleRate / 2)
        var composite: [Float] = gap
        for _ in 0..<4 { composite += speech + gap }
        composite += [Float](repeating: 0, count: Self.sampleRate)

        let engine = FluidAudioASR()
        try await engine.prepare()

        for session in 1...2 {
            let (audio, feeder) = AsyncStream.makeStream(of: AudioInput.self)
            let feedTask = Task {
                for start in stride(from: 0, to: composite.count, by: 4000) {
                    feeder.yield(.samples(Array(composite[start ..< min(start + 4000, composite.count)]), soft: false))
                }
                feeder.finish()
            }
            var sawFinal = false
            for await event in engine.transcribe(audio) {
                if case let .finalized(text, _, _) = event, !text.isEmpty { sawFinal = true }
            }
            feedTask.cancel()
            #expect(sawFinal, "session \(session) produced no finalized events")
        }
    }

    @Test("A session begun before prepare() still transcribes")
    func sessionBeforePrepareStillTranscribes() async throws {
        // Dictation is not gated on the launch warm: transcribe() awaits the
        // single-flight prepare internally, so a session started on a cold
        // engine blocks for the model load instead of finishing empty.
        DownloadUtils.enforceOffline = true
        let speech = try fixtureSamples()
        let gap = [Float](repeating: 0, count: Self.sampleRate / 2)
        var composite: [Float] = gap
        for _ in 0..<4 { composite += speech + gap }
        composite += [Float](repeating: 0, count: Self.sampleRate)

        let engine = FluidAudioASR()
        // No prepare() call: the session itself must trigger and await the load.

        let (audio, feeder) = AsyncStream.makeStream(of: AudioInput.self)
        let feedTask = Task {
            for start in stride(from: 0, to: composite.count, by: 4000) {
                feeder.yield(.samples(Array(composite[start ..< min(start + 4000, composite.count)]), soft: false))
            }
            feeder.finish()
        }
        var sawFinal = false
        for await event in engine.transcribe(audio) {
            if case let .finalized(text, _, _) = event, !text.isEmpty { sawFinal = true }
        }
        feedTask.cancel()
        #expect(sawFinal, "cold-engine session produced no finalized events")
    }

    /// Events from one engine stream, each tagged with whether the session's
    /// audio input had already ended when it arrived.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(event: TokenEvent, afterInputEnded: Bool)] = []
        private var inputEnded = false

        func markInputEnded() { lock.withLock { inputEnded = true } }
        func record(_ event: TokenEvent) {
            lock.withLock { entries.append((event, inputEnded)) }
        }
        var all: [(event: TokenEvent, afterInputEnded: Bool)] { lock.withLock { entries } }
        var afterInputEnded: [TokenEvent] { all.filter(\.afterInputEnded).map(\.event) }
    }

    /// What the draft decoder produces for `samples` directly, bypassing the engine.
    private func directDecode(_ samples: [Float]) async throws -> String {
        let directory = try #require(Bundle.main.resourceURL?
            .appendingPathComponent("Models/parakeet-tdt-0.6b-v2"))
        let models = try await AsrModels.load(from: directory, version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    @Test("A short session's committed tail is the draft decoder's output, with no draft after input ends")
    func shortSessionTailIsDraftDecode() async throws {
        DownloadUtils.enforceOffline = true
        let speech = try fixtureSamples()   // ~2.6 s: under the 10 s confirmation context

        let engine = FluidAudioASR()
        try await engine.prepare()

        let (audio, feeder) = AsyncStream.makeStream(of: AudioInput.self)
        let log = EventLog()
        let consumer = Task {
            for await event in engine.transcribe(audio) { log.record(event) }
        }
        for start in stride(from: 0, to: speech.count, by: 3200) {
            feeder.yield(.samples(Array(speech[start ..< min(start + 3200, speech.count)]), soft: false))
            try await Task.sleep(for: .milliseconds(40))
        }
        // Let the last draft decode finish, so what follows is the commit alone.
        try await Task.sleep(for: .milliseconds(1500))
        log.markInputEnded()
        feeder.finish()
        await consumer.value

        let after = log.afterInputEnded
        #expect(!after.contains { if case .draft = $0 { true } else { false } },
                "a draft arrived after the input ended: \(after)")
        let finals = after.compactMap { event -> String? in
            if case let .finalized(text, _, _) = event { text } else { nil }
        }
        #expect(finals.count == 1, "expected exactly one commit final, got \(finals)")
        #expect(finals.first == (try await directDecode(speech)),
                "the commit final is not the draft decoder's output for the same samples")
    }

    @Test("A session begun while the previous one finishes adds no event to the previous stream")
    func overlappingSessionDoesNotLeak() async throws {
        DownloadUtils.enforceOffline = true
        let speech = try fixtureSamples()

        let engine = FluidAudioASR()
        try await engine.prepare()

        let (firstAudio, firstFeeder) = AsyncStream.makeStream(of: AudioInput.self)
        let firstLog = EventLog()
        let firstConsumer = Task {
            for await event in engine.transcribe(firstAudio) { firstLog.record(event) }
        }
        firstFeeder.yield(.samples(speech, soft: false))
        try await Task.sleep(for: .milliseconds(1500))
        firstLog.markInputEnded()
        firstFeeder.finish()

        // The second session starts at once, while the first is still decoding
        // its tail, and keeps feeding audio the first must never read.
        let (secondAudio, secondFeeder) = AsyncStream.makeStream(of: AudioInput.self)
        let secondConsumer = Task { () -> Int in
            var finals = 0
            for await event in engine.transcribe(secondAudio) {
                if case .finalized = event { finals += 1 }
            }
            return finals
        }
        secondFeeder.yield(.samples(speech, soft: false))
        await firstConsumer.value

        let entries = firstLog.all
        let finalIndices = entries.indices.filter {
            if case .finalized = entries[$0].event { entries[$0].afterInputEnded } else { false }
        }
        #expect(finalIndices.count <= 1, "more than one commit final on the first stream")
        if let index = finalIndices.first {
            #expect(index == entries.count - 1, "an event followed the first stream's commit final")
        }
        #expect(!firstLog.afterInputEnded.contains { if case .draft = $0 { true } else { false } },
                "a draft reached the first stream after its input ended")

        secondFeeder.finish()
        let secondFinals = await secondConsumer.value
        #expect(secondFinals == 1, "the second session should still commit normally")
    }

    /// The fixture's utterance, `repeats` times, each followed by 0.75 s of
    /// silence (what the VAD waits for before reporting a pause) and, when
    /// `pauseMarks` is set, a pause mark, in 0.2 s batches.
    private func utterances(repeats: Int, pauseMarks: Bool) throws -> [AudioInput] {
        let speech = try fixtureSamples()
        let silence = [Float](repeating: 0, count: Self.sampleRate * 3 / 4)
        var inputs: [AudioInput] = []
        for _ in 0..<repeats {
            let audio = speech + silence
            for start in stride(from: 0, to: audio.count, by: 3200) {
                inputs.append(.samples(Array(audio[start ..< min(start + 3200, audio.count)]), soft: false))
            }
            if pauseMarks { inputs.append(.pause) }
        }
        return inputs
    }

    /// Runs a session over `inputs` at about five times real time, waits for
    /// the decodes in flight, ends the input, and returns the session's events.
    private func run(_ engine: FluidAudioASR, feeding inputs: [AudioInput]) async throws -> EventLog {
        let (audio, feeder) = AsyncStream.makeStream(of: AudioInput.self)
        let log = EventLog()
        let consumer = Task {
            for await event in engine.transcribe(audio) { log.record(event) }
        }
        for input in inputs {
            feeder.yield(input)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(1500))
        log.markInputEnded()
        feeder.finish()
        await consumer.value
        return log
    }

    private func finalTexts(_ events: [TokenEvent]) -> [String] {
        events.compactMap { if case let .finalized(text, _, _) = $0 { text } else { nil } }
    }

    /// How many times the fixture's lead word appears: one per utterance, so a
    /// count above the number of utterances means a window repeated words.
    private func leadWordCount(in texts: [String]) -> Int {
        texts.joined(separator: " ").lowercased().components(separatedBy: "testing").count - 1
    }

    /// The fixture speech at `gain` under seeded white noise of `noise`
    /// amplitude, as 0.2 s batches with a closing pause mark.
    private func degradedUtterance(gain: Float, noise: Float, soft: Bool) throws -> [AudioInput] {
        var generator = SeededGenerator(seed: 9)
        let mixed = try fixtureSamples().map {
            $0 * gain + Float.random(in: -noise ... noise, using: &generator)
        }
        let batches = stride(from: 0, to: mixed.count, by: 3200).map {
            AudioInput.samples(Array(mixed[$0 ..< min($0 + 3200, mixed.count)]), soft: soft)
        }
        return batches + [.pause]
    }

    @Test("Soft audio that decodes to a low-confidence hallucination yields no final and no draft text")
    func softHallucinationDropped() async throws {
        DownloadUtils.enforceOffline = true
        let engine = FluidAudioASR()
        try await engine.prepare()

        // Speech at 1% gain under noise decodes to invented words (confidence
        // 0.48 on the bundled model, 2026-10-27) when the gate let it in as
        // ordinary audio, so the soft case below drops real hallucination.
        let ordinary = try await run(engine, feeding: degradedUtterance(gain: 0.01, noise: 0.01, soft: false))
        #expect(!finalTexts(ordinary.all.map(\.event)).isEmpty, "the fixture no longer hallucinates unflagged")

        let soft = try await run(engine, feeding: degradedUtterance(gain: 0.01, noise: 0.01, soft: true))
        #expect(finalTexts(soft.all.map(\.event)).isEmpty, "a soft hallucination became a final")
        let lastDraft = soft.all.reversed().compactMap { entry -> String? in
            if case let .draft(_, text) = entry.event { text } else { nil }
        }.first
        #expect(lastDraft?.isEmpty ?? true, "a soft hallucination is left as a draft: \(lastDraft ?? "")")
    }

    @Test("Soft audio that decodes above the confidence bar keeps its text")
    func softSpeechAboveBarKept() async throws {
        DownloadUtils.enforceOffline = true
        let engine = FluidAudioASR()
        try await engine.prepare()
        let log = try await run(engine, feeding: degradedUtterance(gain: 0.05, noise: 0.02, soft: true))
        #expect(finalTexts(log.all.map(\.event)).joined(separator: " ").lowercased().contains("testing"))
    }

    @Test("Each pause closes one window, and no utterance's words reach two finals")
    func pausesCloseWindows() async throws {
        DownloadUtils.enforceOffline = true
        let engine = FluidAudioASR()
        try await engine.prepare()
        let log = try await run(engine, feeding: utterances(repeats: 3, pauseMarks: true))

        let beforeEnd = finalTexts(log.all.filter { !$0.afterInputEnded }.map(\.event))
        let afterEnd = finalTexts(log.afterInputEnded)
        #expect(beforeEnd.count == 3, "expected one final per pause before the input ended: \(beforeEnd)")
        #expect(leadWordCount(in: beforeEnd + afterEnd) == 3, "a window repeated words: \(beforeEnd + afterEnd)")
        // A pause window confirms through the pause, so nothing is left for a
        // commit decode over context plus silence.
        #expect(afterEnd.isEmpty, "the commit decode emitted after the last pause: \(afterEnd)")
    }

    @Test("Twelve seconds of speech without a pause yields a forced window before the input ends")
    func forcedWindowWithoutPause() async throws {
        DownloadUtils.enforceOffline = true
        let engine = FluidAudioASR()
        try await engine.prepare()
        // 5 x (1.8 s speech + 0.75 s silence) = 12.9 s with no pause mark.
        let log = try await run(engine, feeding: utterances(repeats: 5, pauseMarks: false))

        let beforeEnd = finalTexts(log.all.filter { !$0.afterInputEnded }.map(\.event))
        let afterEnd = finalTexts(log.afterInputEnded)
        #expect(beforeEnd.count == 1, "expected the forced window's final before the input ended: \(beforeEnd)")
        #expect(afterEnd.count == 1, "expected the commit decode to cover the rest: \(afterEnd)")
        #expect(leadWordCount(in: beforeEnd + afterEnd) == 5, "the forced cut repeated or lost words: \(beforeEnd + afterEnd)")
    }

    private func assertGoldenExpectations(finals: [Final], drafts: [(windowID: Int, text: String)]) {
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
        // At least one confirmation carried per-token confidence.
        #expect(finals.contains { !$0.tokenConfidences.isEmpty },
                "no confirmed event carried per-token confidence")

        // No duplicate-transcript event: the observed bug was finish()'s whole-
        // transcript return re-emitted after its pieces had already been
        // finalized. Signature: a later finalized event containing an earlier
        // finalized event's (nontrivial) text verbatim.
        for earlier in finals.indices {
            for later in finals.indices where later > earlier {
                let earlierText = finals[earlier].text
                guard earlierText.count > 15 else { continue }
                #expect(!finals[later].text.contains(earlierText),
                        "finalized event re-contains earlier finalized text — duplication")
            }
        }

        // Draft windows only ever advance (draft-replaces-draft is per window).
        let windowIDs = drafts.map(\.windowID)
        #expect(windowIDs == windowIDs.sorted(), "draft windowIDs regressed")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
