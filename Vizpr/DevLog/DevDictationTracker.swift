#if DICT_DEV_LOG
import Foundation

/// Accumulates the raw ASR text of the current session for the per-dictation
/// record (§14): `raw_asr_text` is the engine's raw output — before the vocab
/// pre-pass and cleanup — so the record captures exactly what the display
/// pipeline was given to improve on.
///
/// Raw mirrors the display's own shape: confirmed (finalized) spans plus the
/// trailing unconfirmed draft. The trailing draft is load-bearing, not a
/// nicety — sessions under the sliding window's 10 s confirmation context
/// never confirm ANYTHING, even at flush (field-observed: every short
/// dictation logged empty raw when only finals were tracked). Each finalized
/// span supersedes the drafts of the window it confirms, so finals clear the
/// trailing draft.
actor DevDictationTracker {
    private var rawFinalized: [String] = []
    private var trailingDraft = ""

    /// Observe one ASR event on its way into SmartCleanup.
    func observe(_ event: TokenEvent) {
        switch event {
        case let .draft(_, text):
            trailingDraft = text
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
            modelTier: modelTier
        )
    }
}
#endif
