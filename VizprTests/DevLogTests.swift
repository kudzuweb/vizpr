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
            modelTier: "qwen3-4b-instruct-2507-4bit"
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

    @Test("Tracker accumulates finalized text only and resets after the record")
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
}
#endif
