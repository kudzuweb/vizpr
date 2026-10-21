import Foundation

/// The injection orchestrator (PLAN.md §12, locked sequence). Receives EXACTLY
/// the `commit()` snapshot and transforms nothing — the pasted string is
/// joiner + snapshot with the snapshot byte-intact (WYSIWYG; asserted in
/// tests). Accessibility is never used for writes.
///
/// v2 seam (reserved, do not implement): inject(_:) takes only a text
/// payload today; a future CommandParser adds an optional action list
/// parameter here rather than a new pipeline stage.
@MainActor
final class TextInjector {

    /// What happens to the user's previous clipboard after a paste.
    enum ClipboardOutcome: Equatable {
        /// The previous clipboard was captured and its ownership-guarded
        /// restore is scheduled.
        case restoreScheduled
        /// Nothing was captured (restore setting off, or concealed content),
        /// so the transcript stays on the clipboard by design.
        case notCaptured
        /// The focused element did not plausibly accept the paste, so the
        /// transcript stays on the clipboard as the user's only other copy.
        /// The caller MUST tell the user (beep).
        case keptNoTextField
    }

    enum Outcome: Equatable {
        /// Pasted via the CGEvent chord or the AppleScript fallback.
        case injected(usedFallback: Bool, clipboard: ClipboardOutcome)
        /// Secure field focused — skipped; the caller MUST surface a quiet
        /// notice (§12.1: never fail silently).
        case skippedSecureInput
        /// Empty commit — nothing to do.
        case skippedEmpty
        /// Both paste paths failed; the text remains on the pasteboard so the
        /// user can paste manually (and restore is skipped for the same
        /// reason). Callers surface this too — total failure is no quieter
        /// than a secure-input skip.
        case failed
    }

    private let pasteboard: any PasteboardWriting
    private let poster: any EventPosting
    private let secureInput: any SecureInputProbing
    private let focusProbe: any FocusedFieldProbing
    private let spacer: InterSegmentSpacer
    /// Time to let the target app service the paste before the ownership-
    /// guarded restore (§12.5). Zero in tests.
    private let restoreDelay: Duration
    private var restoreEnabled: Bool

    /// Live setting (PR 11): ON restores the prior clipboard after paste;
    /// OFF leaves the transcript on it (Mauria's clipboard-keep request).
    func setRestoreEnabled(_ enabled: Bool) {
        restoreEnabled = enabled
    }
    private let now: @Sendable () -> Date

    /// Tail of the last successfully pasted string, for inter-segment spacing.
    private var previousTail: Character?
    private var previousInjectionAt: Date?

    /// The deferred ownership-guarded restore of the LAST injection. Runs as
    /// a child task so inject() returns as soon as the paste is posted — an
    /// inline 300 ms sleep would stall the caller's action loop and cost the
    /// first 300 ms of a rapid re-dictation (review finding, PR 8).
    private var pendingRestore: Task<Void, Never>?

    init(
        pasteboard: any PasteboardWriting,
        poster: any EventPosting,
        secureInput: any SecureInputProbing,
        focusProbe: any FocusedFieldProbing,
        spacer: InterSegmentSpacer = InterSegmentSpacer(),
        restoreDelay: Duration = .milliseconds(300),
        restoreEnabled: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.secureInput = secureInput
        self.focusProbe = focusProbe
        self.spacer = spacer
        self.restoreDelay = restoreDelay
        self.restoreEnabled = restoreEnabled
        self.now = now
    }

    /// The locked §12 sequence: secure-input guard → clipboard snapshot →
    /// tagged write → layout-aware Cmd+V (AppleScript fallback) → ownership-
    /// guarded restore (deferred; see `pendingRestore`), skipped when the
    /// focused element does not accept text.
    func inject(_ snapshot: String) async -> Outcome {
        // §12.1 comes FIRST — even an empty commit in a secure field is a
        // secure-input skip, not a silent no-op.
        guard !secureInput.isSecureInputActive else { return .skippedSecureInput }
        guard !snapshot.isEmpty else { return .skippedEmpty }

        // Let the previous injection's deferred restore finish before we
        // touch the pasteboard, or our write would defeat its ownership guard
        // and the user's original clipboard would be lost on back-to-back
        // dictations. Bounded by restoreDelay.
        if let pendingRestore {
            await pendingRestore.value
            self.pendingRestore = nil
        }

        let injectionTime = now()
        let joiner = spacer.joiner(
            previousTail: previousTail,
            previousAt: previousInjectionAt,
            next: snapshot,
            now: injectionTime
        )
        // WYSIWYG: the snapshot is a byte-intact suffix of the pasted string.
        let pasted = joiner + snapshot

        // Never snapshot concealed content (password managers): capturing it
        // copies a secret into our memory and restoring it re-arms it outside
        // the manager's auto-clear. The paste still proceeds; only restore is
        // sacrificed.
        let saved: PasteboardContents? =
            (restoreEnabled && !pasteboard.containsConcealedContent)
                ? pasteboard.snapshot() : nil
        // Started before the paste so the AX read overlaps it instead of
        // extending the commit-to-inject path.
        let focusCheck = saved == nil ? nil : focusProbe.beginAcceptsTextCheck()
        let tag = UUID().uuidString
        let countAfterWrite = pasteboard.write(pasted, tag: tag)

        var usedFallback = false
        if !poster.postPasteChord() {
            usedFallback = true
            // The chord path may have taken real time; re-check §12.1 before
            // the slower fallback rather than pasting into a field the user
            // just focused.
            guard !secureInput.isSecureInputActive else { return .skippedSecureInput }
            guard poster.fallbackPaste() else {
                // Leave our text on the pasteboard: manual Cmd+V is the
                // user's recovery path, so restoring would destroy it.
                return .failed
            }
        }

        previousTail = pasted.last
        previousInjectionAt = injectionTime

        // The paste is attempted either way (terminals and Electron apps
        // accept pastes while exposing poor AX trees); only the restore
        // depends on the probe. If the paste landed nowhere, the restore
        // would delete the only other copy of the text.
        guard let saved, let focusCheck else {
            return .injected(usedFallback: usedFallback, clipboard: .notCaptured)
        }
        guard await focusCheck.value else {
            return .injected(usedFallback: usedFallback, clipboard: .keptNoTextField)
        }
        scheduleRestore(saved, expectedChangeCount: countAfterWrite, tag: tag)
        return .injected(usedFallback: usedFallback, clipboard: .restoreScheduled)
    }

    private func scheduleRestore(
        _ saved: PasteboardContents, expectedChangeCount: Int, tag: String
    ) {
        pendingRestore = Task { @MainActor [pasteboard, restoreDelay] in
            do {
                try await Task.sleep(for: restoreDelay)
            } catch {
                // Cancelled (app terminating): leaving the pasteboard
                // unrestored is acceptable; restoring EARLY would race the
                // target app still servicing the paste and make it paste the
                // old clipboard instead of the dictation.
                return
            }
            // Ownership guard (§12.5): restore only if the pasteboard still
            // holds exactly our tagged write — change count unmoved AND the
            // tag intact — and the shell re-verifies atomically at claim
            // time. Anything else means the user (or another app) owns the
            // pasteboard now; never clobber it.
            if pasteboard.changeCount == expectedChangeCount, pasteboard.hasTag(tag) {
                _ = pasteboard.restore(saved, expectedChangeCount: expectedChangeCount)
            }
        }
    }

    /// Await the deferred restore of the last injection — tests use this to
    /// make the restore observable; production callers never need it.
    func settleForTesting() async {
        await pendingRestore?.value
        pendingRestore = nil
    }

    /// Forget the previous segment's tail so the next injection starts
    /// unjoined. Call when continuity with the last injection is broken —
    /// session cancel, a secure-input skip (the user has moved fields), or
    /// any future focus-change signal (PR 10).
    func resetSpacing() {
        previousTail = nil
        previousInjectionAt = nil
    }
}
