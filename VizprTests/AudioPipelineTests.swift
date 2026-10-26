import Testing
@testable import Vizpr

/// A capture source that hands the pipeline a pre-built stream.
private struct FakeCaptureSource: CaptureSource {
    let stream: AsyncStream<[Float]>
    func start() async throws -> AsyncStream<[Float]> { stream }
    func stop() {}
}

/// A capture source whose engine cannot start.
private struct FailingCaptureSource: CaptureSource {
    func start() async throws -> AsyncStream<[Float]> { throw AudioCaptureError.cannotConfigureInput }
    func stop() {}
}

/// A source whose route has delivered only silence, so the pipeline attempts
/// the built-in failover; the failover returns `result`.
private struct SilentRouteSource: FailoverCapableSource {
    let stream: AsyncStream<[Float]>
    let result: FailoverResult
    var routeEvidence: RouteEvidence {
        RouteEvidence(
            measuredFrames: 96_000, hardwareSampleRate: 48_000, rawPeak: 0, route: .external
        )
    }
    func start() async throws -> AsyncStream<[Float]> { stream }
    func stop() {}
    func fallBackToBuiltInMic() async -> FailoverResult { result }
}

/// Records onCaptureFailure calls on the main actor.
@MainActor
private final class FailureLog {
    private(set) var calls: [Void] = []
    func record() { calls.append(()) }
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

    @MainActor
    @Test("onCaptureFailure fires once when the source cannot start")
    func captureFailureReported() async throws {
        let failures = FailureLog()
        let drained = CallbackLog()
        let pipeline = AudioPipeline(
            source: FailingCaptureSource(),
            detector: SpeechDetector(model: try SpeechDetector.loadBundledModel()),
            onSessionDrained: { epoch in await drained.add("drained:\(epoch)") },
            onAutoStop: {}
        )
        pipeline.onCaptureFailure = { failures.record() }

        pipeline.start(sessionEpoch: 1)
        for _ in 0..<200 {
            if await drained.entries.contains("drained:1") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(failures.calls.count == 1)
    }

    @MainActor
    @Test("onCaptureFailure stays quiet when the stream ends normally")
    func noCaptureFailureOnNormalEnd() async throws {
        let (samples, feeder) = AsyncStream.makeStream(of: [Float].self)
        let failures = FailureLog()
        let drained = CallbackLog()
        let pipeline = AudioPipeline(
            source: FakeCaptureSource(stream: samples),
            detector: SpeechDetector(model: try SpeechDetector.loadBundledModel()),
            onSessionDrained: { epoch in await drained.add("drained:\(epoch)") },
            onAutoStop: {}
        )
        pipeline.onCaptureFailure = { failures.record() }

        pipeline.start(sessionEpoch: 2)
        feeder.finish()
        for _ in 0..<200 {
            if await drained.entries.contains("drained:2") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        try #require(await drained.entries.contains("drained:2"))
        #expect(failures.calls.isEmpty)
    }

    @MainActor
    private func captureFailures(whenFailoverReturns result: FailoverResult) async throws -> Int {
        let (samples, feeder) = AsyncStream.makeStream(of: [Float].self)
        let failures = FailureLog()
        let drained = CallbackLog()
        let pipeline = AudioPipeline(
            source: SilentRouteSource(stream: samples, result: result),
            detector: SpeechDetector(model: try SpeechDetector.loadBundledModel()),
            onSessionDrained: { epoch in await drained.add("drained:\(epoch)") },
            onAutoStop: {}
        )
        pipeline.onCaptureFailure = { failures.record() }

        pipeline.start(sessionEpoch: 3)
        feeder.yield([Float](repeating: 0, count: 4096))
        feeder.finish()
        for _ in 0..<200 {
            if await drained.entries.contains("drained:3") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(await drained.entries.contains("drained:3"))
        return failures.calls.count
    }

    @MainActor
    @Test("a failover that loses capture fires onCaptureFailure")
    func failoverLostReportsFailure() async throws {
        #expect(try await captureFailures(whenFailoverReturns: .lost) == 1)
    }

    @MainActor
    @Test("a failover that switches or changes nothing does not fire onCaptureFailure")
    func failoverSurvivedIsNotAFailure() async throws {
        #expect(try await captureFailures(whenFailoverReturns: .switched) == 0)
        #expect(try await captureFailures(whenFailoverReturns: .unchanged) == 0)
    }
}
