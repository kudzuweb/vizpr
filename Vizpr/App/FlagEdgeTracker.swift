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
    mutating func edges(for flags: CGEventFlags) -> [Edge] {
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

    /// Clear edge state. Called on every tap re-enable so a press whose release
    /// was missed while the tap was disabled cannot strand `fnDown` true and
    /// swallow the next press's edge (fail-open: assume nothing is held).
    mutating func reset() {
        fnDown = false
        secondaryActive = false
    }
}
