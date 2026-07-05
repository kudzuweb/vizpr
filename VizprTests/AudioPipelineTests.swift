import Testing
@testable import Vizpr

/// A capture source that hands the pipeline a pre-built stream.
private struct FakeCaptureSource: CaptureSource {
    let stream: AsyncStream<[Float]>
    @MainActor func start() async throws -> AsyncStream<[Float]> { stream }
    @MainActor func stop() {}
}

/// An engine that mimics the real flush shape: a draft while audio flows,
/// then — only after the input stream ends — a late finalized event.
private struct FlushingEngine: TranscriptionEngine {
    func prepare() async throws {}

    nonisolated func transcribe(_ audio: AsyncStream<[Float]>) -> AsyncStream<TokenEvent> {
        AsyncStream { continuation in
            let task = Task {
                var sawAudio = false
                for await _ in audio where !sawAudio {
                    sawAudio = true
                    continuation.yield(.draft(windowID: 0, text: "live draft"))
                }
                // Input ended (commit upstream): the flush final arrives late,
                // exactly like SlidingWindowAsrManager.finish().
                try? await Task.sleep(nanoseconds: 30_000_000)
                continuation.yield(.finalized(
                    text: "flush final.", confidence: 0.9, tokenConfidences: []
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Ordered record of pipeline callbacks.
private actor CallbackLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

@Suite("AudioPipeline")
struct AudioPipelineTests {

    /// The §14 drain contract: onSessionDrained fires strictly after every
    /// token event — including flush finals that arrive after the audio input
    /// ends — has been delivered to onTokenEvent. (Field regression: writing
    /// the dictation record at the commit action instead logged empty
    /// raw_asr_text for every short dictation.)
    @MainActor
    @Test("onSessionDrained fires after the flush finals are delivered")
    func drainedFiresAfterFlush() async throws {
        let (samples, feeder) = AsyncStream.makeStream(of: [Float].self)
        let log = CallbackLog()

        let pipeline = AudioPipeline(
            source: FakeCaptureSource(stream: samples),
            detector: SpeechDetector(model: try SpeechDetector.loadBundledModel()),
            engine: FlushingEngine(),
            onTokenEvent: { event in
                switch event {
                case let .draft(_, text): await log.add("draft:\(text)")
                case let .finalized(text, _, _): await log.add("final:\(text)")
                }
            },
            onSessionDrained: { epoch in await log.add("drained:\(epoch)") },
            onAutoStop: {}
        )

        pipeline.start(sessionEpoch: 7)
        feeder.yield([Float](repeating: 0, count: 4096))
        feeder.finish()

        // Wait for the drain (bounded).
        for _ in 0..<200 {
            if await log.entries.contains("drained:7") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let entries = await log.entries
        try #require(entries.contains("drained:7"), "session never drained (or epoch lost): \(entries)")
        #expect(entries.last == "drained:7", "drained was not the final callback: \(entries)")
        #expect(entries.contains("final:flush final."),
                "flush final missing before drain: \(entries)")
    }
}
