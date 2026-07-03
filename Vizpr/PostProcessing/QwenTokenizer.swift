import Foundation

/// First-party byte-level BPE tokenizer for the bundled Qwen model (PR 6b).
///
/// Written fresh (invariant 2) instead of depending on swift-transformers,
/// whose Tokenizers product statically links Hub's URLSession download client —
/// unacceptable in a mic+Accessibility process with a verified zero-egress
/// guarantee (invariant 1). Correctness is pinned by a golden corpus generated
/// from the reference tokenizer (58 adversarial cases including every failure
/// mode documented across the ecosystem — see VizprTests/Fixtures/).
///
/// Design rules distilled from others' documented failures:
/// - Split ADDED/SPECIAL tokens out before anything else (GPT-2/minGPT/Qwen all
///   shipped the "<|endoftext|> becomes 7 tokens" bug), scanning with
///   scalar-safe ranges (swift-transformers #210: Character-index math split a
///   special token adjacent to emoji).
/// - NFC-normalize BEFORE byte-encoding (vocabularies are built on NFC; NFD
///   input hits different merges).
/// - Pre-tokenize with NSRegularExpression compiled once (Swift Regex
///   backtracks quadratically), with `(?i:'s…)` expanded to explicit case
///   alternatives (no inline-group flags in ICU's NSRegularExpression).
/// - Work on unicode scalars / bytes, never Character (grapheme clustering
///   fuses combining marks and corrupts merges — swift-transformers #52/#355).
/// - BPE merge loop on integer token IDs with ranks in a packed-UInt64 dict
///   (string-pair keys hash slowly; naive O(n²) scans are 1000x slower).
struct QwenTokenizer: Sendable {

    enum LoadError: Error {
        case fileMissing(String)
        case malformed(String)
    }

    // Vocab and merges, integerized at load.
    private let tokenToID: [String: Int]
    private let idToToken: [Int: String]
    /// Merge ranks keyed by (leftID << 32 | rightID). Merged pair -> its rank;
    /// the merged token's ID is looked up from the concatenated string once at
    /// load into `mergeResult` to keep the hot loop string-free.
    private let mergeRank: [UInt64: Int]
    private let mergeResult: [UInt64: Int]

    /// Added/special tokens, sorted longest-first for greedy literal scanning.
    private let addedTokens: [(text: String, id: Int)]
    private let addedTokenIDs: Set<Int>

    let eosTokenID: Int      // <|im_end|>
    let padTokenID: Int      // <|endoftext|>

    private let preTokenizer: NSRegularExpression

    // MARK: Loading

    /// Load from a model directory containing tokenizer.json (HF fast format).
    init(modelDirectory: URL) throws {
        let url = modelDirectory.appendingPathComponent("tokenizer.json")
        guard let data = try? Data(contentsOf: url) else {
            throw LoadError.fileMissing(url.path)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocab = model["vocab"] as? [String: Int],
            let merges = model["merges"] as? [[String]]
        else {
            throw LoadError.malformed("tokenizer.json missing model/vocab/merges")
        }

        var tokenToID = vocab
        var idToToken = [Int: String](minimumCapacity: vocab.count)
        for (token, id) in vocab { idToToken[id] = token }

        // Added tokens override/extend the vocab and are matched literally.
        var added: [(String, Int)] = []
        if let addedList = root["added_tokens"] as? [[String: Any]] {
            for entry in addedList {
                guard let content = entry["content"] as? String,
                      let id = entry["id"] as? Int else { continue }
                added.append((content, id))
                tokenToID[content] = id
                idToToken[id] = content
            }
        }
        self.addedTokens = added.sorted { $0.0.count > $1.0.count }
        self.addedTokenIDs = Set(added.map(\.1))
        self.tokenToID = tokenToID
        self.idToToken = idToToken

        (self.mergeRank, self.mergeResult) = Self.integerizeMerges(merges, vocab: tokenToID)

        guard let eos = tokenToID["<|im_end|>"], let pad = tokenToID["<|endoftext|>"] else {
            throw LoadError.malformed("ChatML control tokens missing from vocab")
        }
        self.eosTokenID = eos
        self.padTokenID = pad

        // Qwen2 split pattern with (?i:…) expanded to explicit case
        // alternatives (ICU NSRegularExpression has no inline-group flags).
        // Everything else is verbatim from the model's tokenizer.json.
        let pattern = "(?:'[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])"
            + "|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+"
            + "|\\p{N}"
            + "| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*"
            + "|\\s*[\\r\\n]+"
            + "|\\s+(?!\\S)"
            + "|\\s+"
        self.preTokenizer = try NSRegularExpression(pattern: pattern)
    }

    /// Integerize merges: rank = list index; result = id of the concatenation.
    private static func integerizeMerges(
        _ merges: [[String]], vocab: [String: Int]
    ) -> ([UInt64: Int], [UInt64: Int]) {
        var rank = [UInt64: Int](minimumCapacity: merges.count)
        var result = [UInt64: Int](minimumCapacity: merges.count)
        for (index, pair) in merges.enumerated() {
            guard pair.count == 2,
                  let left = vocab[pair[0]], let right = vocab[pair[1]],
                  let merged = vocab[pair[0] + pair[1]] else { continue }
            let key = (UInt64(UInt32(left)) << 32) | UInt64(UInt32(right))
            rank[key] = index
            result[key] = merged
        }
        return (rank, result)
    }

    // MARK: Encode

    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int] = []
        // 1. Split out added/special tokens FIRST, matched literally on the
        //    untouched text (they must never be normalized or BPE-merged).
        for segment in splitOnAddedTokens(text) {
            switch segment {
            case let .special(id):
                ids.append(id)
            case let .plain(chunk):
                encodePlain(chunk, into: &ids)
            }
        }
        return ids
    }

    private enum Segment {
        case special(Int)
        case plain(Substring)
    }

    /// Literal, longest-first scan for added tokens using String ranges (never
    /// Character-count offset math — see swift-transformers #210).
    private func splitOnAddedTokens(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            var matched = false
            for (token, id) in addedTokens where text[cursor...].hasPrefix(token) {
                segments.append(.special(id))
                cursor = text.index(cursor, offsetBy: token.count)
                matched = true
                break
            }
            if matched { continue }
            // Advance to the next possible special-token start ('<' begins all
            // of Qwen's added tokens); everything before it is plain text.
            let next = text[text.index(after: cursor)...].firstIndex(of: "<") ?? text.endIndex
            segments.append(.plain(text[cursor..<next]))
            cursor = next
        }
        return coalescePlain(segments)
    }

    /// Merge adjacent plain segments (the '<' scanner can fragment them).
    private func coalescePlain(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments {
            if case let .plain(chunk) = segment, case let .plain(previous)? = out.last,
               previous.endIndex == chunk.startIndex {
                out[out.count - 1] = .plain(previous.base[previous.startIndex..<chunk.endIndex])
            } else {
                out.append(segment)
            }
        }
        return out
    }

    private func encodePlain(_ chunk: Substring, into ids: inout [Int]) {
        guard !chunk.isEmpty else { return }
        // 2. NFC-normalize BEFORE byte-encoding (merge tables assume NFC).
        let normalized = String(chunk).precomposedStringWithCanonicalMapping
        // 3. Pre-tokenize with the (expanded) Qwen2 split regex.
        let ns = normalized as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        preTokenizer.enumerateMatches(in: normalized, range: fullRange) { match, _, _ in
            guard let match else { return }
            let piece = ns.substring(with: match.range)
            // 4. Byte-encode to the GPT-2 unicode alphabet, then 5. BPE.
            ids.append(contentsOf: bpe(GPT2ByteMap.encode(piece)))
        }
    }

    /// BPE merge loop on integer IDs: repeatedly merge the lowest-rank adjacent
    /// pair. Inputs are pre-tokenizer pieces (typically < 20 symbols), so a
    /// linear rescan per merge is O(n·merges-applied) with tiny constants —
    /// simpler than a heap and comfortably fast at this piece size. The
    /// rank/result tables are integer-keyed; no strings in the loop.
    private func bpe(_ byteTokens: [String]) -> [Int] {
        var ids = byteTokens.compactMap { tokenToID[$0] }
        guard ids.count == byteTokens.count else { return ids }   // defensive; 256-alphabet is total

        while ids.count >= 2 {
            var bestRank = Int.max
            var bestIndex = -1
            for left in 0 ..< ids.count - 1 {
                let key = (UInt64(UInt32(ids[left])) << 32) | UInt64(UInt32(ids[left + 1]))
                if let rank = mergeRank[key], rank < bestRank {
                    bestRank = rank
                    bestIndex = left
                }
            }
            guard bestIndex >= 0 else { break }
            let key = (UInt64(UInt32(ids[bestIndex])) << 32) | UInt64(UInt32(ids[bestIndex + 1]))
            guard let merged = mergeResult[key] else { break }
            ids.replaceSubrange(bestIndex ... bestIndex + 1, with: [merged])
        }
        return ids
    }

    // MARK: Decode

    func decode(_ ids: [Int], skipSpecialTokens: Bool = false) -> String {
        var bytes: [UInt8] = []
        var out = ""
        func flushBytes() {
            if !bytes.isEmpty {
                // Lossy-replacement decode is CORRECT here: invalid UTF-8 mid-
                // stream becomes U+FFFD, matching the reference ByteLevel
                // decoder's errors=replace semantics (pinned by golden decode).
                // swiftlint:disable:next optional_data_string_conversion
                out += String(decoding: bytes, as: UTF8.self)
                bytes.removeAll(keepingCapacity: true)
            }
        }
        for id in ids {
            if addedTokenIDs.contains(id) {
                // Added tokens are raw text, never byte-mapped (decoding them
                // through the byte table corrupts unicode — tokenizers #1996).
                flushBytes()
                if !skipSpecialTokens, let token = idToToken[id] { out += token }
            } else if let token = idToToken[id] {
                bytes.append(contentsOf: GPT2ByteMap.decode(token))
            }
        }
        flushBytes()
        return out
    }

    // MARK: Vocabulary access

    func tokenID(of token: String) -> Int? { tokenToID[token] }
    func token(of id: Int) -> String? { idToToken[id] }

    // MARK: ChatML

    /// Render + encode the ChatML prompt for one system+user exchange with the
    /// generation prompt, matching the model's chat template for this shape.
    /// (Deliberately not a Jinja engine: cleanup only ever uses this shape.)
    func encodeChat(system: String, user: String) -> [Int] {
        encodeChat(turns: [("system", system), ("user", user)])
    }

    /// General simple-chat form: each turn rendered as
    /// `<|im_start|>role\ncontent<|im_end|>\n`, generation prompt appended.
    func encodeChat(turns: [(role: String, content: String)]) -> [Int] {
        var ids: [Int] = []
        let imStart = tokenToID["<|im_start|>"] ?? 0
        for turn in turns {
            ids.append(imStart)
            ids.append(contentsOf: encode(turn.role + "\n" + turn.content))
            ids.append(eosTokenID)
            ids.append(contentsOf: encode("\n"))
        }
        ids.append(imStart)
        ids.append(contentsOf: encode("assistant\n"))
        return ids
    }
}

/// The GPT-2 byte<->unicode bijection, generated from its defining algorithm
/// (not transcribed): printable bytes map to themselves; the remaining 68 bytes
/// map sequentially to U+0100+. Space becomes "Ġ", newline "Ċ" — the alphabet
/// the vocab and merges are written in.
enum GPT2ByteMap {
    private static let tables: (encode: [String], decode: [Character: UInt8]) = {
        var byteToChar = [Character](repeating: " ", count: 256)
        var charToByte = [Character: UInt8](minimumCapacity: 256)
        var next = 0x100
        for byte in 0...255 {
            let isPrintable = (33...126).contains(byte) || (161...172).contains(byte)
                || (174...255).contains(byte)
            let scalar = isPrintable ? Unicode.Scalar(byte)! : Unicode.Scalar(next)!
            if !isPrintable { next += 1 }
            let char = Character(scalar)
            byteToChar[byte] = char
            charToByte[char] = UInt8(byte)
        }
        return (byteToChar.map(String.init), charToByte)
    }()

    /// UTF-8 bytes of `piece`, each mapped into the unicode alphabet, split
    /// into single-character token strings (BPE's initial symbols).
    static func encode(_ piece: String) -> [String] {
        piece.utf8.map { tables.encode[Int($0)] }
    }

    /// Reverse-map a vocab token's characters to raw bytes.
    static func decode(_ token: String) -> [UInt8] {
        token.compactMap { tables.decode[$0] }
    }
}
