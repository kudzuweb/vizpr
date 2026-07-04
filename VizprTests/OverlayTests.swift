import AppKit
import Testing
@testable import Vizpr

@Suite("OverlayLayout")
struct OverlayLayoutTests {
    // A 1000-pt-tall screen: bottom edge at 250, max height 500, cap at 750.
    private let layout = OverlayLayout(screen: CGRect(x: 0, y: 0, width: 1600, height: 1000))

    @Test("Growth → cap → tail-scroll against a scripted sequence")
    func growthSequence() {
        var lastHeight: CGFloat = 0
        for content in stride(from: CGFloat(0), through: 900, by: 60) {
            let frame = layout.frame(contentHeight: content)
            // The bottom edge NEVER moves (§13: grows upward).
            #expect(frame.minY == 250)
            // Height is monotonic non-decreasing and capped at 500.
            #expect(frame.height >= lastHeight)
            #expect(frame.height <= 500)
            lastHeight = frame.height
            // Tail-scroll exactly when content exceeds the cap.
            #expect(layout.scrollsTail(contentHeight: content) == (content > 500))
        }
        #expect(layout.frame(contentHeight: 900).height == 500, "cap not reached")
    }

    @Test("Resting capsule floors the height and centers horizontally")
    func resting() {
        let frame = layout.restingFrame
        #expect(frame.height == OverlayLayout.restingSize.height)
        #expect(frame.midX == 800)
        #expect(frame.minY == 250)
    }

    @Test("Growth is height-only at the fixed reading width")
    func fixedWidth() {
        let small = layout.frame(contentHeight: 100)
        let large = layout.frame(contentHeight: 400)
        #expect(small.width == OverlayLayout.readingWidth)
        #expect(large.width == OverlayLayout.readingWidth)
        #expect(small.midX == large.midX)
    }
}

@MainActor
@Suite("SettleGate")
struct SettleGateTests {
    @Test("Drain before the wait returns immediately")
    func drainFirst() async {
        let gate = SettleGate()
        gate.beginSession()
        gate.noteDrained()
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .seconds(5))
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }

    @Test("A waiter is released the moment the drain lands")
    func drainReleasesWaiter() async {
        let gate = SettleGate()
        gate.beginSession()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            gate.noteDrained()
        }
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .seconds(5))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "waiter held past the drain: \(elapsed)")
    }

    @Test("The cap bounds a session that never drains")
    func capBounds() async {
        let gate = SettleGate()
        gate.beginSession()
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .milliseconds(80))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(80))
        #expect(elapsed < .seconds(2), "cap did not bound the wait: \(elapsed)")
    }

    @Test("Drain state is per-session")
    func perSession() async {
        let gate = SettleGate()
        gate.beginSession()
        gate.noteDrained()
        gate.beginSession()   // new session: previous drain must not leak
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .milliseconds(60))
        #expect(ContinuousClock.now - start >= .milliseconds(60),
                "stale drain satisfied a new session's settle")
    }
}

@MainActor
@Suite("PreviewPanel")
struct PreviewPanelTests {
    @Test("The focus invariant: the panel can never take key or main")
    func focusInvariant() {
        let panel = PreviewPanel()
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.level == .floating)
    }
}
