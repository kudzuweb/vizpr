import Testing
@testable import Vizpr

// MARK: - Deterministic PRNG (shared pattern with the PR 2 property tests)

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("TokenStream")
struct TokenStreamTests {

    private func stream() -> TokenStream {
        TokenStream()
    }

    // MARK: Regions

    @Test("Draft replaces per window; stale windows are dropped")
    func draftReplacement() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.draft(windowID: 0, text: "hello wor"))
        await ts.apply(.draft(windowID: 0, text: "hello world"))
        #expect(await ts.draft == "hello world")

        await ts.apply(.draft(windowID: 1, text: "new window"))
        #expect(await ts.draft == "new window")

        await ts.apply(.draft(windowID: 0, text: "stale"))   // dropped
        #expect(await ts.draft == "new window")
    }

    @Test("Finalized text lands in live and clears the draft")
    func finalizedClearsDraft() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.draft(windowID: 0, text: "hello wor"))
        await ts.apply(.finalized(text: "Hello world.", confidence: 0.9, tokenConfidences: []))
        #expect(await ts.live == "Hello world.")
        #expect(await ts.draft.isEmpty)
    }

    @Test("A straggler draft for a just-finalized window cannot resurrect text")
    func staleDraftAfterFinalizeRejected() async {
        // Critical review finding: applyFinalized must advance the draft floor,
        // or an engine-flush straggler draft for the finalized window passes the
        // >= guard, resurrects superseded text, and gets injected at commit.
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.draft(windowID: 5, text: "just a rem"))
        await ts.apply(.finalized(text: "The meeting is set.", confidence: 0.9, tokenConfidences: []))
        await ts.apply(.draft(windowID: 5, text: "Just a remark"))   // stale straggler
        #expect(await ts.draft.isEmpty, "stale same-window draft resurrected")
        #expect(await ts.commit() == "The meeting is set.")
    }

    @Test("A draft continues the live tail with a space and repeats nothing")
    func draftContinuesLiveTail() async {
        // Drafts start at the confirmed boundary, so a draft never re-covers
        // the final before it.
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "We say negligent discharge",
                                  confidence: 0.9, tokenConfidences: []))
        await ts.apply(.draft(windowID: 1, text: "for a reason"))
        let displayed = await ts.currentSnapshot().displayed
        #expect(displayed == "We say negligent discharge for a reason")
    }

    @Test("Backstop: text older than two sentences settles even with no cleanup resolved")
    func settleBackstop() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "One. Two. Three. Four.", confidence: 0.9, tokenConfidences: []))
        #expect(await ts.settled == "One. Two. ")
        #expect(await ts.live == "Three. Four.")
    }

    @Test("Events outside a session are ignored (post-commit stragglers)")
    func stragglersIgnored() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "Session text.", confidence: 0.9, tokenConfidences: []))
        _ = await ts.commit()
        // The engine's flush can deliver one more final after commit.
        await ts.apply(.finalized(text: "Straggler.", confidence: 0.9, tokenConfidences: []))
        #expect(await ts.currentSnapshot() == .empty)
    }

    // MARK: Commit contract

    @Test("Commit returns exactly the displayed text, including the draft")
    func commitIsDisplayedText() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "Confirmed part.", confidence: 0.9, tokenConfidences: []))
        await ts.apply(.draft(windowID: 1, text: "trailing draft"))
        let displayed = await ts.currentSnapshot().displayed
        let committed = await ts.commit()
        #expect(committed == displayed)
        #expect(committed == "Confirmed part. trailing draft")
    }

    @Test("Commit cancels in-flight cleanup; late results never apply")
    func commitCancelsCleanup() async throws {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "Some text.", confidence: 0.9, tokenConfidences: []))
        let generationSeen = await ts.generation

        // A cleanup that records observing its own cancellation. AtomicCounter
        // is a Sendable reference (unlike move-only Atomic), so the closure can
        // share it with the test.
        let cancelObserved = AtomicCounter()
        _ = await ts.launchCleanup { _ in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            cancelObserved.increment()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)   // let it start looping

        _ = await ts.commit()
        // Structural cancellation: cancelled at commit, not awaited.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let wasCancelled = cancelObserved.value > 0
        #expect(wasCancelled)
        // A result computed against the old generation provably never applies.
        let applied = await ts.applyCleanup(expectedGeneration: generationSeen, rewrittenLive: "HACKED")
        #expect(!applied)
        #expect(await ts.currentSnapshot() == .empty)
    }

    @Test("Cancel discards everything and injects nothing")
    func cancelDiscards() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "Discard me.", confidence: 0.9, tokenConfidences: []))
        await ts.cancelSession()
        #expect(await ts.currentSnapshot() == .empty)
    }

    // MARK: Cleanup gate

    @Test("Cleanup applies only at the exact generation it was given")
    func cleanupGenerationGate() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "helo world.", confidence: 0.5, tokenConfidences: []))
        let gen = await ts.generation

        // New tokens arrive: the live region moved on.
        await ts.apply(.finalized(text: "More text.", confidence: 0.9, tokenConfidences: []))
        #expect(await !ts.applyCleanup(expectedGeneration: gen, rewrittenLive: "Hello world."))

        // A fresh result against the current generation applies, and its
        // complete sentences settle.
        let current = await ts.generation
        #expect(await ts.applyCleanup(expectedGeneration: current, rewrittenLive: "Hello world. More text."))
        #expect(await ts.settled == "Hello world. More text.")
        #expect(await ts.live.isEmpty)
        // Applying bumped the generation: replaying the same result is stale.
        #expect(await !ts.applyCleanup(expectedGeneration: current, rewrittenLive: "replay"))
    }

    // MARK: Settling as cleanup resolves

    @Test("An applied cleanup settles the complete sentences of its rewrite and leaves a fragment live")
    func appliedCleanupSettlesCompleteSentences() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "helo world. how are", confidence: 0.5, tokenConfidences: []))
        let generation = await ts.generation
        #expect(await ts.applyCleanup(expectedGeneration: generation, rewrittenLive: "Hello world. How are"))
        #expect(await ts.settled == "Hello world. ")
        #expect(await ts.live == "How are")
    }

    @Test("A skipped cleanup settles the complete sentences of the raw text")
    func skippedCleanupSettles() async {
        let ts = stream()
        await ts.beginSession()
        let generation = await ts.apply(.finalized(
            text: "We shipped it. Then we", confidence: 0.95, tokenConfidences: []
        ))
        await ts.resolveLive(generation: generation)
        #expect(await ts.settled == "We shipped it. ")
        #expect(await ts.live == "Then we")
    }

    @Test("A skip while another cleanup is running settles nothing")
    func skipWhileCleanupRunningSettlesNothing() async {
        let ts = stream()
        await ts.beginSession()
        await ts.apply(.finalized(text: "helo world.", confidence: 0.5, tokenConfidences: []))
        let release = AtomicCounter()
        _ = await ts.launchCleanup { _ in
            while release.value == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let generation = await ts.apply(.finalized(text: "More text.", confidence: 0.95, tokenConfidences: []))
        await ts.resolveLive(generation: generation)
        #expect(await ts.settled.isEmpty)
        #expect(await ts.live == "helo world. More text.")
        release.increment()
    }

    @Test("A resolution for an older generation settles nothing")
    func staleResolutionSettlesNothing() async {
        let ts = stream()
        await ts.beginSession()
        let old = await ts.apply(.finalized(text: "First one.", confidence: 0.95, tokenConfidences: []))
        await ts.apply(.finalized(text: "Second one.", confidence: 0.95, tokenConfidences: []))
        await ts.resolveLive(generation: old)
        #expect(await ts.settled.isEmpty)
    }

    @Test("A skip blocked by a running cleanup settles when that cleanup returns stale")
    func blockedSkipRetriedWhenCleanupsDrain() async throws {
        let ts = stream()
        await ts.beginSession()
        let first = await ts.apply(.finalized(text: "First one.", confidence: 0.5, tokenConfidences: []))
        let release = AtomicCounter()
        _ = await ts.launchCleanup { _ in
            while release.value == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
            // The second final moved the generation on, so this result is stale.
            _ = await ts.applyCleanup(expectedGeneration: first, rewrittenLive: "First one!")
        }
        let second = await ts.apply(.finalized(text: "Second one.", confidence: 0.95, tokenConfidences: []))
        await ts.resolveLive(generation: second)
        #expect(await ts.settled.isEmpty)

        release.increment()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await ts.settled == "First one. Second one.")
        #expect(await ts.live.isEmpty)
    }

    @Test("A cleanup that fails settles the raw text it was given")
    func failedCleanupSettles() async throws {
        let ts = stream()
        await ts.beginSession()
        let generation = await ts.apply(.finalized(text: "Raw text.", confidence: 0.5, tokenConfidences: []))
        _ = await ts.launchCleanup { id in
            await ts.resolveLive(generation: generation, finishedCleanup: id)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await ts.settled == "Raw text.")
    }

    @Test("The space before the next final goes with the settled text, so a cleanup rewrite cannot join words")
    func separatorAfterFullSettle() async {
        let ts = stream()
        await ts.beginSession()
        let first = await ts.apply(.finalized(text: "Hello there.", confidence: 0.95, tokenConfidences: []))
        await ts.resolveLive(generation: first)
        #expect(await ts.live.isEmpty)

        let second = await ts.apply(.finalized(text: "Next one", confidence: 0.5, tokenConfidences: []))
        #expect(await ts.settled == "Hello there. ")
        #expect(await ts.live == "Next one")

        // Cleanup returns trimmed text; the display must still read as written.
        #expect(await ts.applyCleanup(expectedGeneration: second, rewrittenLive: "Next one"))
        #expect(await ts.currentSnapshot().displayed == "Hello there. Next one")
    }

    // MARK: Long-session bounds

    @Test("Long latched session: live stays bounded, settled only grows")
    func longSessionBounded() async {
        let ts = stream()
        await ts.beginSession()
        var settledLength = 0
        for index in 0..<300 {
            await ts.apply(.finalized(
                text: "Sentence number \(index).", confidence: 0.9, tokenConfidences: []
            ))
            let settled = await ts.settled
            #expect(settled.count >= settledLength, "settled shrank")
            settledLength = settled.count
        }
        let liveSentences = SentenceSplitter.split(await ts.live).count
        #expect(liveSentences <= 2)
        #expect(settledLength > 0)
    }
}

// MARK: - Property tests

@Suite("TokenStream invariants")
struct TokenStreamPropertyTests {

    private func randomWord(_ rng: inout SplitMix64) -> String {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        return words[Int(rng.next() % UInt64(words.count))]
    }

    private func randomText(_ rng: inout SplitMix64) -> String {
        let count = 1 + Int(rng.next() % 6)
        var text = (0..<count).map { _ in randomWord(&rng) }.joined(separator: " ")
        if rng.next() % 2 == 0 { text += "." }
        return text
    }

    /// THE load-bearing invariant (PLAN.md §8b): no event sequence ever changes
    /// settled text — settling is append-only, and neither drafts, finals,
    /// stale cleanup, fresh cleanup, nor straggler events may rewrite it.
    @Test("Settle monotonicity: settled only ever extends, never mutates")
    func settleMonotonicity() async {
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(seed: seed)
            let ts = TokenStream()
            await ts.beginSession()
            var previousSettled = ""
            var windowID = 0

            for _ in 0..<120 {
                switch rng.next() % 12 {
                case 0...2:
                    // Sometimes redraft an OLD window (generator gap from review:
                    // stale same-window drafts after a finalize must not mutate
                    // settled — or resurrect anything).
                    let wid = rng.next() % 3 == 0 ? max(0, windowID - 1) : windowID
                    await ts.apply(.draft(windowID: wid, text: randomText(&rng)))
                case 3...6:
                    await ts.apply(.finalized(
                        text: randomText(&rng), confidence: 0.9, tokenConfidences: []
                    ))
                    windowID += 1   // finalize always advances the window
                case 7:
                    // Cleanup with a randomly chosen (usually stale) generation.
                    let guess = Int(rng.next() % 40)
                    await ts.applyCleanup(
                        expectedGeneration: guess, rewrittenLive: randomText(&rng)
                    )
                case 8:
                    // Cleanup against the CURRENT generation — applies, and must
                    // still never touch settled.
                    let current = await ts.generation
                    await ts.applyCleanup(
                        expectedGeneration: current, rewrittenLive: randomText(&rng)
                    )
                case 10:
                    await ts.resolveLive(generation: await ts.generation)
                case 11:
                    await ts.resolveLive(generation: Int(rng.next() % 40))
                default:
                    // Straggler outside session boundaries is exercised in the
                    // session-boundary property below; here keep feeding.
                    await ts.apply(.draft(windowID: windowID, text: randomText(&rng)))
                }

                let settled = await ts.settled
                #expect(settled.hasPrefix(previousSettled),
                        "settled mutated (seed \(seed)): '\(previousSettled)' -> '\(settled)'")
                previousSettled = settled
            }
        }
    }

    /// Commit atomicity across random histories: the committed string always
    /// equals the displayed snapshot at the commit instant, and afterwards the
    /// stream is empty and rejects everything until a new session.
    @Test("Commit returns the displayed snapshot and seals the session")
    func commitSeals() async {
        for seed in UInt64(1)...100 {
            var rng = SplitMix64(seed: seed)
            let ts = TokenStream()
            await ts.beginSession()
            for _ in 0..<(5 + rng.next() % 40) {
                if rng.next() % 3 == 0 {
                    await ts.apply(.draft(windowID: Int(rng.next() % 5), text: randomText(&rng)))
                } else {
                    await ts.apply(.finalized(
                        text: randomText(&rng), confidence: 0.9, tokenConfidences: []
                    ))
                }
            }
            let displayed = await ts.currentSnapshot().displayed
            let committed = await ts.commit()
            #expect(committed == displayed, "commit != displayed (seed \(seed))")

            // Sealed: stragglers and cleanup — even with a correctly guessed
            // generation — must bounce off an inactive session.
            await ts.apply(.finalized(text: "straggler", confidence: 0.9, tokenConfidences: []))
            let generation = await ts.generation
            let applied = await ts.applyCleanup(expectedGeneration: generation, rewrittenLive: "x")
            #expect(!applied, "post-commit cleanup applied to a sealed session (seed \(seed))")
            #expect(await ts.currentSnapshot() == .empty, "session not sealed (seed \(seed))")
        }
    }
}
