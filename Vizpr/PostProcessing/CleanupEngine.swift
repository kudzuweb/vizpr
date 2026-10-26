/// Context handed to the cleanup engine alongside the text (PLAN.md §10, §11).
/// The AX-context slot is empty until PR 10 (FieldContextReader).
struct CleanupContext: Sendable, Equatable {
    /// Surrounding text of the focused field, if readable (PR 10). nil elsewhere.
    var surroundingText: String?
    /// Frontmost app's bundle id, for app-specific behavior.
    var bundleID: String?
    /// Whether the target looks like code (CodeDetector, PR 10) — enables code mode.
    var codeMode: Bool
    /// Vocabulary terms to make the model aware they exist (post-pass stays
    /// authoritative regardless).
    var vocabularyHint: String
    /// Context-profile style directives (PR 11 buckets): free-text rules the
    /// active bucket imposes ("no capitalization"). Prompt-enforced.
    var styleRules: String?

    static let empty = CleanupContext(
        surroundingText: nil, bundleID: nil, codeMode: false, vocabularyHint: "",
        styleRules: nil
    )
}

/// A cleanup request: the live-region text to clean plus context.
struct CleanupRequest: Sendable, Equatable {
    let text: String
    let context: CleanupContext
}

/// A cleanup result: the cleaned text. (Kept a struct for forward-compat with
/// per-request metadata the dev logger records in PR 7.)
struct CleanupResult: Sendable, Equatable {
    let text: String
    /// When the first decoded chunk arrived; measured in dev-log builds only.
    var firstTokenAt: ContinuousClock.Instant?
}

/// Abstraction over the cleanup LLM (PLAN.md §11). The pipeline depends only on
/// this seam; the default conformer is `MLXCleanup` (Qwen3-4B via mlx-swift).
///
/// `clean` MUST be cooperatively cancellable — it checks `Task.isCancelled`
/// between decode steps and abandons promptly (this is what makes the WYSIWYG
/// strict-cancel real, and it is an acceptance criterion). mlx-swift's decode
/// loop checks Task cancellation for us; conformers just need to stop consuming.
protocol CleanupEngine: Sendable {
    /// Load the model and become ready. Fails loudly if assets are missing.
    func prepare() async throws

    /// Clean one request. Cooperatively cancellable via the calling Task.
    func clean(_ request: CleanupRequest) async throws -> CleanupResult
}
