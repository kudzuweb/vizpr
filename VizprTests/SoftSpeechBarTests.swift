import FluidAudio
import Testing
@testable import Vizpr

@Suite("SoftSpeechBar")
struct SoftSpeechBarTests {

    /// One word decoded 2 s into a decode that starts at sample 0, with the
    /// given token confidence.
    private func cut(confidence: Float, decodeStart: Int = 0, cutStart: Int, cutEnd: Int) -> TimedCut.Cut {
        let timing = TokenTiming(token: " hello", tokenId: 1, startTime: 2.0, endTime: 2.4, confidence: confidence)
        let result = ASRResult(
            text: "hello", confidence: confidence, duration: 0, processingTime: 0, tokenTimings: [timing]
        )
        return TimedCut.cut(
            result: result, decodeStart: decodeStart, cutStart: cutStart, cutEnd: cutEnd
        )
    }

    private func runs(_ ranges: Range<Int>...) -> SoftRuns {
        var runs = SoftRuns()
        ranges.forEach { runs.append($0) }
        return runs
    }

    @Test("An entirely soft cut is dropped at 0.79 and kept at 0.81")
    func finalBar() {
        let soft = runs(32_000 ..< 96_000)
        let span = 32_000 ..< 96_000
        #expect(!SoftSpeechBar.keeps(cut(confidence: 0.79, cutStart: 32_000, cutEnd: 96_000), span: span, runs: soft))
        #expect(SoftSpeechBar.keeps(cut(confidence: 0.81, cutStart: 32_000, cutEnd: 96_000), span: span, runs: soft))
    }

    @Test("The left context before cutStart does not make a soft cut mixed")
    func leftContextIgnored() {
        // The decode starts 2 s (32,000 samples) before the cut, in ordinary audio.
        let soft = runs(32_000 ..< 96_000)
        let low = cut(confidence: 0.5, decodeStart: 0, cutStart: 32_000, cutEnd: 96_000)
        #expect(!SoftSpeechBar.keeps(low, span: 32_000 ..< 96_000, runs: soft))
    }

    @Test("A cut that reaches into ordinary audio is kept at 0.5")
    func mixedCutKept() {
        let soft = runs(32_000 ..< 64_000)
        let low = cut(confidence: 0.5, cutStart: 32_000, cutEnd: 96_000)
        #expect(SoftSpeechBar.keeps(low, span: 32_000 ..< 96_000, runs: soft))
        #expect(SoftSpeechBar.keeps(low, span: 32_000 ..< 96_000, runs: SoftRuns()), "no soft audio at all")
    }

    @Test("A cut spanning two separate soft runs is mixed")
    func separateRunsAreMixed() {
        let soft = runs(0 ..< 10_000, 12_000 ..< 30_000)
        #expect(!soft.covers(5_000 ..< 25_000))
        #expect(soft.covers(13_000 ..< 25_000))
    }

    @Test("Contiguous soft batches merge into one run, and trimming forgets runs behind the buffer")
    func runsMergeAndTrim() {
        var soft = SoftRuns()
        soft.append(0 ..< 1_600)
        soft.append(1_600 ..< 3_200)
        soft.append(8_000 ..< 9_600)
        #expect(soft.ranges == [0 ..< 3_200, 8_000 ..< 9_600])
        soft.trim(before: 3_200)
        #expect(soft.ranges == [8_000 ..< 9_600])
    }

    @Test("An entirely soft draft under the bar yields empty text; at or above it keeps its text")
    func draftBar() {
        #expect(SoftSpeechBar.draftText("hello", confidence: 0.79, entirelySoft: true).isEmpty)
        #expect(SoftSpeechBar.draftText("hello", confidence: 0.80, entirelySoft: true) == "hello")
        #expect(SoftSpeechBar.draftText("hello", confidence: 0.2, entirelySoft: false) == "hello")
    }
}
