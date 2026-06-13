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

    @Test("reset clears state so a missed up-event cannot strand fnDown")
    func resetClearsStaleState() {
        var tracker = tracker()
        _ = tracker.edges(for: [.maskSecondaryFn])     // Fn down
        #expect(tracker.fnDown)
        // Simulate a tap re-enable after the Fn release was missed while disabled.
        tracker.reset()
        #expect(!tracker.fnDown)
        // The next real Fn-down is now correctly seen as a fresh down edge.
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
}
