import CoreGraphics

/// Derives discrete key edges from the modifier-flag snapshots that
/// `flagsChanged` delivers (PLAN.md §6 + §8).
///
/// `flagsChanged` reports the *entire* modifier set on every change, so detecting
/// "Fn went down" or "the secondary combo was released" means comparing against
/// the previous snapshot. That comparison is real logic with real failure modes
/// (stale state after a missed event; two modifiers changing in one packet), so
/// it lives here as a pure value type rather than buried in the tap shell — fully
/// testable with synthetic flag sequences, no CGEventTap required.
///
/// Pulling it out fixes two shell bugs by construction: a single packet that
/// toggles both Fn and the secondary combo now yields *both* edges (the shell no
/// longer early-returns after Fn), and `reset()` gives the shell one call to
/// clear edge state on every tap re-enable so a missed up-edge can't strand
/// `fnDown` true.
struct FlagEdgeTracker {
    /// A single key transition derived from a flag change.
    enum Edge: Equatable, Sendable {
        case fnDown, fnUp
        case secondaryDown, secondaryUp
    }

    /// The modifiers that together form the secondary activation combo.
    let secondaryMask: CGEventFlags

    private(set) var fnDown = false
    private(set) var secondaryActive = false

    /// Whether the current `fnDown`/`secondaryActive` baselines are trustworthy.
    /// True from init (a fresh launch starts from "nothing held", so the first
    /// Fn press must emit immediately); false after `reset()`, because a reset
    /// follows a blind window in which any number of events were missed.
    private var seeded = true

    init(secondaryMask: CGEventFlags) {
        // The secondary combo must not include Fn, or one physical key would be
        // both suppressed (as Fn) and tracked as a benign modifier.
        precondition(!secondaryMask.contains(.maskSecondaryFn),
                     "secondaryMask must not include the Fn flag")
        self.secondaryMask = secondaryMask
    }

    /// Fold a new flag snapshot in and return the edges it produced, in a stable
    /// order (Fn first). Updates internal state. Returns an empty array when no
    /// tracked modifier crossed a boundary.
    ///
    /// The first snapshot after `reset()` is adopted as the new baseline and
    /// emits **no** edges: after a blind window we cannot tell "Fn is newly down"
    /// from "Fn was held the whole time", and emitting a down-edge on that guess
    /// would start a spurious dictation session and delete a flag packet that may
    /// carry another modifier's real transition (e.g. Shift while typing a
    /// password — the very situation that disables the tap). Fail-open per the
    /// plan: a missed trigger is annoying; an ambiguous consume is unacceptable.
    mutating func edges(for flags: CGEventFlags) -> [Edge] {
        guard seeded else {
            fnDown = flags.contains(.maskSecondaryFn)
            secondaryActive = flags.contains(secondaryMask)
            seeded = true
            return []
        }

        var result: [Edge] = []

        let fn = flags.contains(.maskSecondaryFn)
        if fn != fnDown {
            result.append(fn ? .fnDown : .fnUp)
            fnDown = fn
        }

        let combo = flags.contains(secondaryMask)
        if combo != secondaryActive {
            result.append(combo ? .secondaryDown : .secondaryUp)
            secondaryActive = combo
        }

        return result
    }

    /// Clear edge state after a blind window (tap disable/re-enable, stop). The
    /// next snapshot re-seeds the baseline silently — see `edges(for:)`.
    mutating func reset() {
        fnDown = false
        secondaryActive = false
        seeded = false
    }
}
