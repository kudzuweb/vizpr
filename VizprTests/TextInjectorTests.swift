import Foundation
import Testing
@testable import Vizpr

// MARK: Fakes

@MainActor
private final class FakePasteboard: PasteboardWriting {
    private(set) var changeCount = 0
    private(set) var contents: PasteboardContents = .init(items: [])
    private(set) var writtenText: String?
    private(set) var writtenTag: String?
    private(set) var restored: PasteboardContents?
    var concealed = false

    // Independent simulation knobs: the ownership guard is a CONJUNCTION of
    // changeCount and tag, so tests must be able to break each alone.
    var tagDestroyed = false

    var containsConcealedContent: Bool { concealed }

    func snapshot() -> PasteboardContents {
        snapshotCount += 1
        return contents
    }
    private(set) var snapshotCount = 0

    func write(_ text: String, tag: String) -> Int {
        writtenText = text
        writtenTag = tag
        tagDestroyed = false
        changeCount += 1
        return changeCount
    }

    func hasTag(_ tag: String) -> Bool { writtenTag == tag && !tagDestroyed }

    func restore(_ contents: PasteboardContents, expectedChangeCount: Int) -> Bool {
        guard changeCount == expectedChangeCount else { return false }
        restored = contents
        changeCount += 1
        return true
    }

    /// A foreign write: bumps the count AND destroys the tag (real semantics).
    func simulateUserCopy() {
        tagDestroyed = true
        changeCount += 1
    }

    /// Pathological: count moves but our tag item somehow survives.
    func simulateCountBumpOnly() { changeCount += 1 }

    /// Pathological: tag gone but count untouched.
    func simulateTagLossOnly() { tagDestroyed = true }

    func seed(_ contents: PasteboardContents) { self.contents = contents }
}

@MainActor
private final class FakePoster: EventPosting {
    var chordSucceeds = true
    var fallbackSucceeds = true
    private(set) var chordCount = 0
    private(set) var fallbackCount = 0
    /// Runs during the chord — the window in which a user copy can race.
    var onChord: (() -> Void)?

    func postPasteChord() -> Bool {
        chordCount += 1
        onChord?()
        return chordSucceeds
    }

    func fallbackPaste() -> Bool {
        fallbackCount += 1
        return fallbackSucceeds
    }
}

@MainActor
private final class FakeSecureInput: SecureInputProbing {
    var isSecureInputActive = false
}

private func plainText(_ text: String) -> PasteboardContents {
    PasteboardContents(items: [[PasteboardEntry(
        type: "public.utf8-plain-text", data: Data(text.utf8)
    )]])
}

// MARK: Tests

@MainActor
@Suite("TextInjector")
struct TextInjectorTests {

    private func makeInjector(
        pasteboard: FakePasteboard,
        poster: FakePoster,
        secure: FakeSecureInput = FakeSecureInput(),
        restoreEnabled: Bool = true,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TextInjector {
        TextInjector(
            pasteboard: pasteboard, poster: poster, secureInput: secure,
            restoreDelay: .zero, restoreEnabled: restoreEnabled, now: { now }
        )
    }

    @Test("The commit snapshot is a byte-intact suffix of the pasted string")
    func byteEquality() async {
        let pasteboard = FakePasteboard()
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        // Adversarial snapshot: multibyte, combining marks, trailing space.
        let snapshot = "naïve café — 日本語 🎉 e\u{301} end "
        let outcome = await injector.inject(snapshot)

        #expect(outcome == .injected(usedFallback: false))
        #expect(pasteboard.writtenText == snapshot)
    }

    @Test("Byte equality holds for a JOINED second segment too")
    func byteEqualityJoined() async {
        let pasteboard = FakePasteboard()
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        _ = await injector.inject("First segment")
        let second = "ñe\u{301}xt — 日本 🎉"
        _ = await injector.inject(second)

        let pasted = pasteboard.writtenText ?? ""
        #expect(pasted == " " + second)
        #expect(Array(pasted.utf8).suffix(second.utf8.count) == Array(second.utf8),
                "snapshot bytes not intact after joining")
    }

    @Test("Ownership guard: clean window restores the prior clipboard")
    func restoreWhenUnowned() async {
        let pasteboard = FakePasteboard()
        let prior = plainText("mine")
        pasteboard.seed(prior)
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        _ = await injector.inject("hello.")
        await injector.settleForTesting()
        #expect(pasteboard.restored == prior)
    }

    @Test("Ownership guard: a user copy mid-paste is never clobbered")
    func noClobberOnUserCopy() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(plainText("old"))
        let poster = FakePoster()
        poster.onChord = { pasteboard.simulateUserCopy() }
        let injector = makeInjector(pasteboard: pasteboard, poster: poster)

        let outcome = await injector.inject("hello.")
        await injector.settleForTesting()
        #expect(outcome == .injected(usedFallback: false))
        #expect(pasteboard.restored == nil, "restore ran over the user's copy")
    }

    @Test("Ownership guard conjuncts fail independently")
    func guardConjuncts() async {
        // Count moved, tag intact → no restore.
        let boardA = FakePasteboard()
        boardA.seed(plainText("a"))
        let posterA = FakePoster()
        posterA.onChord = { boardA.simulateCountBumpOnly() }
        let injectorA = makeInjector(pasteboard: boardA, poster: posterA)
        _ = await injectorA.inject("x.")
        await injectorA.settleForTesting()
        #expect(boardA.restored == nil, "count-moved alone must veto restore")

        // Tag gone, count untouched → no restore.
        let boardB = FakePasteboard()
        boardB.seed(plainText("b"))
        let posterB = FakePoster()
        posterB.onChord = { boardB.simulateTagLossOnly() }
        let injectorB = makeInjector(pasteboard: boardB, poster: posterB)
        _ = await injectorB.inject("x.")
        await injectorB.settleForTesting()
        #expect(boardB.restored == nil, "tag-loss alone must veto restore")
    }

    @Test("Concealed clipboard content is never snapshotted or restored")
    func concealedNeverCaptured() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(plainText("hunter2"))
        pasteboard.concealed = true
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        let outcome = await injector.inject("hello.")
        await injector.settleForTesting()
        #expect(outcome == .injected(usedFallback: false), "paste itself must proceed")
        #expect(pasteboard.snapshotCount == 0, "captured a concealed secret")
        #expect(pasteboard.restored == nil)
    }

    @Test("Restore disabled: no snapshot is taken and nothing is restored")
    func restoreDisabled() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(plainText("x"))
        let injector = makeInjector(
            pasteboard: pasteboard, poster: FakePoster(), restoreEnabled: false
        )
        _ = await injector.inject("hello.")
        await injector.settleForTesting()
        #expect(pasteboard.snapshotCount == 0)
        #expect(pasteboard.restored == nil)
    }

    @Test("Back-to-back injections: the first restore completes before the second write")
    func backToBackAwaitsPendingRestore() async {
        let pasteboard = FakePasteboard()
        let prior = plainText("original")
        pasteboard.seed(prior)
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        _ = await injector.inject("First.")
        // No settle: the second inject must itself await the pending restore.
        _ = await injector.inject("Second.")
        #expect(pasteboard.restored == prior,
                "second write defeated the first injection's restore")
    }

    @Test("Fallback triggers when the chord fails, and reports itself")
    func fallbackTrigger() async {
        let pasteboard = FakePasteboard()
        let poster = FakePoster()
        poster.chordSucceeds = false
        let injector = makeInjector(pasteboard: pasteboard, poster: poster)

        let outcome = await injector.inject("hello.")
        #expect(outcome == .injected(usedFallback: true))
        #expect(poster.fallbackCount == 1)
    }

    @Test("Both paths failing leaves our text on the pasteboard for manual paste")
    func failureKeepsTextForManualPaste() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(plainText("x"))
        let poster = FakePoster()
        poster.chordSucceeds = false
        poster.fallbackSucceeds = false
        let injector = makeInjector(pasteboard: pasteboard, poster: poster)

        let outcome = await injector.inject("hello.")
        await injector.settleForTesting()
        #expect(outcome == .failed)
        #expect(pasteboard.restored == nil, "restore would destroy the manual-paste recovery")
        #expect(pasteboard.writtenText == "hello.")
    }

    @Test("Secure input: skip and touch nothing — even for an empty commit")
    func secureInputSkips() async {
        let pasteboard = FakePasteboard()
        let poster = FakePoster()
        let secure = FakeSecureInput()
        secure.isSecureInputActive = true
        let injector = makeInjector(pasteboard: pasteboard, poster: poster, secure: secure)

        #expect(await injector.inject("p4ssw0rd oops") == .skippedSecureInput)
        // §12.1 outranks the empty check: a secure field still notifies.
        #expect(await injector.inject("") == .skippedSecureInput)
        #expect(pasteboard.writtenText == nil)
        #expect(poster.chordCount == 0)
    }

    @Test("Secure input engaging between chord failure and fallback skips the fallback")
    func secureInputRecheckBeforeFallback() async {
        let pasteboard = FakePasteboard()
        let poster = FakePoster()
        let secure = FakeSecureInput()
        poster.chordSucceeds = false
        poster.onChord = { secure.isSecureInputActive = true }
        let injector = makeInjector(pasteboard: pasteboard, poster: poster, secure: secure)

        let outcome = await injector.inject("hello.")
        #expect(outcome == .skippedSecureInput)
        #expect(poster.fallbackCount == 0, "fallback pasted into a secure field")
    }

    @Test("Empty commit is a no-op")
    func emptySkips() async {
        let pasteboard = FakePasteboard()
        let poster = FakePoster()
        let injector = makeInjector(pasteboard: pasteboard, poster: poster)
        let outcome = await injector.inject("")
        #expect(outcome == .skippedEmpty)
        #expect(pasteboard.writtenText == nil)
        #expect(poster.chordCount == 0)
    }

    @Test("Consecutive segments join with a space; reset drops the memory")
    func interSegmentSpacing() async {
        let pasteboard = FakePasteboard()
        let injector = makeInjector(pasteboard: pasteboard, poster: FakePoster())

        _ = await injector.inject("First segment.")
        _ = await injector.inject("Second segment.")
        #expect(pasteboard.writtenText == " Second segment.")

        injector.resetSpacing()
        _ = await injector.inject("Third segment.")
        #expect(pasteboard.writtenText == "Third segment.",
                "resetSpacing did not drop the joiner memory")
    }

    @Test("No joiner after a failed injection (nothing was pasted)")
    func noJoinerAfterFailure() async {
        let pasteboard = FakePasteboard()
        let poster = FakePoster()
        poster.chordSucceeds = false
        poster.fallbackSucceeds = false
        let injector = makeInjector(pasteboard: pasteboard, poster: poster)

        _ = await injector.inject("First.")
        poster.chordSucceeds = true
        _ = await injector.inject("Second.")
        #expect(pasteboard.writtenText == "Second.",
                "failed paste must not seed spacing memory")
    }
}

@Suite("InterSegmentSpacer")
struct InterSegmentSpacerTests {
    private let spacer = InterSegmentSpacer()
    private let base = Date(timeIntervalSince1970: 1_000)

    @Test("Space between word-tail and word-start")
    func joins() {
        #expect(spacer.joiner(previousTail: ".", previousAt: base, next: "Next", now: base) == " ")
    }

    @Test("No joiner on first segment")
    func firstSegment() {
        #expect(spacer.joiner(previousTail: nil, previousAt: nil, next: "Hi", now: base).isEmpty)
    }

    @Test("No joiner when the previous tail is whitespace or newline")
    func tailWhitespace() {
        #expect(spacer.joiner(previousTail: " ", previousAt: base, next: "Hi", now: base).isEmpty)
        #expect(spacer.joiner(previousTail: "\n", previousAt: base, next: "Hi", now: base).isEmpty)
    }

    @Test("No joiner before binding punctuation or a combining mark")
    func bindingLeaders() {
        for leader in [".", ",", "!", "?", ")", "\u{2019}s", "\u{301}x"] {
            #expect(spacer.joiner(previousTail: "d", previousAt: base, next: leader, now: base).isEmpty,
                    "joined before \(leader.debugDescription)")
        }
    }

    @Test("The join window expires")
    func windowExpires() {
        let later = base.addingTimeInterval(91)
        #expect(spacer.joiner(previousTail: "d", previousAt: base, next: "Hi", now: later).isEmpty)
        let within = base.addingTimeInterval(89)
        #expect(spacer.joiner(previousTail: "d", previousAt: base, next: "Hi", now: within) == " ")
    }
}
