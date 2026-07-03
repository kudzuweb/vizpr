import Foundation
import Testing
@testable import Vizpr

private final class GoldenLocator {}

private struct GoldenCase: Decodable {
    let text: String
    let ids: [Int]
    let decoded: String
}

private struct GoldenChatExample: Decodable {
    let rendered: String
    let ids: [Int]
}

private struct Golden: Decodable {
    let eosTokenID: Int
    let cases: [GoldenCase]
    let chatTemplateExample: GoldenChatExample

    enum CodingKeys: String, CodingKey {
        case eosTokenID = "eos_token_id"
        case cases
        case chatTemplateExample = "chat_template_example"
    }
}

/// Whether the bundled cleanup model (with tokenizer.json) is present in the
/// host app bundle — fetched by scripts/fetch-models.sh, too large for git.
private var cleanupModelPresent: Bool {
    guard let url = Bundle.main.resourceURL?
        .appendingPathComponent("Models/cleanup-llm/tokenizer.json") else { return false }
    return FileManager.default.fileExists(atPath: url.path)
}

/// The first-party tokenizer's correctness contract: byte-for-byte token-ID
/// equality with the reference Qwen2Tokenizer on the golden corpus — 58
/// adversarial cases distilled from documented tokenizer failures across the
/// ecosystem (CamelCase regex divergence, upper/lower contractions, CJK,
/// combining marks, NBSP/format chars, CRLF+space, special tokens as literal
/// text, emoji adjacent to special tokens, code identifiers, real dictation
/// transcripts) plus the ChatML template rendering.
@Suite("QwenTokenizer golden", .enabled(if: cleanupModelPresent,
       "cleanup model missing — run scripts/fetch-models.sh and rebuild"))
struct QwenTokenizerGoldenTests {

    private func load() throws -> (QwenTokenizer, Golden) {
        let modelDir = Bundle.main.resourceURL!.appendingPathComponent("Models/cleanup-llm")
        let tokenizer = try QwenTokenizer(modelDirectory: modelDir)
        let goldenURL = try #require(Bundle(for: GoldenLocator.self)
            .url(forResource: "tokenizer-golden", withExtension: "json"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: goldenURL))
        return (tokenizer, golden)
    }

    @Test("Every golden case encodes to the reference token IDs")
    func encodeMatchesReference() throws {
        let (tokenizer, golden) = try load()
        for testCase in golden.cases {
            let ids = tokenizer.encode(testCase.text)
            #expect(ids == testCase.ids,
                    "encode mismatch for \(testCase.text.debugDescription): \(ids) != \(testCase.ids)")
        }
    }

    @Test("Every golden case decodes to the reference decode")
    func decodeMatchesReference() throws {
        let (tokenizer, golden) = try load()
        for testCase in golden.cases {
            let decoded = tokenizer.decode(testCase.ids)
            let message = "decode mismatch for \(testCase.text.debugDescription): "
                + "\(decoded.debugDescription) != \(testCase.decoded.debugDescription)"
            #expect(decoded == testCase.decoded, Comment(rawValue: message))
        }
    }

    @Test("ChatML render matches the reference template token-for-token")
    func chatTemplateMatches() throws {
        let (tokenizer, golden) = try load()
        let ids = tokenizer.encodeChat(
            system: "You clean up transcripts.", user: "helo wrld"
        )
        #expect(ids == golden.chatTemplateExample.ids,
                "chat template mismatch: \(ids) != \(golden.chatTemplateExample.ids)")
    }

    @Test("EOS token id matches the reference")
    func eosMatches() throws {
        let (tokenizer, golden) = try load()
        #expect(tokenizer.eosTokenID == golden.eosTokenID)
    }

    @Test("Byte map round-trips arbitrary UTF-8 losslessly")
    func byteMapRoundTrip() {
        let samples = ["hello", " Ġ already-mapped chars Ċ", "日本語", "🎉👍🏽",
                       "e\u{301} decomposed", "\r\n\t", "\u{00A0}\u{00AD}"]
        for sample in samples {
            let symbols = GPT2ByteMap.encode(sample)
            let bytes = GPT2ByteMap.decode(symbols.joined())
            // swiftlint:disable:next optional_data_string_conversion
            #expect(String(decoding: bytes, as: UTF8.self) == sample,
                    "byte map roundtrip failed for \(sample.debugDescription)")
        }
    }
}
