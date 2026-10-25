import FluidAudio
import Testing
@testable import Vizpr

@Suite("TimedCut")
struct TimedCutTests {

    private let rate = 16_000

    private func token(_ text: String, at start: Double, length: Double = 0.2, confidence: Float = 0.9) -> TokenTiming {
        TokenTiming(
            token: text, tokenId: 1, startTime: start, endTime: start + length, confidence: confidence
        )
    }

    private func result(_ timings: [TokenTiming]) -> ASRResult {
        let text = timings.map(\.token).joined().trimmingCharacters(in: .whitespaces)
        return ASRResult(text: text, confidence: 0.9, duration: 0, processingTime: 0, tokenTimings: timings)
    }

    /// "the quick brown fox." with "brown" split into two pieces, one word per
    /// 0.5 s starting at 0.
    private var sentence: [TokenTiming] {
        [
            token(" the", at: 0.0), token(" quick", at: 0.5), token(" br", at: 1.0),
            token("own", at: 1.2), token(" fox", at: 1.5), token(".", at: 1.7),
        ]
    }

    @Test("Words before cutStart and from cutEnd on are dropped by their first token")
    func dropsOutsideWords() {
        let cut = TimedCut.cut(result: result(sentence), decodeStart: 0, cutStart: 8_000, cutEnd: 24_000)
        #expect(cut.text == "quick brown")
    }

    @Test("A two-piece word straddling the cut belongs to exactly one side")
    func straddlingWordKeptWhole() {
        // The cut falls at 1.1 s, between "br" (1.0 s) and "own" (1.2 s).
        let cutAt = Int(1.1 * Double(rate))
        let before = TimedCut.cut(result: result(sentence), decodeStart: 0, cutStart: 0, cutEnd: cutAt)
        let after = TimedCut.cut(result: result(sentence), decodeStart: 0, cutStart: cutAt, cutEnd: 10 * rate)
        #expect(before.text == "the quick brown")
        #expect(after.text == "fox.")
    }

    @Test("A cut over the whole decode rebuilds the result's text")
    func fullRangeEqualsResultText() {
        let decoded = result(sentence)
        let cut = TimedCut.cut(result: decoded, decodeStart: 0, cutStart: 0, cutEnd: 10 * rate)
        #expect(cut.text == decoded.text)
    }

    @Test("Positions are relative to the decode start")
    func decodeStartOffsets() {
        // Decode began at absolute sample 32,000 (2 s); the window starts at 2.5 s.
        let cut = TimedCut.cut(result: result(sentence), decodeStart: 32_000, cutStart: 40_000, cutEnd: 80_000)
        #expect(cut.text == "quick brown fox.")
    }

    @Test("A leading fragment is never kept")
    func leadingFragmentDropped() {
        let timings = [token("ing", at: 0.0), token(" the", at: 0.4), token(" end", at: 0.8)]
        let cut = TimedCut.cut(result: result(timings), decodeStart: 0, cutStart: 0, cutEnd: 10 * rate)
        #expect(cut.text == "the end")
    }

    @Test("keptEnd is the last kept word's end in samples, nil for an empty cut")
    func keptEnd() {
        let cut = TimedCut.cut(result: result(sentence), decodeStart: 0, cutStart: 0, cutEnd: Int(1.3 * Double(rate)))
        // "brown" ends with its last piece: 1.2 s + 0.2 s.
        #expect(cut.keptEnd == Int(1.4 * Double(rate)))

        let empty = TimedCut.cut(result: result(sentence), decodeStart: 0, cutStart: 5 * rate, cutEnd: 6 * rate)
        #expect(empty.text.isEmpty)
        #expect(empty.keptEnd == nil)
        #expect(empty.confidence == 1.0)
        #expect(empty.tokenConfidences.isEmpty)
    }

    @Test("Confidence is the mean over the kept tokens")
    func keptConfidence() {
        let timings = [
            token(" a", at: 0.0, confidence: 0.5), token(" b", at: 0.5, confidence: 0.7),
            token(" c", at: 1.0, confidence: 0.1),
        ]
        let cut = TimedCut.cut(result: result(timings), decodeStart: 0, cutStart: 0, cutEnd: 8_000 + 4_000)
        #expect(cut.tokenConfidences == [0.5, 0.7])
        #expect(abs(cut.confidence - 0.6) < 0.0001)
    }

    @Test("A token missing from the vocabulary is left out of the text")
    func vocabularyMissDropped() {
        let timings = [token(" hello", at: 0.0), token("token_123", at: 0.5), token(" world", at: 1.0)]
        let cut = TimedCut.cut(result: result(timings), decodeStart: 0, cutStart: 0, cutEnd: 10 * rate)
        #expect(cut.text == "hello world")
    }

    // MARK: Forced cut

    /// One word per `step` seconds from 0 up to `count` words, each `length` long.
    private func evenWords(count: Int, step: Double, length: Double) -> [TokenTiming] {
        (0 ..< count).map { token(" w\($0)", at: Double($0) * step, length: length) }
    }

    @Test("A gap that ends before 9 s is not a candidate")
    func forcedCutIgnoresEarlyGaps() {
        var timings = evenWords(count: 18, step: 0.5, length: 0.4)   // last word ends at 8.9 s
        timings.append(token(" late", at: 10.3, length: 0.4))         // the 8.9 -> 10.3 gap starts before 9 s
        timings.append(token(" after", at: 10.8, length: 0.4))
        let point = TimedCut.forcedCutPoint(result: result(timings), decodeStart: 0, cutStart: 0)
        #expect(point == Int(10.75 * Double(rate)))   // late (ends 10.7) -> after (10.8)
    }

    @Test("The forced cut picks the wider of two eligible gaps")
    func forcedCutPicksWidest() {
        let timings = [
            token(" a", at: 8.0, length: 1.0), token(" b", at: 9.2, length: 0.3),   // gap 9.0 -> 9.2
            token(" c", at: 10.4, length: 0.3), token(" d", at: 10.8, length: 0.2),  // gaps 9.5 -> 10.4, 10.7 -> 10.8
        ]
        let point = TimedCut.forcedCutPoint(result: result(timings), decodeStart: 0, cutStart: 0)
        #expect(point == Int(((9.5 + 10.4) / 2) * Double(rate)))
    }

    @Test("With no eligible gap the forced cut is the first word at or after 10 s")
    func forcedCutFirstWordAfterTen() {
        let timings = [token(" a", at: 5.0, length: 0.4), token(" b", at: 10.6, length: 0.4)]
        let point = TimedCut.forcedCutPoint(result: result(timings), decodeStart: 0, cutStart: 0)
        #expect(point == Int(10.6 * Double(rate)))
    }

    @Test("With no word at or after 10 s the forced cut is 10 s")
    func forcedCutTenSeconds() {
        let timings = [token(" a", at: 5.0, length: 0.4), token(" b", at: 6.0, length: 0.4)]
        let point = TimedCut.forcedCutPoint(result: result(timings), decodeStart: 0, cutStart: 0)
        #expect(point == 10 * rate)
    }

    @Test("The forced cut measures 9 to 11 s from cutStart, not from the decode start")
    func forcedCutRelativeToCutStart() {
        // Decode began 2 s before cutStart, so word times carry a 2 s offset.
        let timings = [token(" a", at: 2.0 + 9.0, length: 0.2), token(" b", at: 2.0 + 10.0, length: 0.2)]
        let point = TimedCut.forcedCutPoint(result: result(timings), decodeStart: 0, cutStart: 2 * rate)
        // Gap 11.2 -> 12.0 relative to the decode start; midpoint 11.6 s.
        #expect(point == Int(11.6 * Double(rate)))
    }
}
