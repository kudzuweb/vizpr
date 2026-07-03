import Foundation
import MLXLLM
import MLXLMCommon

enum MLXCleanupError: Error {
    case bundledModelMissing(String)
    case notPrepared
}

/// The cleanup LLM behind `CleanupEngine` (PLAN.md §10): Qwen3-4B-Instruct-2507
/// (4-bit MLX) via mlx-swift-lm — non-thinking (the Instruct-2507 template has
/// no thinking path), low temperature, deterministic.
///
/// Loads from the app bundle through `loadContainer(from:using:)` with the
/// FIRST-PARTY `QwenTokenizer` (golden-tested against the reference): nothing
/// in this path can reach the network, and no HF stack is linked (invariants
/// 1–3). Cancellation is cooperative: mlx-swift's decode loop checks
/// `Task.isCancelled` between steps, so abandoning the stream stops decoding
/// promptly — the strict-cancel guarantee the commit gate depends on.
actor MLXCleanup: CleanupEngine {
    /// Deterministic, low-temperature generation (§10 requirement 11).
    private static let temperature: Float = 0.1
    /// Cleanup rewrites a bounded span; cap output so a runaway generation
    /// can't stall the pipeline.
    private static let maxTokens = 400

    private let modelDirectory: URL
    private var container: ModelContainer?

    init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
            ?? Bundle.main.resourceURL!.appendingPathComponent("Models/cleanup-llm")
    }

    func prepare() async throws {
        guard container == nil else { return }
        let marker = modelDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw MLXCleanupError.bundledModelMissing(modelDirectory.path)
        }
        container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory, using: QwenTokenizerLoader()
        )
    }

    func clean(_ request: CleanupRequest) async throws -> CleanupResult {
        guard let container else { throw MLXCleanupError.notPrepared }

        let system = CleanupPrompt.system(for: request.context)
        let input = UserInput(chat: [.system(system), .user(request.text)])
        let parameters = GenerateParameters(
            maxTokens: Self.maxTokens, temperature: Self.temperature
        )

        let lmInput = try await container.prepare(input: input)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        var output = ""
        for await generation in stream {
            // Cooperative cancellation: bail as soon as the task is cancelled
            // (commit fired). Terminating the stream cancels the decode task.
            try Task.checkCancellation()
            if case let .chunk(text) = generation {
                output += text
            }
        }
        return CleanupResult(text: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Loads the first-party tokenizer for mlx-swift-lm's model factory.
struct QwenTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try QwenTokenizer(modelDirectory: directory)
    }
}
