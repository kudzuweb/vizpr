import Foundation

/// Inter-segment spacing (PLAN.md §12): the injector owns the joiner BETWEEN
/// consecutive dictation segments; the committed snapshot itself is never
/// touched (WYSIWYG — the injected string is joiner + snapshot, snapshot
/// byte-intact).
///
/// Pure value logic: the injector feeds it the previous injection's tail and
/// asks for the joiner for the next segment.
struct InterSegmentSpacer: Sendable {
    /// A segment older than this no longer joins — the user has almost
    /// certainly moved fields or contexts. Tunable in PR 11.
    var joinWindow: TimeInterval = 90

    /// Punctuation that binds to the preceding text: a segment starting with
    /// one of these never gets a leading joiner.
    private static let bindingLeaders = Set(".,!?;:)]}\u{2019}\u{201D}'\"…")

    /// The joiner to place before `next`, given the previous segment ended
    /// with `previousTail` at `previousAt` and the next injection happens at
    /// `now`. Empty when no join applies.
    func joiner(
        previousTail: Character?,
        previousAt: Date?,
        next: String,
        now: Date
    ) -> String {
        guard let previousTail, let previousAt else { return "" }
        guard now.timeIntervalSince(previousAt) <= joinWindow else { return "" }
        guard let first = next.first else { return "" }
        if previousTail.isWhitespace || previousTail.isNewline { return "" }
        if first.isWhitespace { return "" }
        if Self.bindingLeaders.contains(first) { return "" }
        // A leading combining mark would attach to the joiner space itself,
        // rendering as an accented space — never join in front of one.
        if let scalar = next.unicodeScalars.first,
           [.nonspacingMark, .spacingMark, .enclosingMark]
               .contains(scalar.properties.generalCategory) {
            return ""
        }
        return " "
    }
}
