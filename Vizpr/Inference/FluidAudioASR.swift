import Foundation
import FluidAudio

enum FluidAudioASRError: Error {
    case bundledModelMissing(String)
    case offlineModeNotAsserted
}

/// Parakeet TDT v2 behind `TranscriptionEngine` (PLAN.md §5 + PR 4).
///
/// The model ships in the app bundle and loads via `AsrModels.load(from:)` — a
/// pure filesystem path. Belt and braces, `prepare()` refuses to run unless
/// FluidAudio's global offline switch is already engaged, so even a future
/// misuse of a downloading API would throw instead of reaching the network
/// (invariant 1: fail loudly if the offline guarantee cannot be confirmed).
///
/// The engine owns its windows and decodes with FluidAudio's batch `AsrManager`
/// only. One decode task per session runs three kinds of decode, one at a time:
///
/// - A *window* confirms audio as final text. It closes at each pause the
///   input reports (`AudioInput.pause`), or on a clock when speech runs 12 s
///   without one. The decode starts 2 s before the window, and `TimedCut`
///   keeps only the words that start inside it, so no decode repeats another's
///   words and nothing has to be matched by text. A forced window is cut at the
///   widest gap between words near 10 s.
/// - A *draft* re-decodes the unconfirmed tail with no context and publishes
///   it as tentative text, as fast as the decoder sustains.
/// - The *commit* decode runs once when the input ends: the unconfirmed tail,
///   with left context, cut at the boundary, becomes the last final. A tail
///   the user proofread as a draft is therefore decoded by the same decoder
///   that produced it.
///
/// Planning (what to decode and when) lives in `WindowTracker`; the cut lives
/// in `TimedCut`. AudioPipeline runs one session at a time, but a new
/// transcribe() can begin while the previous one is still finishing;
/// `sessionCounter` lets the finishing task's calls into this actor detect that
/// and do nothing. This state is reset in beginSession().
actor FluidAudioASR: TranscriptionEngine {

    private let modelsDirectory: URL
    /// One long-lived batch decoder, reused across sessions (the expensive part:
    /// ~443 MB and seconds of load time). Stateless per call (a fresh
    /// TdtDecoderState each decode), so a new session needs no new manager.
    private var batchManager: AsrManager?
    private var tracker = WindowTracker()
    private var sessionBuffer: [Float] = []
    private var bufferStartSample = 0
    /// Windows confirmed this session, including ones that kept no word.
    /// Drafts carry it as their window id, so a draft after a confirm never
    /// carries an id TokenStream has already passed.
    private var windowsProcessed = 0
    private var lastDraftText = ""
    /// True while new decodes may be planned. Closed (under actor
    /// serialization) when the input ends, so no draft can be yielded after
    /// the commit final and the commit decode covers whatever a pending window
    /// would have.
    private var decodingOpen = false
    private var sessionCounter = 0

    /// Live setting (PR 11): min audio before the first draft decode —
    /// Mauria's "first draft faster?" lever. Applies from the next session.
    private var draftMinTailSamples = 24_000

    func setDraftMinTail(milliseconds: Int) {
        draftMinTailSamples = max(1, milliseconds) * 16   // 16 kHz
    }

    /// Starts a session and returns its identity. Every later actor call from
    /// that session's task passes it back and is ignored once another session
    /// has begun.
    private func beginSession() -> Int {
        sessionCounter += 1
        tracker = WindowTracker(minTailSamples: draftMinTailSamples)
        sessionBuffer.removeAll(keepingCapacity: true)
        bufferStartSample = 0
        windowsProcessed = 0
        lastDraftText = ""
        decodingOpen = true
        return sessionCounter
    }

    private func closeDecoding(session: Int) {
        guard session == sessionCounter else { return }
        decodingOpen = false
    }

    /// The next decode the session's decode task should run.
    private enum Work {
        case window(WindowTracker.WindowPlan, samples: [Float])
        case draft(samples: [Float], windowID: Int)
    }

    /// Ingest session audio. Buffer bookkeeping only; never decodes.
    private func ingest(_ samples: [Float], session: Int) {
        guard session == sessionCounter else { return }
        sessionBuffer.append(contentsOf: samples)
        tracker.append(sampleCount: samples.count)
        trimBuffer()
    }

    private func notePause(session: Int) {
        guard session == sessionCounter else { return }
        tracker.notePause()
    }

    /// A window if one is due, else a draft pass if one is due, or nil. Slices
    /// are copied here, inside the actor call, so later trims cannot
    /// invalidate them.
    private func takeWork(session: Int) -> Work? {
        guard session == sessionCounter, decodingOpen else { return nil }
        if let plan = tracker.takeConfirmPlan(), let samples = slice(plan.range) {
            return .window(plan, samples: samples)
        }
        guard let request = tracker.takeDecodeRequest() else { return nil }
        // Decode from the unconfirmed boundary (not the left-context start):
        // including confirmed audio would re-transcribe already-final text into
        // the draft. The cost is slightly weaker acoustics on the first word
        // after a confirmation — acceptable for display-only drafts.
        let range = max(request.draftStart, request.range.lowerBound) ..< request.range.upperBound
        guard let samples = slice(range) else { return nil }
        return .draft(samples: samples, windowID: windowsProcessed)
    }

    /// The session audio at an absolute range, or nil when the buffer no longer
    /// (or does not yet) holds it.
    private func slice(_ range: Range<Int>) -> [Float]? {
        let start = range.lowerBound - bufferStartSample
        let end = range.upperBound - bufferStartSample
        guard start >= 0, end <= sessionBuffer.count, start < end else { return nil }
        return Array(sessionBuffer[start ..< end])
    }

    /// Publish a tail draft unless drafts are closed or the text repeats the
    /// last one. Yields inside the actor so that `closeDecoding()` strictly
    /// orders against it.
    private func emitTailDraft(
        _ text: String, windowID: Int, session: Int,
        to continuation: AsyncStream<TokenEvent>.Continuation
    ) {
        guard session == sessionCounter, decodingOpen, shouldEmitDraft(text) else { return }
        continuation.yield(.draft(windowID: windowID, text: text))
    }

    private func trimBuffer() {
        let reclaimable = tracker.reclaimableSamples - bufferStartSample
        if reclaimable > 0, reclaimable <= sessionBuffer.count {
            sessionBuffer.removeFirst(reclaimable)
            bufferStartSample += reclaimable
        }
    }

    /// Deduplicate consecutive identical drafts (silence produces repeats).
    private func shouldEmitDraft(_ text: String) -> Bool {
        guard text != lastDraftText else { return false }
        lastDraftText = text
        return true
    }

    /// Stateless batch decode of `samples`. Errors are swallowed — a failed
    /// draft pass costs one refresh, a failed window leaves its audio to the
    /// next window, and a failed commit decode falls back to the last draft
    /// the user already saw.
    private func decode(_ samples: [Float]) async -> ASRResult? {
        guard let batchManager else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: await batchManager.decoderLayerCount)
            return try await batchManager.transcribe(samples, decoderState: &state)
        } catch {
            return nil
        }
    }

    /// Emit a window's cut as a final and move the confirmed boundary. Runs as
    /// one actor call so the final and the new boundary are never seen apart.
    /// A forced window is cut at the widest gap between words near its end,
    /// and its boundary moves to the end of the last word it kept, so a word it
    /// left out at its edge is decoded whole by the next window. A pause
    /// window confirms through the pause: the silence between its last word
    /// and the pause was heard and yielded nothing, and leaving it unconfirmed
    /// would make the commit decode run over context plus silence. A window
    /// that kept no word confirms through its end, or a forced window would
    /// plan again on every wake. A failed decode confirms nothing and emits
    /// nothing: the audio stays in the tail, and the caller retries the window
    /// on the next wake (a pause is consumed, so its audio goes to the next
    /// window or the commit decode instead).
    /// - Returns: whether the boundary moved.
    @discardableResult
    private func finishWindow(
        _ plan: WindowTracker.WindowPlan, result: ASRResult?, decodeMs: Int?, session: Int,
        to continuation: AsyncStream<TokenEvent>.Continuation
    ) -> Bool {
        guard session == sessionCounter else { return false }
        let decodeStart = plan.range.lowerBound
        var cutEnd = plan.cutEnd
        if plan.kind == .forced, let result {
            let point = TimedCut.forcedCutPoint(
                result: result, decodeStart: decodeStart, cutStart: plan.cutStart
            )
            cutEnd = min(max(point, plan.cutStart), plan.range.upperBound)
        }

        var confirmedThrough: Int?
        if let result {
            confirmedThrough = cutEnd
            let cut = TimedCut.cut(
                result: result, decodeStart: decodeStart, cutStart: plan.cutStart, cutEnd: cutEnd,
                startTolerance: plan.startTolerance
            )
            if let keptEnd = cut.keptEnd, !cut.text.isEmpty {
                continuation.yield(.finalized(
                    text: cut.text, confidence: cut.confidence, tokenConfidences: cut.tokenConfidences
                ))
                if plan.kind == .forced {
                    confirmedThrough = min(decodeStart + keptEnd, cutEnd)
                }
            }
        }

        #if DICT_DEV_LOG
        let kind = plan.kind == .forced ? "forced" : "pause"
        let cutSamples = cutEnd - plan.cutStart
        let decoded = decodeMs.map { "decoded \($0) ms" } ?? "decode failed"
        VizprTranscriptLogger.note("window: \(kind), \(decoded), cut \(cutSamples) samples")
        #endif

        guard let confirmedThrough else { return false }
        windowsProcessed += 1
        lastDraftText = ""
        tracker.confirm(through: confirmedThrough, atPause: plan.kind == .pause)
        trimBuffer()
        return true
    }

    /// The decode plan for the commit-time tail, or nil when nothing is
    /// unconfirmed or the session has moved.
    private func takeCommitPlan(session: Int) -> (plan: WindowTracker.WindowPlan, samples: [Float])? {
        guard session == sessionCounter, let plan = tracker.commitPlan(),
              let samples = slice(plan.range) else { return nil }
        return (plan, samples)
    }

    /// - Parameter modelsDirectory: directory holding the v2 `.mlmodelc` set.
    ///   Defaults to the bundled copy at Resources/Models/parakeet-tdt-0.6b-v2.
    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory
            ?? Bundle.main.resourceURL!.appendingPathComponent("Models/parakeet-tdt-0.6b-v2")
    }

    /// Single-flight load. Actor reentrancy makes a plain `guard models == nil`
    /// racy: the launch warm and an eager first dictation can both pass the
    /// guard and load the ~443 MB model set twice. Every caller awaits the one
    /// shared task instead. A failed load stays cached — prepare failure means
    /// a broken bundle, and the app fails loudly rather than retrying.
    private var prepareTask: Task<Void, any Error>?

    func prepare() async throws {
        if prepareTask == nil {
            prepareTask = Task { try await performPrepare() }
        }
        try await prepareTask!.value
    }

    private func performPrepare() async throws {
        // The offline switch must be thrown before any FluidAudio model API is
        // touched (AppDelegate does it at launch); refusing to proceed without
        // it makes the no-download guarantee a checked precondition, not a hope.
        guard DownloadUtils.enforceOffline else {
            throw FluidAudioASRError.offlineModeNotAsserted
        }
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            throw FluidAudioASRError.bundledModelMissing(modelsDirectory.path)
        }

        // encoderPrecision only affects v3 file naming; v2 uses its fixed
        // Encoder.mlmodelc regardless, so the default is fine.
        let loaded = try await AsrModels.load(
            from: modelsDirectory,
            version: .v2
        )

        // Default ASRConfig: loadModels auto-adapts the blank token to the
        // loaded model version.
        let batch = AsrManager(config: .default)
        try await batch.loadModels(loaded)
        batchManager = batch
    }

    /// nonisolated: builds the event stream synchronously (satisfying the
    /// protocol's sync shape); all actor state is reached with await inside the
    /// stream's task.
    nonisolated func transcribe(_ audio: AsyncStream<AudioInput>) -> AsyncStream<TokenEvent> {
        AsyncStream { continuation in
            let task = Task {
                // Awaits the (single-flight) model load, so a dictation begun
                // before the launch warm finishes blocks briefly instead of
                // producing an empty session.
                guard (try? await self.prepare()) != nil else {
                    continuation.finish()
                    return
                }
                let session = await self.beginSession()

                // Decode task: runs the next due decode whenever woken,
                // independent of audio ingestion. Wakes that arrive during a
                // decode coalesce into one, so a decode starts as soon as the
                // previous finishes and the floor of new audio has arrived
                // (takeWork returns nil until then).
                let (wakeups, wake) = AsyncStream.makeStream(
                    of: Void.self, bufferingPolicy: .bufferingNewest(1)
                )
                let decodeTask = self.startDecodeTask(
                    wakeups: wakeups, session: session, continuation: continuation
                )
                defer {
                    wake.finish()
                    decodeTask.cancel()
                }

                do {
                    for await input in audio {
                        try Task.checkCancellation()
                        switch input {
                        case let .samples(samples):
                            await self.ingest(samples, session: session)
                        case .pause:
                            await self.notePause(session: session)
                        }
                        wake.yield()
                    }

                    // Input ended (commit/cancel upstream). Stop planning, then
                    // wait for the decode already running: FluidAudio checks
                    // cancellation only between model stages, so cancelling
                    // would not stop it, and waiting guarantees no draft lands
                    // after the commit final and every confirmed window has
                    // moved the boundary. It costs at most one decode.
                    wake.finish()
                    await self.closeDecoding(session: session)
                    await decodeTask.value

                    // The tail's final text is one more decode over everything
                    // past the boundary, with left context.
                    if let (plan, samples) = await self.takeCommitPlan(session: session) {
                        #if DICT_DEV_LOG
                        let started = ContinuousClock.now
                        #endif
                        let result = await self.decode(samples)
                        let cut = result.map {
                            TimedCut.cut(
                                result: $0, decodeStart: plan.range.lowerBound,
                                cutStart: plan.cutStart, cutEnd: plan.cutEnd,
                                startTolerance: plan.startTolerance
                            )
                        }
                        #if DICT_DEV_LOG
                        let outcome = cut?.text.isEmpty == false ? "decoded" : "empty"
                        VizprTranscriptLogger.note(
                            "commit tail: \(outcome) \(Self.milliseconds(since: started)) ms over \(samples.count) samples"
                        )
                        #endif
                        if let cut, !cut.text.isEmpty {
                            continuation.yield(.finalized(
                                text: cut.text, confidence: cut.confidence,
                                tokenConfidences: cut.tokenConfidences
                            ))
                        }
                    } else {
                        #if DICT_DEV_LOG
                        VizprTranscriptLogger.note("commit tail: nothing to decode")
                        #endif
                    }
                } catch {
                    // Cancelled: nothing is committed.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the due decodes per wake: windows until none is due (each confirm
    /// moves the draft tail, so the next plan is taken at once), then one draft.
    private nonisolated func startDecodeTask(
        wakeups: AsyncStream<Void>, session: Int,
        continuation: AsyncStream<TokenEvent>.Continuation
    ) -> Task<Void, Never> {
        Task {
            for await _ in wakeups {
                drain: while let work = await self.takeWork(session: session) {
                    switch work {
                    case let .window(plan, samples):
                        #if DICT_DEV_LOG
                        let started = ContinuousClock.now
                        #endif
                        let result = await self.decode(samples)
                        #if DICT_DEV_LOG
                        let decodeMs: Int? = result == nil ? nil : Self.milliseconds(since: started)
                        #else
                        let decodeMs: Int? = nil
                        #endif
                        let confirmed = await self.finishWindow(
                            plan, result: result, decodeMs: decodeMs, session: session, to: continuation
                        )
                        if !confirmed { break drain }
                    case let .draft(samples, windowID):
                        if let result = await self.decode(samples) {
                            await self.emitTailDraft(
                                result.text, windowID: windowID, session: session, to: continuation
                            )
                        }
                    }
                    if case .draft = work { break drain }
                }
            }
        }
    }

    #if DICT_DEV_LOG
    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let parts = (ContinuousClock.now - start).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
    #endif
}
