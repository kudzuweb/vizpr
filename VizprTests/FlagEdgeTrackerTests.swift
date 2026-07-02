import CoreGraphics
import Testing
@testable import Vizpr

/// Tests for the edge-derivation logic the tap shell relies on. These cover the
/// two shell bugs the PR 2 review surfaced — a packet toggling both Fn and the
/// secondary combo, and stale edge state after a missed up-event — which the
/// pure-machine property tests cannot reach.
@Suite("FlagEdgeTracker")
struct FlagEdgeTrackerTests {

    private func tracker() -> FlagEdgeTracker {
        FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate])
    }

    @Test("Fn down then up yields one edge each")
    func fnDownUp() {
        var tracker = tracker()
        #expect(tracker.edges(for: [.maskSecondaryFn]) == [.fnDown])
        #expect(tracker.edges(for: []) == [.fnUp])
    }

    @Test("Repeated identical snapshots yield no edges")
    func noSpuriousEdges() {
        var tracker = tracker()
        #expect(tracker.edges(for: [.maskSecondaryFn]) == [.fnDown])
        #expect(tracker.edges(for: [.maskSecondaryFn]).isEmpty)   // unchanged
        #expect(tracker.edges(for: [.maskSecondaryFn]).isEmpty)
    }

    @Test("Secondary combo requires all mask bits")
    func secondaryComboNeedsAllBits() {
        var tracker = tracker()
        #expect(tracker.edges(for: [.maskControl]).isEmpty)        // partial — no edge
        #expect(tracker.edges(for: [.maskControl, .maskAlternate]) == [.secondaryDown])
        #expect(tracker.edges(for: [.maskControl]) == [.secondaryUp])   // dropped a bit
    }

    @Test("One packet toggling both Fn and secondary yields both edges, Fn first")
    func bothEdgesInOnePacket() {
        var tracker = tracker()
        // The bug this guards: the old shell early-returned after Fn and dropped
        // the secondary edge, desyncing the secondary source.
        let edges = tracker.edges(for: [.maskSecondaryFn, .maskControl, .maskAlternate])
        #expect(edges == [.fnDown, .secondaryDown])
    }

    @Test("First snapshot after reset seeds the baseline silently")
    func resetSeedsSilently() {
        var tracker = tracker()
        _ = tracker.edges(for: [.maskSecondaryFn])     // Fn down
        #expect(tracker.fnDown)
        // Tap re-enabled after a blind window; whatever the first snapshot says
        // is adopted as the baseline without emitting edges.
        tracker.reset()
        #expect(tracker.edges(for: [.maskSecondaryFn]).isEmpty)   // still held → no edge
        #expect(tracker.fnDown)                                    // baseline adopted
        // The real release, observed live, now produces a correct up edge...
        #expect(tracker.edges(for: []) == [.fnUp])
        // ...and the next press a correct down edge.
        #expect(tracker.edges(for: [.maskSecondaryFn]) == [.fnDown])
    }

    @Test("Ambiguous post-reset packet cannot start a spurious session")
    func postResetPacketWithOtherModifierEmitsNothing() {
        var tracker = tracker()
        _ = tracker.edges(for: [.maskSecondaryFn])     // dictating, Fn held
        tracker.reset()                                 // secure input killed the tap
        // User, still holding Fn, presses Shift to type a password character. The
        // packet {Fn, Shift} must NOT read as an Fn-down edge — the old behavior
        // started a dictation session here and deleted Shift's transition packet.
        #expect(tracker.edges(for: [.maskSecondaryFn, .maskShift]).isEmpty)
        // Follow-up changes are tracked normally from the adopted baseline.
        #expect(tracker.edges(for: [.maskShift]) == [.fnUp])
    }

    @Test("A missed trigger is the accepted cost of an ambiguous resync")
    func freshPressAfterResetIsMissedOnce() {
        var tracker = tracker()
        tracker.reset()
        // If the very first packet after re-enable IS a fresh Fn press, it seeds
        // silently — the plan prefers a missed trigger over an ambiguous consume.
        #expect(tracker.edges(for: [.maskSecondaryFn]).isEmpty)
        // Releasing and pressing again works normally.
        #expect(tracker.edges(for: []) == [.fnUp])
        #expect(tracker.edges(for: [.maskSecondaryFn]) == [.fnDown])
    }

    @Test("Without reset, a missed up-event would swallow the next down edge")
    func staleStateSwallowsNextDownWithoutReset() {
        var tracker = tracker()
        _ = tracker.edges(for: [.maskSecondaryFn])     // Fn down, fnDown == true
        // No up edge delivered (tap was disabled). A later Fn-down snapshot looks
        // identical to the stranded state, so no edge is produced — which is
        // exactly why the shell must call reset() on every re-enable.
        #expect(tracker.edges(for: [.maskSecondaryFn]).isEmpty)
    }

    @Test("Init is seeded: the first-ever Fn press emits immediately")
    func initIsSeeded() {
        var tracker = tracker()
        // No silent-seed penalty on a fresh launch — dictation works on the very
        // first press after the tap installs.
        #expect(tracker.edges(for: [.maskSecondaryFn]) == [.fnDown])
    }
}
