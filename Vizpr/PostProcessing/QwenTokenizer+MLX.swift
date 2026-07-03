import Foundation
import MLXLMCommon

/// Bridge the first-party tokenizer into mlx-swift-lm's Tokenizer protocol so
/// the LLM runtime uses it directly — no swift-transformers, no network code
/// in the binary (invariant 1), no third dependency (invariant 3).
extension QwenTokenizer: MLXLMCommon.Tokenizer {

    /// Qwen has no BOS and `add_bos_token: false`; special tokens in the input
    /// are already handled by the literal pre-scan, so the flag is inert.
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        encode(text)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        decode(tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenID(of: token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        token(of: id)
    }

    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }   // byte-level BPE: every byte is representable

    /// Render ChatML for the message shapes cleanup uses (system + user turns,
    /// generation prompt appended). Deliberately not a Jinja engine: the
    /// template's simple-chat branch is a fixed string shape, pinned token-for-
    /// token against the reference by the golden corpus.
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let turns = messages.compactMap { message -> (role: String, content: String)? in
            guard let role = message["role"] as? String,
                  let content = message["content"] as? String else { return nil }
            return (role, content)
        }
        return encodeChat(turns: turns)
    }
}
