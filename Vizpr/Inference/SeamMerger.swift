import Foundation

/// Pure seam-merge for finalized text arriving from windowed ASR (PLAN.md §5):
/// the spacing and punctuation rules for joining one final onto the text
/// before it, plus the echo strip for cleanup output.
///
/// Finals no longer repeat each other's words: the engine decodes each window
/// with audio before it for context and keeps only the words that start inside
/// the window (`TimedCut`), so nothing here matches words across a seam. A
/// phrase repeated across two finals is real speech and is kept.
///
/// Field-collected artifacts this handles (2026-07-03 logs, now fixtures):
/// - a final beginning with orphan punctuation (", a lot of booze…") that must
///   glue onto the previous text without a space,
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

        // Leading punctuation: if the context is already terminated, the seam
        // duplicated the boundary ("…margaritas." + ", a lot…") — strip it.
        // Otherwise it belongs to the previous clause and glues directly
        // ("…margaritas" + ", a lot…").
        if let first = incoming.first, first.isPunctuation {
            if let last = context.last, last.isPunctuation {
                let stripped = String(incoming.drop { $0.isPunctuation || $0.isWhitespace })
                return stripped.isEmpty ? "" : " " + stripped
            }
            return incoming
        }
        return " " + incoming
    }

    /// Filler tokens ignored when ALIGNING a cleanup echo with its context:
    /// cleanup removes fillers, so a copy of the context can lack ones the
    /// context has.
    private static let fillers: Set<String> = ["uh", "um"]

    /// Contraction variants cleanup may normalize when it copies the context
    /// ("gonna" / "going to"). Both sides expand before alignment.
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

    /// Strip a leading ECHO of `context` from `incoming` — cleanup models
    /// occasionally copy the surrounding settled context into their rewrite
    /// despite the prompt (field catch, 2026-07-05: an entire settled
    /// paragraph rendered and COMMITTED twice). The echo can be arbitrarily
    /// long, so the whole context participates; and it must be a substantial
    /// verbatim-ish match (≥ 3 tokens) so a rewrite legitimately opening with
    /// a repeated word is never eaten.
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
            // The match must end at a raw-word boundary on the incoming side:
            // matching only "going" out of gonna→[going, to] would consume the
            // whole raw word and lose its "to".
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
