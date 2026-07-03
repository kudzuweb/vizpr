#if DICT_DEV_LOG
import Foundation

/// Accumulates the raw ASR text of the current session for the per-dictation
/// record (§14): `raw_asr_text` is what the engine finalized — before the
/// vocab pre-pass and cleanup — so the record captures exactly what the
/// display pipeline was given to improve on. Drafts are display-only and
/// excluded.
actor DevDictationTracker {
    private var rawFinalized: [String] = []

    /// Observe one ASR event on its way into SmartCleanup.
    func observe(_ event: TokenEvent) {
        if case let .finalized(text, _, _) = event {
            rawFinalized.append(text)
        }
    }

    /// Discard the session's accumulation (session start, or cancel — a
    /// cancelled dictation injects nothing and gets no record).
    func reset() {
        rawFinalized.removeAll()
    }

    /// Build the dictation record at commit and reset for the next session.
    func makeRecord(
        injectedText: String,
        bundleID: String?,
        mode: String,
        modelTier: String,
        timestamp: String = Date().ISO8601Format()
    ) -> DevDictationRecord {
        defer { rawFinalized.removeAll() }
        return DevDictationRecord(
            timestamp: timestamp,
            rawASRText: rawFinalized.joined(separator: " "),
            injectedText: injectedText,
            context: DevDictationContext(
                surroundingText: nil, bundleID: bundleID, mode: mode
            ),
            modelTier: modelTier
        )
    }
}
#endif
