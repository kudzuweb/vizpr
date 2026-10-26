#if DICT_DEV_LOG
import Foundation

/// The §14 JSONL record shapes. Both kinds share one file (one JSON object per
/// line, discriminated by `type`) and must stay parseable with
/// `pandas.read_json(lines=True)` — flat snake_case keys, no nesting beyond
/// the spec'd `context` object, newlines confined to JSON string escapes.

/// One dictation, written at commit: the raw ASR text as the engine finalized
/// it (pre-vocab, pre-cleanup) against exactly what was injected.
struct DevDictationRecord: Encodable, Sendable {
    let type = "dictation"
    let timestamp: String
    /// Joins this record to its cleanup records and `[s:<id>]` log lines.
    var sessionID: String?
    let rawASRText: String
    let injectedText: String
    let context: DevDictationContext
    let modelTier: String
    let timings: DevSessionTimings

    enum CodingKeys: String, CodingKey {
        case type, timestamp, context
        case sessionID = "session_id"
        case rawASRText = "raw_asr_text"
        case injectedText = "injected_text"
        case modelTier = "model_tier"
    }

    /// Hand-written so the timing keys sit flat beside the others, and so an
    /// unreached mark encodes as `null` (synthesized `Encodable` would omit
    /// the key and give the rows different columns).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(rawASRText, forKey: .rawASRText)
        try container.encode(injectedText, forKey: .injectedText)
        try container.encode(context, forKey: .context)
        try container.encode(modelTier, forKey: .modelTier)
        try timings.encode(to: encoder)
    }
}

/// Session latency marks for the PR 13 audit. Each `t_*` value is milliseconds
/// since the startDictation action was received; nil when the mark never
/// happened. The draft statistics describe the gaps between consecutive
/// `.draft` arrivals.
struct DevSessionTimings: Sendable {
    var captureMs: Int?
    var speechOnsetMs: Int?
    var firstDraftMs: Int?
    var firstPreviewMs: Int?
    var firstSettledMs: Int?
    var commitMs: Int?
    var injectedMs: Int?
    /// The last finalized token event delivered, whether the tail decode's or
    /// the last window's.
    var finalASRMs: Int?
    /// The last cleanup of the session to resolve (applied, stale, cancelled
    /// or failed) before the session drained.
    var cleanupDoneMs: Int?
    /// Captured audio length, from the capture loop's sample count.
    var audioMs: Int?
    /// Kind (`pause`, `forced` or `commit`) of the last final delivered at or
    /// before the first settled text appeared.
    var firstSettledWindow: String?
    var draftCount = 0
    var draftIntervalMeanMs: Int?
    var draftIntervalMaxMs: Int?

    static let none = DevSessionTimings()
}

extension DevSessionTimings: Encodable {
    enum CodingKeys: String, CodingKey {
        case captureMs = "t_capture_ms"
        case speechOnsetMs = "t_speech_onset_ms"
        case firstDraftMs = "t_first_draft_ms"
        case firstPreviewMs = "t_first_preview_ms"
        case firstSettledMs = "t_first_settled_ms"
        case commitMs = "t_commit_ms"
        case injectedMs = "t_injected_ms"
        case finalASRMs = "t_final_asr_ms"
        case cleanupDoneMs = "t_cleanup_done_ms"
        case audioMs = "audio_ms"
        case firstSettledWindow = "first_settled_window"
        case draftCount = "draft_count"
        case draftIntervalMeanMs = "draft_interval_mean_ms"
        case draftIntervalMaxMs = "draft_interval_max_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureMs, forKey: .captureMs)
        try container.encode(speechOnsetMs, forKey: .speechOnsetMs)
        try container.encode(firstDraftMs, forKey: .firstDraftMs)
        try container.encode(firstPreviewMs, forKey: .firstPreviewMs)
        try container.encode(firstSettledMs, forKey: .firstSettledMs)
        try container.encode(commitMs, forKey: .commitMs)
        try container.encode(injectedMs, forKey: .injectedMs)
        try container.encode(finalASRMs, forKey: .finalASRMs)
        try container.encode(cleanupDoneMs, forKey: .cleanupDoneMs)
        try container.encode(audioMs, forKey: .audioMs)
        try container.encode(firstSettledWindow, forKey: .firstSettledWindow)
        try container.encode(draftCount, forKey: .draftCount)
        try container.encode(draftIntervalMeanMs, forKey: .draftIntervalMeanMs)
        try container.encode(draftIntervalMaxMs, forKey: .draftIntervalMaxMs)
    }
}

/// The `context` object of a dictation record (§14).
struct DevDictationContext: Encodable, Sendable {
    /// Surrounding text of the focused field — nil until PR 10.
    let surroundingText: String?
    let bundleID: String?
    let mode: String

    enum CodingKeys: String, CodingKey {
        case surroundingText = "surrounding_text"
        case bundleID = "bundle_id"
        case mode
    }
}

/// Where one cleanup sits in its dictation session: the session's id and the
/// milliseconds from session start to when the cleanup was queued and to when
/// the engine call began. Nil fields are omitted from the record.
struct DevCleanupTiming: Sendable, Equatable {
    var sessionID: String?
    var enqueuedMs: Int?
    var startedMs: Int?

    static let none = DevCleanupTiming()
}

/// One cleanup invocation — the feedstock for prompt tuning. Dispositions:
/// applied | stale | cancelled | failed (failed carries the engine error;
/// see CleanupOutcome for why it extends the spec's set).
struct DevCleanupRecord: Encodable, Sendable {
    let type = "cleanup"
    let timestamp: String
    let input: String
    let output: String?
    let generation: Int
    let disposition: String
    let error: String?
    let durationMs: Int?
    let sessionID: String?
    let enqueuedMs: Int?
    let startedMs: Int?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, input, output, generation, disposition, error
        case durationMs = "duration_ms"
        case sessionID = "session_id"
        case enqueuedMs = "enqueued_ms"
        case startedMs = "started_ms"
    }

    init(
        _ outcome: CleanupOutcome,
        timestamp: String = Date().ISO8601Format(),
        timing: DevCleanupTiming = .none
    ) {
        self.timestamp = timestamp
        self.input = outcome.input
        self.output = outcome.output
        self.generation = outcome.generation
        self.disposition = outcome.disposition.rawValue
        self.error = outcome.errorDescription
        self.durationMs = outcome.durationMs
        self.sessionID = timing.sessionID
        self.enqueuedMs = timing.enqueuedMs
        self.startedMs = timing.startedMs
    }
}
#endif
