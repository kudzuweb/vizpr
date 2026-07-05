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
    /// Filler tokens ignored when ALIGNING the overlap (field catch: the
    /// windowed final ended "…Otherwise, we're" and the next window opened
    /// "Otherwise, uh we're coming" — the "uh" broke token alignment and the
    /// words rendered twice). Fillers inside a matched overlap are trimmed
    /// with it; fillers elsewhere are never touched.
    private static let fillers: Set<String> = ["uh", "um"]

    /// Contraction variants the ASR renders inconsistently across windows
    /// (field catch: "…going to feel different than" / "…gonna feel different
    /// than" rendered twice). Both sides expand before alignment.
    private static let expansions: [String: [String]] = [
        "gonna": ["going", "to"], "wanna": ["want", "to"], "gotta": ["got", "to"],
        "kinda": ["kind", "of"], "sorta": ["sort", "of"], "dunno": ["dont", "know"],
    ]

    /// One alignment token: normalized text plus the raw word it came from.
    private struct Token {
        let raw: Int
        let text: String
    }

    /// Normalize raw words into alignment tokens: lowercase alphanumerics,
    /// fillers skipped, contractions expanded, punctuation-only words skipped.
    private static func alignmentTokens(_ words: [Substring]) -> [Token] {
        var out: [Token] = []
        for (index, word) in words.enumerated() {
            let normalized = normalize(word)
            if normalized.isEmpty || fillers.contains(normalized) { continue }
            if let expanded = expansions[normalized] {
                out.append(contentsOf: expanded.map { Token(raw: index, text: $0) })
            } else {
                out.append(Token(raw: index, text: normalized))
            }
        }
        return out
    }

    private static func trimOverlap(context: String, incoming: String) -> String {
        let contextRaw = Array(context.split(separator: " ").suffix(12))
        let incomingRaw = incoming.split(separator: " ", omittingEmptySubsequences: true)
        let contextToks = alignmentTokens(contextRaw)
        let incomingToks = alignmentTokens(Array(incomingRaw.prefix(12)))

        var rawConsumed = 0
        let maxLen = min(contextToks.count, incomingToks.count)
        for length in stride(from: maxLen, through: 1, by: -1) {
            let tail = contextToks.suffix(length).map(\.text)
            let head = incomingToks.prefix(length).map(\.text)
            guard tail == head else { continue }
            // The match must end at a raw-word boundary on the incoming side:
            // matching only "going" out of gonna→[going, to] would trim the
            // whole raw word and lose its "to".
            if length < incomingToks.count,
               incomingToks[length].raw == incomingToks[length - 1].raw { continue }
            if length == 1 {
                // Single-word trims need raw equality modulo the context
                // word's trailing punctuation ("confirmation." / "confirmation"
                // is a seam; "final." / "Final" is real repeated speech).
                let rawContext = contextToks.last.map { String(contextRaw[$0.raw]) } ?? ""
                let rawIncoming = incomingToks.first.map { String(incomingRaw[$0.raw]) } ?? ""
                let stripped = String(rawContext.reversed().drop(while: \.isPunctuation).reversed())
                guard rawContext == rawIncoming || stripped == rawIncoming else { continue }
            }
            // Consume through the raw index of the last matched token,
            // including any fillers interior to the overlap.
            rawConsumed = incomingToks[length - 1].raw + 1
            break
        }
        guard rawConsumed > 0, rawConsumed <= incomingRaw.count else { return incoming }
        guard rawConsumed < incomingRaw.count else { return "" }

        // Slice the ORIGINAL string after the overlap words rather than
        // rejoining split words: rejoining collapses internal whitespace, a
        // silent transformation the WYSIWYG contract forbids (review finding).
        let lastOverlapWord = incomingRaw[rawConsumed - 1]
        let rest = incoming[lastOverlapWord.endIndex...]
        return String(rest.drop { $0 == " " })
    }

    /// Strip a leading ECHO of `context` from `incoming` — cleanup models
    /// occasionally copy the surrounding settled context into their rewrite
    /// despite the prompt (field catch, 2026-07-05: an entire settled
    /// paragraph rendered and COMMITTED twice). Unlike the seam trim, the
    /// echo can be arbitrarily long, so the whole context participates; and
    /// it must be a substantial verbatim-ish match (≥ 3 tokens) so a rewrite
    /// legitimately opening with a repeated word is never eaten.
    static func stripContextEcho(context: String, from incoming: String) -> String {
        guard !context.isEmpty, !incoming.isEmpty else { return incoming }
        let contextRaw = Array(context.split(separator: " "))
        let incomingRaw = incoming.split(separator: " ", omittingEmptySubsequences: true)
        let contextToks = alignmentTokens(contextRaw).map(\.text)
        let incomingToks = alignmentTokens(Array(incomingRaw))

        let maxLen = min(contextToks.count, incomingToks.count)
        for length in stride(from: maxLen, through: 2, by: -1) {
            // Substantial (≥ 3 tokens), or the echo covers the ENTIRE context
            // — a short settled context copied whole is still an echo (test
            // catch: a 2-token context slipped under the threshold and the
            // unstripped echo then REPLACED the live region).
            guard length >= 3 || length == contextToks.count else { continue }
            guard Array(contextToks.suffix(length)) == incomingToks.prefix(length).map(\.text)
            else { continue }
            // Raw-word boundary on the incoming side (see trimOverlap).
            if length < incomingToks.count,
               incomingToks[length].raw == incomingToks[length - 1].raw { continue }
            let rawConsumed = incomingToks[length - 1].raw + 1
            guard rawConsumed < incomingRaw.count else { return "" }
            let lastWord = incomingRaw[rawConsumed - 1]
            return String(incoming[lastWord.endIndex...].drop { $0 == " " })
        }
        return incoming
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
