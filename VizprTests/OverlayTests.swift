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

@Suite("OverlayLayout anchor")
struct OverlayAnchorLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test("A nil anchor gives exactly the lower-center frame")
    func nilAnchorIsDefault() {
        let layout = OverlayLayout(screen: screen)
        for content in [CGFloat(0), 100, 400, 900] {
            let frame = layout.frame(contentHeight: content, paneWidth: 560, margin: 20)
            let width = content <= 44 ? OverlayLayout.restingSize.width : 560
            #expect(frame == CGRect(
                x: 800 - width / 2 - 20, y: 250 - 20,
                width: width + 40, height: min(max(content, 44), 500) + 40
            ))
        }
        #expect(layout.maxHeight == 500)
    }

    @Test("An anchor puts the pane's bottom-center there, and the margin wraps it")
    func anchorPlacesPane() {
        let layout = OverlayLayout(screen: screen, anchor: OverlayAnchor(x: 0.25, y: 0.1))
        let frame = layout.frame(contentHeight: 200, paneWidth: 560, margin: 30)
        #expect(frame.midX == 400)
        #expect(frame.minY + 30 == 100)
        #expect(frame.insetBy(dx: 30, dy: 30).height == 200)
    }

    @Test("A high anchor caps the height so the pane stays on screen")
    func highAnchorCapsHeight() {
        let layout = OverlayLayout(screen: screen, anchor: OverlayAnchor(x: 0.5, y: 0.8))
        #expect(layout.maxHeight == 1000 - 800 - OverlayLayout.topInset)
        let frame = layout.frame(contentHeight: 900)
        #expect(frame.maxY <= screen.maxY - OverlayLayout.topInset)
        #expect(layout.scrollsTail(contentHeight: 300))
    }

    @Test("A pane anchored at the right edge is held fully on screen")
    func edgeAnchorStaysOnScreen() {
        let layout = OverlayLayout(screen: screen, anchor: OverlayAnchor(x: 1, y: 0))
        let frame = layout.frame(contentHeight: 100, paneWidth: 560)
        #expect(frame.maxX == screen.maxX)
        #expect(frame.minY == screen.minY)
    }

    @Test("anchor(forPaneFrame:) inverts frame()")
    func roundTrip() {
        let original = OverlayAnchor(x: 0.3, y: 0.4)
        let pane = OverlayLayout(screen: screen, anchor: original).frame(contentHeight: 120, paneWidth: 560)
        let recovered = OverlayLayout(screen: screen).anchor(forPaneFrame: pane)
        #expect(abs(recovered.x - original.x) < 1e-9)
        #expect(abs(recovered.y - original.y) < 1e-9)
    }

    @Test("A pane dragged partly off screen is pulled back on")
    func dragPastEdgeClamps() {
        let layout = OverlayLayout(screen: screen)
        let offRight = layout.anchor(forPaneFrame: CGRect(x: 1500, y: 300, width: 560, height: 44))
        #expect(offRight.x == 1320.0 / 1600)
        let offBottomLeft = layout.anchor(forPaneFrame: CGRect(x: -200, y: -50, width: 560, height: 44))
        #expect(offBottomLeft == OverlayAnchor(x: 280.0 / 1600, y: 0))
        let offTop = layout.anchor(forPaneFrame: CGRect(x: 500, y: 990, width: 560, height: 44))
        #expect(offTop.y == 956.0 / 1000)
    }

    @Test("The same fractions place the pane proportionally on a different screen")
    func fractionsSurviveResize() {
        let anchor = OverlayAnchor(x: 0.4, y: 0.6)
        let small = OverlayLayout(screen: CGRect(x: 0, y: 0, width: 1280, height: 800), anchor: anchor)
        let large = OverlayLayout(screen: CGRect(x: 1920, y: 100, width: 2560, height: 1440), anchor: anchor)
        #expect(abs(small.frame(contentHeight: 100).midX - 512) < 1e-6)
        #expect(abs(small.bottomEdgeY - 480) < 1e-6)
        #expect(abs(large.frame(contentHeight: 100).midX - 2944) < 1e-6)
        #expect(abs(large.bottomEdgeY - 964) < 1e-6)
    }
}

@MainActor
@Suite("SettleGate")
struct SettleGateTests {
    @Test("Drain before the wait returns immediately")
    func drainFirst() async {
        let gate = SettleGate()
        let epoch = gate.beginSession()
        gate.noteDrained(epoch: epoch)
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .seconds(5))
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }

    @Test("A waiter is released the moment the drain lands")
    func drainReleasesWaiter() async {
        let gate = SettleGate()
        let epoch = gate.beginSession()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            gate.noteDrained(epoch: epoch)
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

    @Test("A stale epoch's drain never satisfies the current session")
    func staleEpochIgnored() async {
        let gate = SettleGate()
        let old = gate.beginSession()
        gate.beginSession()   // supersedes `old`
        gate.noteDrained(epoch: old)   // late drain from the dead session
        let start = ContinuousClock.now
        await gate.awaitDrain(cap: .milliseconds(60))
        #expect(ContinuousClock.now - start >= .milliseconds(60),
                "a stale drain collapsed the current settle window")
    }

    @Test("Drain state is per-session")
    func perSession() async {
        let gate = SettleGate()
        let stale = gate.beginSession()
        gate.noteDrained(epoch: stale)
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
        // Click-through was dropped on purpose (2026-10-21) so the pane can be dragged.
        #expect(panel.ignoresMouseEvents == false)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.level == .floating)
    }
}
