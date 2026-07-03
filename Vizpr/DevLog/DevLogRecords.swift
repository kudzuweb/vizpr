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
    let rawASRText: String
    let injectedText: String
    let context: DevDictationContext
    let modelTier: String

    enum CodingKeys: String, CodingKey {
        case type, timestamp, context
        case rawASRText = "raw_asr_text"
        case injectedText = "injected_text"
        case modelTier = "model_tier"
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

    init(_ outcome: CleanupOutcome, timestamp: String = Date().ISO8601Format()) {
        self.timestamp = timestamp
        self.input = outcome.input
        self.output = outcome.output
        self.generation = outcome.generation
        self.disposition = outcome.disposition.rawValue
        self.error = outcome.errorDescription
    }
}
#endif
