import Foundation
import FluidAudio

/// Cuts a batch decode into the words that belong to one window, by token
/// timing, and rebuilds their text.
///
/// Every window and the commit tail are decoded with a little audio before
/// their start, for acoustic context. The context's words are decoded again
/// and must not reach the display twice, so each decode keeps only the words
/// whose first token starts inside the window's span. A word is the unit of
/// the cut: Parakeet splits words into SentencePiece pieces, and a cut between
/// two pieces would render a fragment on each side.
///
/// Pure value logic over `ASRResult`, so the cut is testable without a model.
enum TimedCut {
    static let sampleRate = 16_000

    /// One decoded word: its first token through the last token that does not
    /// start a new word, so a punctuation piece stays with the word it follows.
    struct Word {
        let tokens: ArraySlice<TokenTiming>

        var start: TimeInterval { tokens.first?.startTime ?? 0 }
        var end: TimeInterval { tokens.last?.endTime ?? 0 }
    }

    struct Cut: Equatable {
        let text: String
        let confidence: Float
        let tokenConfidences: [Float]
        /// Where the last kept word ends, in samples from the decode start;
        /// nil when no word was kept.
        let keptEnd: Int?
    }

    /// Groups tokens into words. A word begins at a token whose text starts
    /// with a space (FluidAudio renders the SentencePiece word marker that
    /// way). Tokens before the first such token continue a word that began in
    /// audio the decode did not hear, so they belong to no word.
    static func words(in timings: [TokenTiming]) -> [Word] {
        var starts: [Int] = []
        for (index, timing) in timings.enumerated() where timing.token.hasPrefix(" ") {
            starts.append(index)
        }
        var words: [Word] = []
        for (position, first) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : timings.count
            words.append(Word(tokens: timings[first ..< end]))
        }
        return words
    }

    /// Keeps the words whose first token starts in
    /// `[cutStart - startTolerance, cutEnd)`. Positions are absolute sample
    /// indices; `decodeStart` is the absolute sample the decode's audio began
    /// at. The tolerance covers the decoder stamping a word's start a frame or
    /// more before its true position, which would otherwise drop a word that
    /// begins right at the boundary.
    static func cut(
        result: ASRResult, decodeStart: Int, cutStart: Int, cutEnd: Int, startTolerance: Int = 0
    ) -> Cut {
        let lower = Double(cutStart - startTolerance - decodeStart) / Double(sampleRate)
        let upper = Double(cutEnd - decodeStart) / Double(sampleRate)
        let kept = words(in: result.tokenTimings ?? []).filter { $0.start >= lower && $0.start < upper }
        let tokens = kept.flatMap(\.tokens)
        guard let lastWord = kept.last else {
            return Cut(text: "", confidence: 1.0, tokenConfidences: [], keptEnd: nil)
        }
        let confidences = tokens.map(\.confidence)
        return Cut(
            text: text(of: tokens),
            confidence: confidences.reduce(0, +) / Float(confidences.count),
            tokenConfidences: confidences,
            keptEnd: Int((lastWord.end * Double(sampleRate)).rounded())
        )
    }

    /// Where a forced window should end, as an absolute sample. The widest gap
    /// between two words inside 9 to 11 s after `cutStart` wins, cut at its
    /// midpoint, so the cut lands between words and not in one. With no such
    /// gap it falls back to the start of the first word that begins at or
    /// after 10 s, and failing that to 10 s.
    static func forcedCutPoint(result: ASRResult, decodeStart: Int, cutStart: Int) -> Int {
        let origin = Double(cutStart - decodeStart) / Double(sampleRate)
        let words = words(in: result.tokenTimings ?? [])

        var widest: (width: TimeInterval, midpoint: TimeInterval)?
        for (previous, next) in zip(words, words.dropFirst()) {
            guard previous.end >= origin + 9, next.start <= origin + 11 else { continue }
            let width = next.start - previous.end
            if width > (widest?.width ?? -1) {
                widest = (width, (previous.end + next.start) / 2)
            }
        }
        let cut = widest?.midpoint
            ?? words.first(where: { $0.start >= origin + 10 })?.start
            ?? origin + 10
        return decodeStart + Int((cut * Double(sampleRate)).rounded())
    }

    private static func text(of tokens: [TokenTiming]) -> String {
        tokens
            .filter { !isVocabularyMiss($0.token) }
            .map(\.token)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    /// FluidAudio renders a token id missing from the vocabulary as
    /// `token_<id>` in the timing text, and drops it from the result's text.
    private static func isVocabularyMiss(_ token: String) -> Bool {
        token.hasPrefix("token_") && token.dropFirst("token_".count).allSatisfy(\.isNumber)
    }
}
