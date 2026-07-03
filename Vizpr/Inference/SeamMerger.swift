import Foundation

/// Pure seam-merge for finalized text arriving from windowed ASR (PLAN.md §5:
/// "tolerant to dedup nondeterminism at window seams" — TokenStream's side of
/// that contract).
///
/// Field-collected artifacts this handles (2026-07-03 logs, now fixtures):
/// - a final beginning with orphan punctuation (", a lot of booze…") that must
///   glue onto the previous text without a space,
/// - a final re-transcribing words already present at the tail of the previous
///   window ("… Good work" / ". Good work, Fable."),
/// - bare punctuation-only finals (".") that duplicate an existing terminator.
enum SeamMerger {

    /// Compute the string to append to `context` so that `context + result`
    /// reads as continuous text. Returns "" when `new` adds nothing.
    static func appendix(context: String, new: String) -> String {
        let incoming = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return "" }
        guard !context.isEmpty else { return incoming }

        // Punctuation-only finals: drop if the context already ends with the
        // same terminator; otherwise glue directly (no space).
        if incoming.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) {
            if let last = context.last, incoming.hasSuffix(String(last)) { return "" }
            return incoming
        }

        // Word-overlap trim: the longest run of words ending `context` that
        // also begins `incoming` was re-transcribed at the seam — drop it.
        let deduped = trimOverlap(context: context, incoming: incoming)
        guard !deduped.isEmpty else { return "" }

        // Leading punctuation: if the context is already terminated, the seam
        // duplicated the boundary ("…margaritas." + ", a lot…") — strip it.
        // Otherwise it belongs to the previous clause and glues directly
        // ("…margaritas" + ", a lot…").
        if let first = deduped.first, first.isPunctuation {
            if let last = context.last, last.isPunctuation {
                let stripped = String(deduped.drop { $0.isPunctuation || $0.isWhitespace })
                return stripped.isEmpty ? "" : " " + stripped
            }
            return deduped
        }
        return " " + deduped
    }

    /// Longest suffix-of-context == prefix-of-incoming match, compared as
    /// normalized words (case/punctuation-insensitive), capped for cost.
    ///
    /// Guard against eating genuinely repeated speech (review finding: a user
    /// saying "…that's final. Final answer." must not lose the second word):
    /// a normalized match of >= 2 words is confidently a seam re-transcription;
    /// a single-word match trims only when the raw words are IDENTICAL
    /// including case and punctuation — real emphasis repeats ("final." vs
    /// "Final") differ in surface form and are preserved.
    private static func trimOverlap(context: String, incoming: String) -> String {
        let contextRaw = context.split(separator: " ").suffix(12)
        let contextWords = contextRaw.map(normalize)
        let incomingRaw = incoming.split(separator: " ", omittingEmptySubsequences: true)
        let incomingWords = incomingRaw.prefix(12).map(normalize)

        var overlap = 0
        let maxLen = min(contextWords.count, incomingWords.count)
        for length in stride(from: maxLen, through: 1, by: -1) {
            let tail = contextWords.suffix(length)
            let head = incomingWords.prefix(length)
            guard !tail.isEmpty, Array(tail) == Array(head),
                  tail.contains(where: { !$0.isEmpty }) else { continue }
            if length == 1, contextRaw.last != incomingRaw.first { continue }
            overlap = length
            break
        }
        guard overlap > 0, overlap <= incomingRaw.count else { return incoming }
        guard overlap < incomingRaw.count else { return "" }

        // Slice the ORIGINAL string after the overlap words rather than
        // rejoining split words: rejoining collapses internal whitespace, a
        // silent transformation the WYSIWYG contract forbids (review finding).
        let lastOverlapWord = incomingRaw[overlap - 1]
        let rest = incoming[lastOverlapWord.endIndex...]
        return String(rest.drop { $0 == " " })
    }

    private static func normalize(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Pure sentence segmentation for the settle policy (PLAN.md §3). Deliberately
/// simple: terminator characters followed by whitespace (or end) close a
/// sentence. Abbreviation handling is a later refinement; mis-splits only make
/// the settle window slightly conservative or eager, never incorrect text.
enum SentenceSplitter {
    /// Split into sentences, each including its terminator and trailing space,
    /// such that `parts.joined() == text` exactly (lossless for region moves).
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var sawTerminator = false
        var sawBreakAfterTerminator = false

        for char in text {
            // A sentence closes only at terminator(s) + whitespace + content:
            // requiring the whitespace keeps ellipses ("Wait... what?") and
            // other punctuation runs inside one sentence.
            if sawTerminator, sawBreakAfterTerminator, !char.isWhitespace {
                parts.append(current)
                current = ""
                sawTerminator = false
                sawBreakAfterTerminator = false
            }
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                sawTerminator = true
                sawBreakAfterTerminator = false
            } else if char.isWhitespace {
                if sawTerminator { sawBreakAfterTerminator = true }
            } else {
                sawTerminator = false
                sawBreakAfterTerminator = false
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
