import Foundation

/// One vocabulary substitution (PLAN.md §4). Two entry kinds, one mechanism:
/// - `.canonical` — normalizes a form: pattern "kubernetes" → "Kubernetes".
/// - `.soundsLike` — maps a mishearing to a term: "pie dantic" → "Pydantic".
/// Both are (pattern → replacement) pairs matched word-boundary-aware and
/// case-insensitively; the kind is metadata for the Settings UI (PR 11).
struct VocabularyEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case canonical
        case soundsLike
    }

    let pattern: String
    let replacement: String
    let kind: Kind
}

/// Pure vocabulary matcher (PLAN.md §4). Runs twice, deliberately: a pre-pass
/// normalizes ASR text before cleanup, and an authoritative post-pass runs on
/// every cleanup result so the model can never un-fix a canonical form
/// (post-pass wins all ties — it is just `apply` run last).
///
/// Matching is word-boundary aware, case-insensitive, and longest-phrase-first;
/// exact + explicit variants only. Fuzzy matching is off in v1 (deferred; fuzzy
/// guesses cause wrong-correction edits). Pure and deterministic.
struct Vocabulary: Sendable, Equatable {
    let entries: [VocabularyEntry]

    static func == (lhs: Vocabulary, rhs: Vocabulary) -> Bool { lhs.entries == rhs.entries }

    /// Patterns as lowercased word arrays, sorted longest-phrase-first so a
    /// multi-word pattern wins over a shorter one starting at the same place.
    private let matchers: [(words: [String], replacement: String)]

    init(entries: [VocabularyEntry]) {
        self.entries = entries
        self.matchers = entries
            .map { (words: Self.words(in: $0.pattern.lowercased()), replacement: $0.replacement) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count > $1.words.count }
    }

    static let empty = Vocabulary(entries: [])

    /// Apply all substitutions to `text`, preserving surrounding whitespace and
    /// punctuation exactly. Idempotent enough to run as both pre- and post-pass.
    func apply(to text: String) -> String {
        guard !matchers.isEmpty else { return text }
        let tokens = Self.tokenize(text)
        guard !tokens.words.isEmpty else { return text }

        var result = tokens.leading
        var index = 0
        while index < tokens.words.count {
            if let match = longestMatch(at: index, in: tokens.words) {
                result += match.replacement
                // Preserve the separator that trailed the LAST matched word so
                // spacing/punctuation after the phrase is unchanged.
                result += tokens.words[index + match.length - 1].separator
                index += match.length
            } else {
                result += tokens.words[index].word + tokens.words[index].separator
                index += 1
            }
        }
        return result
    }

    /// A compact hint injected into the cleanup LLM's context so it knows the
    /// terms exist (PLAN.md §4). The post-pass remains authoritative regardless.
    func promptHint() -> String {
        guard !entries.isEmpty else { return "" }
        let terms = entries.map(\.replacement)
        var seen = Set<String>()
        let unique = terms.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }

    // MARK: Matching

    private func longestMatch(at index: Int, in words: [Token]) -> (length: Int, replacement: String)? {
        for matcher in matchers {
            let length = matcher.words.count
            guard index + length <= words.count else { continue }
            var matched = true
            for offset in 0..<length where words[index + offset].word.lowercased() != matcher.words[offset] {
                matched = false
                break
            }
            if matched { return (length, matcher.replacement) }
        }
        return nil
    }

    // MARK: Tokenization

    /// A word plus the exact separator (whitespace/punctuation) that follows it.
    private struct Token {
        let word: String
        let separator: String
    }

    private static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Split into leading separator + [word, trailing-separator] tokens, exactly
    /// reconstructible: `leading + tokens.map{ $0.word + $0.separator }.joined()`
    /// == the original text. A "word" is a maximal run of letters/digits.
    private static func tokenize(_ text: String) -> (leading: String, words: [Token]) {
        var leading = ""
        var tokens: [Token] = []
        var currentWord = ""
        var currentSeparator = ""
        var inWord = false

        func closeWord() {
            if inWord {
                tokens.append(Token(word: currentWord, separator: ""))
                currentWord = ""
                inWord = false
            }
        }

        for char in text {
            if char.isLetter || char.isNumber {
                if !inWord {
                    // Attach the accumulated separator to the previous word (or
                    // to `leading` if this is the first word).
                    if tokens.isEmpty {
                        leading = currentSeparator
                    } else {
                        tokens[tokens.count - 1] = Token(
                            word: tokens[tokens.count - 1].word, separator: currentSeparator
                        )
                    }
                    currentSeparator = ""
                    inWord = true
                }
                currentWord.append(char)
            } else {
                closeWord()
                currentSeparator.append(char)
            }
        }
        closeWord()
        // Trailing separator after the last word.
        if !currentSeparator.isEmpty {
            if tokens.isEmpty {
                leading += currentSeparator
            } else {
                tokens[tokens.count - 1] = Token(
                    word: tokens[tokens.count - 1].word, separator: currentSeparator
                )
            }
        }
        return (leading, tokens)
    }
}
