#if DICT_DEV_LOG
import Foundation

/// A session mark reported to the tracker for the PR 13 latency audit.
/// The first draft is not a mark: the tracker sees it through `observe`.
enum DevTimingMark: Sendable {
    case captureStarted, speechOnset, firstPreview, firstSettled, commit, injected
}

/// Accumulates the raw ASR text of the current session for the per-dictation
/// record (§14): `raw_asr_text` is the engine's raw output — before the vocab
/// pre-pass and cleanup — so the record captures exactly what the display
/// pipeline was given to improve on.
///
/// Raw mirrors the display's own shape: confirmed (finalized) spans plus the
/// trailing unconfirmed draft. The trailing draft is load-bearing, not a
/// nicety — a session that ends before its first pause or 12 s window has no
/// final until the commit decode, which can be dropped by the settle cap
/// (field-observed: every short dictation logged empty raw when only finals
/// were tracked). Each finalized span supersedes the drafts of the window it
/// confirms, so finals clear the trailing draft.
actor DevDictationTracker {
    private var rawFinalized: [String] = []
    private var trailingDraft = ""

    /// Session start (the startDictation action); nil until `begin`.
    private var startedAt: ContinuousClock.Instant?
    private var marks: [DevTimingMark: ContinuousClock.Instant] = [:]
    private var draftArrivals: [ContinuousClock.Instant] = []

    private var sessionID: String?
    /// Every final delivered this session with the window kind the engine
    /// reported for it (nil from an engine that reports none).
    private var finalDeliveries: [(at: ContinuousClock.Instant, windowKind: String?)] = []
    private var cleanupDoneAt: ContinuousClock.Instant?
    private var capturedSamples: Int?

    /// The last few sessions' ids and start instants. A cleanup that resolves
    /// after its session drained (a cancel at commit) still finds its id here.
    /// Survives `reset`.
    private var recentSessions: [(id: String, startedAt: ContinuousClock.Instant)] = []
    private static let recentSessionLimit = 4

    /// Start a session: clears the previous one and anchors the timing marks.
    func begin(at instant: ContinuousClock.Instant, sessionID: String? = nil) {
        reset()
        startedAt = instant
        self.sessionID = sessionID
        if let sessionID {
            recentSessions.append((sessionID, instant))
            if recentSessions.count > Self.recentSessionLimit { recentSessions.removeFirst() }
        }
    }

    /// Record the first occurrence of a mark. Ignored before `begin`.
    func mark(_ mark: DevTimingMark, at instant: ContinuousClock.Instant) {
        guard startedAt != nil, marks[mark] == nil else { return }
        marks[mark] = instant
    }

    /// Observe one ASR event on its way into SmartCleanup.
    /// - Parameter windowKind: the kind of window behind a final; when nil the
    ///   next kind the engine pushed to `DevFinalWindowKinds` is used.
    func observe(
        _ event: TokenEvent, at instant: ContinuousClock.Instant = .now, windowKind: String? = nil
    ) {
        switch event {
        case let .draft(_, text):
            trailingDraft = text
            draftArrivals.append(instant)
        case let .finalized(text, _, _):
            rawFinalized.append(text)
            trailingDraft = ""
            finalDeliveries.append((instant, windowKind ?? DevFinalWindowKinds.pop()))
        }
    }

    /// The capture loop's total sample count for the session, reported when
    /// the loop ends.
    func noteCapturedSamples(_ count: Int) {
        guard startedAt != nil else { return }
        capturedSamples = count
    }

    /// Place a resolved cleanup in its session. A cleanup belongs to the
    /// latest session that had started when it was queued. Resolving inside
    /// the open session also moves the session's `t_cleanup_done_ms`.
    func noteCleanupResolved(
        enqueuedAt: ContinuousClock.Instant?,
        startedAt cleanupStartedAt: ContinuousClock.Instant?,
        resolvedAt: ContinuousClock.Instant
    ) -> DevCleanupTiming {
        let owner: (id: String, startedAt: ContinuousClock.Instant)?
        if let enqueuedAt {
            owner = recentSessions.last { $0.startedAt <= enqueuedAt }
        } else {
            owner = recentSessions.last
        }
        guard let owner else { return .none }
        if owner.id == sessionID, startedAt != nil {
            cleanupDoneAt = resolvedAt
        }
        func ms(_ instant: ContinuousClock.Instant?) -> Int? {
            instant.map { milliseconds(from: owner.startedAt, to: $0) }
        }
        return DevCleanupTiming(
            sessionID: owner.id, enqueuedMs: ms(enqueuedAt), startedMs: ms(cleanupStartedAt)
        )
    }

    /// Discard the session's accumulation (session start, or cancel — a
    /// cancelled dictation injects nothing and gets no record).
    func reset() {
        rawFinalized.removeAll()
        trailingDraft = ""
        startedAt = nil
        marks.removeAll()
        draftArrivals.removeAll()
        sessionID = nil
        finalDeliveries.removeAll()
        cleanupDoneAt = nil
        capturedSamples = nil
        DevFinalWindowKinds.clear()
    }

    private func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let parts = (end - start).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private func timings() -> DevSessionTimings {
        guard let start = startedAt else { return .none }
        func ms(_ instant: ContinuousClock.Instant?) -> Int? {
            instant.map { milliseconds(from: start, to: $0) }
        }
        var result = DevSessionTimings()
        result.captureMs = ms(marks[.captureStarted])
        result.speechOnsetMs = ms(marks[.speechOnset])
        result.firstDraftMs = ms(draftArrivals.first)
        result.firstPreviewMs = ms(marks[.firstPreview])
        result.firstSettledMs = ms(marks[.firstSettled])
        result.commitMs = ms(marks[.commit])
        result.injectedMs = ms(marks[.injected])
        result.finalASRMs = ms(finalDeliveries.last?.at)
        result.cleanupDoneMs = ms(cleanupDoneAt)
        result.audioMs = capturedSamples.map {
            Int(Double($0) * 1000 / MicrophoneCapture.sampleRate)
        }
        if let settledAt = marks[.firstSettled] {
            result.firstSettledWindow = finalDeliveries.last { $0.at <= settledAt }?.windowKind
        }
        result.draftCount = draftArrivals.count
        if draftArrivals.count >= 2 {
            let gaps = zip(draftArrivals, draftArrivals.dropFirst())
                .map { milliseconds(from: $0, to: $1) }
            result.draftIntervalMeanMs = gaps.reduce(0, +) / gaps.count
            result.draftIntervalMaxMs = gaps.max()
        }
        return result
    }

    /// Build the dictation record at session drain and reset for the next one.
    func makeRecord(
        injectedText: String,
        surroundingText: String? = nil,
        bundleID: String?,
        mode: String,
        modelTier: String,
        timestamp: String = Date().ISO8601Format()
    ) -> DevDictationRecord {
        let sessionID = self.sessionID
        defer { reset() }
        var parts = rawFinalized
        if !trailingDraft.isEmpty { parts.append(trailingDraft) }
        return DevDictationRecord(
            timestamp: timestamp,
            sessionID: sessionID,
            rawASRText: parts.joined(separator: " "),
            injectedText: injectedText,
            context: DevDictationContext(
                surroundingText: surroundingText, bundleID: bundleID, mode: mode
            ),
            modelTier: modelTier,
            timings: timings()
        )
    }
}
#endif
