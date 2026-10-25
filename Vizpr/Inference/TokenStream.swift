/// What the overlay renders: the three regions at one instant (PLAN.md §3).
/// `settled` is frozen (primary label color); `live` and `draft` are mutable
/// (secondary color). `displayed` is the exact string a commit would inject.
struct DisplaySnapshot: Sendable, Equatable {
    let settled: String
    let live: String
    let draft: String

    var displayed: String {
        var text = settled + live
        if !draft.isEmpty {
            text += SeamMerger.appendix(context: text, new: draft)
        }
        return text
    }

    /// The mutable (secondary-color) portion: EXACTLY `displayed` minus the
    /// settled prefix. The overlay renders settled + this — never its own
    /// reconstruction of live/draft (review finding: a synthetic joiner made
    /// the user proofread a string the commit didn't inject).
    var mutableSuffix: String {
        String(displayed.dropFirst(settled.count))
    }

    static let empty = DisplaySnapshot(settled: "", live: "", draft: "")
}

/// The single shared mutable object of the pipeline (PLAN.md §2, §3, §7): the
/// in-flight utterance as three regions, the settle policy, generation tags,
/// and the atomic commit gate. Actor isolation makes data races on it
/// impossible by construction.
///
/// Region contract:
/// - `settled` — frozen; will be injected verbatim. Settling is one-way and
///   monotonic: nothing in this type ever mutates settled except appending.
///   This is the user's "what I proofread is final" guarantee as code, pinned
///   by a randomized property test.
/// - `live` — finalized text whose cleanup has not resolved. Cleanup (PR 6)
///   may rewrite it, gated by generation tags. Live settles when the cleanup
///   launched for its current generation resolves (applied, failed, or never
///   launched because the gate skipped it): the complete sentences settle and
///   a trailing sentence fragment stays live, so a pause mid-sentence never
///   settles half a sentence ahead of the cleanup that sees the whole. A
///   result for an older generation settles nothing. As a backstop, text
///   older than `settledSentenceBacklog` sentences settles regardless, so live
///   stays bounded when cleanups keep going stale under fast speech.
/// - `draft` — the active window's tentative text; replaces per windowID.
///
/// Commit contract (§2, locked): `commit()` snapshots the displayed text,
/// cancels every registered cleanup task (strict cancel — never awaited), and
/// returns the string. Displayed-at-stop == injected, byte for byte.
actor TokenStream {
    /// Sentences that may stay live while cleanups are pending; older text
    /// settles even if no cleanup has resolved.
    static let settledSentenceBacklog = 2

    private(set) var settled = ""
    private(set) var live = ""
    private(set) var draft = ""
    private var draftWindowID = -1

    /// Live-region generation. Bumped whenever live changes (new finalized
    /// text, settling, applied cleanup). A cleanup result computed against an
    /// older generation is stale and silently dropped (§3, locked).
    private(set) var generation = 0

    /// Events arriving outside a session (post-commit stragglers from the
    /// engine's flush — field-observed) are ignored.
    private var sessionActive = false

    /// Cleanup invocations owned by the stream for structural cancellation
    /// (§7). A registry of Tasks rather than a literal TaskGroup: a TaskGroup
    /// cannot be held open across independent actor calls (apply/commit arrive
    /// as separate messages), so the registry is the faithful implementation
    /// of "commit cancels everything in flight" — recorded per invariant 11.
    private var cleanupTasks: [Int: Task<Void, Never>] = [:]
    private var nextCleanupID = 0

    private var snapshotContinuation: AsyncStream<DisplaySnapshot>.Continuation?

    /// Create THE display snapshot stream; only the latest matters, so older
    /// unconsumed snapshots are dropped. Single-consumer by design: calling
    /// again finishes any previous stream (rather than silently orphaning its
    /// consumer — review finding) and replaces it.
    func makeSnapshotStream() -> AsyncStream<DisplaySnapshot> {
        snapshotContinuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.snapshotContinuation = continuation
        }
    }

    // MARK: Session lifecycle

    func beginSession() {
        sessionActive = true
        resetRegions()
        publish()
    }

    /// Atomic commit (§2): snapshot displayed text, structurally cancel all
    /// in-flight cleanup, clear, return the snapshot. The returned string is
    /// exactly what the overlay showed at this instant — the injector applies
    /// zero transformation to it.
    func commit() -> String {
        let text = currentSnapshot().displayed
        endSession()
        return text
    }

    /// Escape: discard everything, inject nothing.
    func cancelSession() {
        endSession()
    }

    private func endSession() {
        for task in cleanupTasks.values { task.cancel() }
        cleanupTasks.removeAll()
        sessionActive = false
        resetRegions()
        publish()
    }

    private func resetRegions() {
        settled = ""
        live = ""
        draft = ""
        draftWindowID = -1
        // Monotonic FOREVER — increment, never reset. Cross-session staleness
        // rejection depends on generation never revisiting an old value: a
        // "tidy" refactor to generation = 0 per session would let a stale
        // cleanup from a prior session land once the counter climbed back to
        // its captured value (review finding). Do not reset.
        generation += 1
    }

    // MARK: Token events

    /// - Returns: the live-region generation after the event, which the caller
    ///   hands to `resolveLive` if it decides no cleanup will follow.
    @discardableResult
    func apply(_ event: TokenEvent) -> Int {
        guard sessionActive else { return generation }
        switch event {
        case let .draft(windowID, text):
            applyDraft(windowID: windowID, text: text)
        case let .finalized(text, _, _):
            applyFinalized(text)
        }
        return generation
    }

    private func applyDraft(windowID: Int, text: String) {
        // Same window: replace. Newer window: adopt. Older window: stale, drop.
        guard windowID >= draftWindowID else { return }
        draftWindowID = windowID
        draft = text
        publish()
    }

    private func applyFinalized(_ text: String) {
        // Bounded seam context (last ~200 chars): SeamMerger only inspects the
        // final character. Concatenating the whole settled string here would
        // make per-event work O(session length) — the acceptance criterion
        // demands it stays bounded.
        let addition = SeamMerger.appendix(context: seamContext(), new: text)
        if live.isEmpty, !settled.isEmpty {
            // Everything before this text settled. The separating space goes
            // with the settled side: cleanup returns trimmed text, so a space
            // left at the front of live would be lost when it rewrites live
            // and the words would join.
            let separator = addition.prefix { $0.isWhitespace }
            settled += separator
            live += addition.dropFirst(separator.count)
        } else {
            live += addition
        }
        // Bump on every accepted finalized event, even one that adds nothing
        // (a bare terminator the text already ends with): the draft is cleared
        // below, so the display changed, and any cleanup computed before this
        // event is stale (review finding — an empty addition previously left
        // generation unchanged).
        generation += 1
        // The finalized window supersedes its draft — and the draft FLOOR must
        // advance past it, or a straggler draft for the just-finalized window
        // (engine flush, field-observed) would pass the >= guard, resurrect
        // superseded text, and be injected at commit (review: critical).
        draft = ""
        draftWindowID += 1
        settle()
        publish()
    }

    /// The bounded tail of already-accepted text used for seam merging.
    private func seamContext() -> String {
        let budget = 200
        if live.count >= budget { return String(live.suffix(budget)) }
        return String(settled.suffix(budget - live.count)) + live
    }

    /// The backstop: move everything older than the trailing
    /// `settledSentenceBacklog` sentences from live into settled (§3). One-way:
    /// settled only ever grows by appending the exact prefix removed from live.
    private func settle() {
        let sentences = SentenceSplitter.split(live)
        guard sentences.count > Self.settledSentenceBacklog else { return }
        moveToSettled(sentences.prefix(sentences.count - Self.settledSentenceBacklog).joined())
    }

    /// Settle the complete sentences of live; a trailing fragment stays live.
    private func settleCompleteSentences() {
        let complete = SentenceSplitter.split(live).prefix { sentence in
            guard let last = sentence.last(where: { !$0.isWhitespace }) else { return false }
            return last == "." || last == "!" || last == "?"
        }
        moveToSettled(complete.joined())
    }

    private func moveToSettled(_ prefix: String) {
        guard !prefix.isEmpty else { return }
        settled += prefix
        live = String(live.dropFirst(prefix.count))
        generation += 1
    }

    // MARK: Cleanup gate (machinery for PR 6)

    /// Launch a cleanup operation owned by this stream (PR 6's entry point).
    /// The actor creates the task, registers it BEFORE any of its actor-visible
    /// effects can run (task-body effects on this actor serialize after this
    /// method), and auto-deregisters on completion — closing the review-found
    /// race where a self-managed task could finish before registration.
    ///
    /// The operation receives its own id, which it passes to `resolveLive` when
    /// it finishes without a result to apply.
    @discardableResult
    func launchCleanup(_ operation: @escaping @Sendable (_ cleanupID: Int) async -> Void) -> Int {
        let id = nextCleanupID
        nextCleanupID += 1
        let task = Task { [weak self] in
            await operation(id)
            await self?.deregisterCleanup(id)
        }
        cleanupTasks[id] = task
        return id
    }

    private func deregisterCleanup(_ id: Int) {
        cleanupTasks.removeValue(forKey: id)
    }

    /// Apply a cleanup rewrite of the live region — only if the live region is
    /// still the one the cleanup saw (§3: generation tags, stale results
    /// silently dropped). Returns whether it applied.
    ///
    /// CONTRACT for callers (PR 6): `rewrittenLive` replaces live verbatim and
    /// must preserve the settled|live boundary shape — cleanup sees only the
    /// live region, so it must not re-capitalize the first word, add leading
    /// whitespace, or otherwise reshape the seam with settled text it cannot
    /// see. The vocab post-pass runs BEFORE this call (post-pass wins ties).
    @discardableResult
    func applyCleanup(expectedGeneration: Int, rewrittenLive: String) -> Bool {
        guard sessionActive, expectedGeneration == generation else { return false }
        live = rewrittenLive
        generation += 1
        settleCompleteSentences()
        publish()
        return true
    }

    /// The cleanup for this generation will not rewrite live (the gate skipped
    /// it, cleanup is off, or it failed): settle the complete sentences of the
    /// text as it stands. Settles nothing when the generation moved on or when
    /// another cleanup is still running, whose result may rewrite an earlier
    /// span. `finishedCleanup` is the caller's own cleanup, which no longer
    /// counts as running.
    func resolveLive(generation expected: Int, finishedCleanup: Int? = nil) {
        if let finishedCleanup { cleanupTasks.removeValue(forKey: finishedCleanup) }
        guard sessionActive, expected == generation, cleanupTasks.isEmpty else { return }
        settleCompleteSentences()
        publish()
    }

    // MARK: Snapshot

    func currentSnapshot() -> DisplaySnapshot {
        DisplaySnapshot(settled: settled, live: live, draft: draft)
    }

    /// Snapshot the live region for a cleanup invocation (PR 6): the text to
    /// clean, the generation to tag the result with, and a bounded tail of
    /// settled text as context so cleanup — which rewrites only `live` — knows
    /// what precedes it and won't reshape the settled|live boundary.
    struct CleanupInput: Sendable {
        let text: String
        let generation: Int
        let settledContext: String
    }

    func cleanupInput() -> CleanupInput {
        CleanupInput(text: live, generation: generation, settledContext: String(settled.suffix(240)))
    }

    private func publish() {
        snapshotContinuation?.yield(currentSnapshot())
    }
}
