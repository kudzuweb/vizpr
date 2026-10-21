#if DICT_DEV_LOG
import Foundation
import Testing
@testable import Vizpr

/// The §14 JSONL contract: one self-contained JSON object per line, snake_case
/// spec keys, parseable line-by-line (the unit-test stand-in for
/// `pandas.read_json(lines=True)`; scripts/check-devlog-parses.py is the real
/// acceptance check against a live log).
@Suite("DevLog")
struct DevLogTests {

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devlog-test-\(UUID().uuidString).jsonl")
    }

    private func parsedLines(of url: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        return try lines.map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any], "line is not a JSON object: \(line)")
        }
    }

    @Test("Writer appends one parseable JSON object per record")
    func writerAppendsJSONL() async throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = VizprDevLogWriter(fileURL: url)

        await writer.append(DevDictationRecord(
            timestamp: "2026-07-03T00:00:00Z",
            rawASRText: "helo wrld",
            injectedText: "Hello world.",
            context: DevDictationContext(
                surroundingText: nil, bundleID: "com.apple.TextEdit", mode: "default"
            ),
            modelTier: "qwen3-4b-instruct-2507-4bit",
            timings: .none
        ))
        await writer.append(DevCleanupRecord(
            CleanupOutcome(
                input: "helo wrld", output: "Hello world.",
                generation: 3, disposition: .applied
            ),
            timestamp: "2026-07-03T00:00:01Z"
        ))

        let records = try parsedLines(of: url)
        try #require(records.count == 2)

        let dictation = records[0]
        #expect(dictation["type"] as? String == "dictation")
        #expect(dictation["raw_asr_text"] as? String == "helo wrld")
        #expect(dictation["injected_text"] as? String == "Hello world.")
        #expect(dictation["model_tier"] as? String == "qwen3-4b-instruct-2507-4bit")
        let context = dictation["context"] as? [String: Any]
        #expect(context?["bundle_id"] as? String == "com.apple.TextEdit")
        #expect(context?["mode"] as? String == "default")

        let cleanupRecord = records[1]
        #expect(cleanupRecord["type"] as? String == "cleanup")
        #expect(cleanupRecord["input"] as? String == "helo wrld")
        #expect(cleanupRecord["output"] as? String == "Hello world.")
        #expect(cleanupRecord["generation"] as? Int == 3)
        #expect(cleanupRecord["disposition"] as? String == "applied")
    }

    @Test("Newlines in transcript text never break the one-line contract")
    func newlinesStayEscaped() async throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = VizprDevLogWriter(fileURL: url)

        await writer.append(DevCleanupRecord(
            CleanupOutcome(
                input: "line one\nline two", output: "Line one.\nLine two.",
                generation: 0, disposition: .applied
            ),
            timestamp: "2026-07-03T00:00:00Z"
        ))

        let records = try parsedLines(of: url)
        try #require(records.count == 1, "embedded newline split the record across lines")
        #expect(records[0]["input"] as? String == "line one\nline two")
    }

    @Test("Failed outcomes carry the engine error")
    func failedCarriesError() async throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = VizprDevLogWriter(fileURL: url)

        await writer.append(DevCleanupRecord(
            CleanupOutcome(
                input: "text", output: nil, generation: 1,
                disposition: .failed, errorDescription: "modelUnavailable"
            ),
            timestamp: "2026-07-03T00:00:00Z"
        ))

        let records = try parsedLines(of: url)
        #expect(records[0]["disposition"] as? String == "failed")
        #expect(records[0]["error"] as? String == "modelUnavailable")
    }

    @Test("Tracker joins finalized spans; finals supersede window drafts")
    func trackerAccumulatesFinals() async {
        let tracker = DevDictationTracker()
        await tracker.observe(.draft(windowID: 0, text: "draft noise"))
        await tracker.observe(.finalized(text: "first span.", confidence: 0.9, tokenConfidences: []))
        await tracker.observe(.draft(windowID: 1, text: "more draft"))
        await tracker.observe(.finalized(text: "second span.", confidence: 0.9, tokenConfidences: []))

        let record = await tracker.makeRecord(
            injectedText: "First span. Second span.",
            bundleID: nil, mode: "default", modelTier: "test",
            timestamp: "2026-07-03T00:00:00Z"
        )
        #expect(record.rawASRText == "first span. second span.")
        #expect(record.injectedText == "First span. Second span.")

        // The record sealed the session: the next record starts empty.
        let next = await tracker.makeRecord(
            injectedText: "", bundleID: nil, mode: "default", modelTier: "test",
            timestamp: "2026-07-03T00:00:00Z"
        )
        #expect(next.rawASRText.isEmpty)
    }

    @Test("A draft-only session records the last draft as raw")
    func trackerDraftOnlySession() async {
        // Field regression: sessions shorter than the 10 s confirmation
        // context never confirm anything — even the flush arrives as a draft —
        // so a finals-only tracker logged empty raw for every short dictation.
        let tracker = DevDictationTracker()
        await tracker.observe(.draft(windowID: 0, text: "were doing a quick"))
        await tracker.observe(.draft(windowID: 0, text: "were doing a quick short"))
        await tracker.observe(.draft(windowID: 0, text: "were doing a quick short flush tail"))

        let record = await tracker.makeRecord(
            injectedText: "We're doing a quick short.",
            bundleID: nil, mode: "default", modelTier: "test",
            timestamp: "2026-07-04T00:00:00Z"
        )
        #expect(record.rawASRText == "were doing a quick short flush tail")
    }

    @Test("Raw is finals plus the unconfirmed trailing draft")
    func trackerFinalsPlusTrailingDraft() async {
        let tracker = DevDictationTracker()
        await tracker.observe(.finalized(text: "confirmed span.", confidence: 0.9, tokenConfidences: []))
        await tracker.observe(.draft(windowID: 1, text: "unconfirmed tail"))

        let record = await tracker.makeRecord(
            injectedText: "Confirmed span. Unconfirmed tail.",
            bundleID: nil, mode: "default", modelTier: "test",
            timestamp: "2026-07-04T00:00:00Z"
        )
        #expect(record.rawASRText == "confirmed span. unconfirmed tail")
    }

    // MARK: Session timing marks (PR 13)

    private let timingKeys = [
        "t_capture_ms", "t_speech_onset_ms", "t_first_draft_ms", "t_first_preview_ms",
        "t_commit_ms", "t_injected_ms", "draft_count",
        "draft_interval_mean_ms", "draft_interval_max_ms"
    ]

    private func encodedObject(_ record: DevDictationRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func record(from tracker: DevDictationTracker) async -> DevDictationRecord {
        await tracker.makeRecord(injectedText: "x", bundleID: nil, mode: "default", modelTier: "test")
    }

    @Test("Every row carries every timing key, null where the mark never happened")
    func timingKeysAlwaysPresent() async throws {
        let empty = try encodedObject(await record(from: DevDictationTracker()))
        for key in timingKeys { #expect(empty[key] != nil, "missing \(key)") }
        #expect(empty["t_capture_ms"] is NSNull)
        #expect(empty["draft_interval_mean_ms"] is NSNull)
        #expect((empty["draft_count"] as? Int) == 0)

        let tracker = DevDictationTracker()
        let start = ContinuousClock.now
        await tracker.begin(at: start)
        await tracker.mark(.captureStarted, at: start + .milliseconds(212))
        let partial = try encodedObject(await record(from: tracker))
        #expect((partial["t_capture_ms"] as? Int) == 212)
        #expect(partial["t_injected_ms"] is NSNull)
    }

    @Test("A mark keeps its first occurrence, and marks before begin are ignored")
    func marksKeepFirstOccurrence() async {
        let tracker = DevDictationTracker()
        let start = ContinuousClock.now
        await tracker.mark(.speechOnset, at: start + .milliseconds(5))
        await tracker.begin(at: start)
        await tracker.mark(.speechOnset, at: start + .milliseconds(640))
        await tracker.mark(.speechOnset, at: start + .milliseconds(900))
        await tracker.mark(.commit, at: start + .milliseconds(5400))
        await tracker.mark(.injected, at: start + .milliseconds(5570))
        let timings = await record(from: tracker).timings

        #expect(timings.speechOnsetMs == 640)
        #expect(timings.commitMs == 5400)
        #expect(timings.injectedMs == 5570)
        #expect(timings.captureMs == nil)
    }

    @Test("Draft cadence is the mean and max gap between consecutive arrivals")
    func draftIntervals() async {
        let tracker = DevDictationTracker()
        let start = ContinuousClock.now
        await tracker.begin(at: start)
        for offset in [2000, 3000, 4200, 5100] {
            await tracker.observe(.draft(windowID: 0, text: "d"), at: start + .milliseconds(offset))
        }
        let timings = await record(from: tracker).timings

        #expect(timings.firstDraftMs == 2000)
        #expect(timings.draftCount == 4)
        #expect(timings.draftIntervalMeanMs == 1033)   // (1000 + 1200 + 900) / 3
        #expect(timings.draftIntervalMaxMs == 1200)
    }

    @Test("Fewer than two drafts leave the interval statistics null")
    func singleDraftHasNoIntervals() async {
        let tracker = DevDictationTracker()
        let start = ContinuousClock.now
        await tracker.begin(at: start)
        await tracker.observe(.draft(windowID: 0, text: "d"), at: start + .milliseconds(2100))
        let timings = await record(from: tracker).timings

        #expect(timings.draftCount == 1)
        #expect(timings.draftIntervalMeanMs == nil)
        #expect(timings.draftIntervalMaxMs == nil)
    }

    @Test("A new session starts from a clean slate")
    func beginResetsPreviousSession() async {
        let tracker = DevDictationTracker()
        let start = ContinuousClock.now
        await tracker.begin(at: start)
        await tracker.mark(.commit, at: start + .milliseconds(100))
        await tracker.observe(.draft(windowID: 0, text: "d"), at: start + .milliseconds(50))
        await tracker.begin(at: start + .seconds(10))
        let timings = await record(from: tracker).timings

        #expect(timings.commitMs == nil)
        #expect(timings.draftCount == 0)
    }
}
#endif
