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

    /// Start a session: clears the previous one and anchors the timing marks.
    func begin(at instant: ContinuousClock.Instant) {
        reset()
        startedAt = instant
    }

    /// Record the first occurrence of a mark. Ignored before `begin`.
    func mark(_ mark: DevTimingMark, at instant: ContinuousClock.Instant) {
        guard startedAt != nil, marks[mark] == nil else { return }
        marks[mark] = instant
    }

    /// Observe one ASR event on its way into SmartCleanup.
    func observe(_ event: TokenEvent, at instant: ContinuousClock.Instant = .now) {
        switch event {
        case let .draft(_, text):
            trailingDraft = text
            draftArrivals.append(instant)
        case let .finalized(text, _, _):
            rawFinalized.append(text)
            trailingDraft = ""
        }
    }

    /// Discard the session's accumulation (session start, or cancel — a
    /// cancelled dictation injects nothing and gets no record).
    func reset() {
        rawFinalized.removeAll()
        trailingDraft = ""
        startedAt = nil
        marks.removeAll()
        draftArrivals.removeAll()
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
        defer { reset() }
        var parts = rawFinalized
        if !trailingDraft.isEmpty { parts.append(trailingDraft) }
        return DevDictationRecord(
            timestamp: timestamp,
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
