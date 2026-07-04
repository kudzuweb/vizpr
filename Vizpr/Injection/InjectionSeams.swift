import Foundation

/// Injection IO seams (PLAN.md §12 + PR 8): the orchestration core in
/// `TextInjector` is pure logic against these; the real NSPasteboard/CGEvent
/// shells conform in SystemInjectionIO.swift and stay thin.

/// One pasteboard representation: UTI → data, in fidelity order.
struct PasteboardEntry: Sendable, Equatable {
    let type: String
    let data: Data
}

/// A pasteboard snapshot for the restore path. Entry order per item preserves
/// `NSPasteboardItem.types` fidelity order — consumers use the first/richest
/// type, so a dictionary would scramble what apps see after restore.
struct PasteboardContents: Sendable, Equatable {
    var items: [[PasteboardEntry]]
}

@MainActor
protocol PasteboardWriting {
    /// NSPasteboard.changeCount semantics: increments on every ownership
    /// change, including writes by other apps. The ownership guard's clock.
    var changeCount: Int { get }

    /// Whether the current content is marked `org.nspasteboard.ConcealedType`
    /// (password managers). Concealed content must never be snapshotted —
    /// capturing it copies a secret into our memory, and restoring it re-arms
    /// it under a change count the owning manager's auto-clear no longer
    /// tracks.
    var containsConcealedContent: Bool { get }

    func snapshot() -> PasteboardContents

    /// Clear, write `text` plus a private tag type carrying `tag`, and return
    /// the change count AFTER the write.
    func write(_ text: String, tag: String) -> Int

    /// Whether the pasteboard still carries our private tag with this value.
    func hasTag(_ tag: String) -> Bool

    /// Atomically re-claim the pasteboard and restore `contents` — but only
    /// if claiming proves no other writer raced in: the claim must observe
    /// exactly `expectedChangeCount` as the pre-claim count. Returns whether
    /// the restore was performed.
    func restore(_ contents: PasteboardContents, expectedChangeCount: Int) -> Bool
}

@MainActor
protocol EventPosting {
    /// Post the paste chord (Cmd+V) with the keycode resolved for the ACTIVE
    /// keyboard layout (§12.4 — Dvorak/AZERTY). Returns false if the process
    /// lacks the trust to post (CGEvent.post silently no-ops without
    /// Accessibility) or the event could not be created.
    func postPasteChord() -> Bool

    /// AppleScript fallback (§12.6) for apps where the CGEvent paste doesn't
    /// land. Returns false if the script errored.
    func fallbackPaste() -> Bool
}

@MainActor
protocol SecureInputProbing {
    /// `IsSecureEventInputEnabled()`: true while a secure field (password
    /// input) holds the keyboard. Injection must skip and notify (§12.1).
    var isSecureInputActive: Bool { get }
}
