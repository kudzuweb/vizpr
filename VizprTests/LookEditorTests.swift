import Foundation
import Testing
@testable import Vizpr

@MainActor
@Suite("Look editor")
struct LookEditorTests {
    private let styleRanges: [(WritableKeyPath<LookStyle, Double>, ClosedRange<Double>)] = [
        (\.fill.frost, LookRanges.unit),
        (\.backdrop.strength, LookRanges.backdropStrength),
        (\.backdrop.feather, LookRanges.backdropFeather),
        (\.light.edgeLight, LookRanges.unit),
        (\.light.bevel, LookRanges.unit),
        (\.light.gloss, LookRanges.unit),
        (\.light.sheen, LookRanges.unit),
        (\.light.sheenSweepSeconds, LookRanges.sheenSweepSeconds),
        (\.light.grain, LookRanges.grain),
        (\.border.width, LookRanges.borderWidth),
        (\.border.opacity, LookRanges.unit),
        (\.outerGlow.radius, LookRanges.glowRadius),
        (\.outerGlow.strength, LookRanges.unit),
        (\.dropShadow.radius, LookRanges.shadowRadius),
        (\.dropShadow.x, LookRanges.shadowOffset),
        (\.dropShadow.y, LookRanges.shadowOffset),
        (\.dropShadow.opacity, LookRanges.unit),
        (\.pane.width, LookRanges.paneWidth),
        (\.pane.paddingHorizontal, LookRanges.panePadding),
        (\.pane.paddingVertical, LookRanges.panePadding),
        (\.text.lineSpacing, LookRanges.lineSpacing),
        (\.text.glowRadius, LookRanges.textGlowRadius),
        (\.dot.size, LookRanges.dotSize)
    ]

    /// A slider longer than its field's clamp stops moving the look partway
    /// along its travel, with nothing crashing to say so.
    @Test("Every slider range matches the bounds its field is clamped to")
    func sliderRangesMatchClamping() {
        for (keyPath, range) in styleRanges {
            for edge in [range.lowerBound, range.upperBound] {
                var style = LookStyle.neutral
                style[keyPath: keyPath] = edge
                #expect(style.clamped()[keyPath: keyPath] == edge, "\(keyPath) at \(edge)")
            }
            var below = LookStyle.neutral
            below[keyPath: keyPath] = range.lowerBound - 1
            var above = LookStyle.neutral
            above[keyPath: keyPath] = range.upperBound + 1
            #expect(below.clamped()[keyPath: keyPath] == range.lowerBound, "\(keyPath) below")
            #expect(above.clamped()[keyPath: keyPath] == range.upperBound, "\(keyPath) above")
        }
    }

    @Test("The slab sliders match the slab's clamping")
    func slabRangesMatchClamping() {
        var low = SlabStyle.default
        low.meshDrift = LookRanges.meshDrift.lowerBound
        low.meshLoopSeconds = LookRanges.meshLoopSeconds.lowerBound
        var high = SlabStyle.default
        high.meshDrift = LookRanges.meshDrift.upperBound
        high.meshLoopSeconds = LookRanges.meshLoopSeconds.upperBound
        #expect(low.clamped().meshDrift == low.meshDrift)
        #expect(low.clamped().meshLoopSeconds == low.meshLoopSeconds)
        #expect(high.clamped().meshDrift == high.meshDrift)
        #expect(high.clamped().meshLoopSeconds == high.meshLoopSeconds)
    }

    @Test("The preview types the sample out, settling the first two sentences, and a settled prefix never changes")
    func transcriptBuildsUp() {
        var previousSettled = ""
        var previousDisplayed = ""
        for count in 1...PreviewTranscript.wordCount {
            let snapshot = PreviewTranscript.snapshot(wordCount: count)
            #expect(snapshot.displayed.hasPrefix(snapshot.settled))
            #expect(snapshot.settled.hasPrefix(previousSettled))
            #expect(snapshot.displayed.hasPrefix(previousDisplayed))
            #expect(snapshot.displayed.split(separator: " ").count == count)
            previousSettled = snapshot.settled
            previousDisplayed = snapshot.displayed
        }
        let done = PreviewTranscript.snapshot(wordCount: PreviewTranscript.wordCount)
        #expect(done.settled == PreviewTranscript.sentences.prefix(PreviewTranscript.settledSentenceCount)
            .joined(separator: " "))
        #expect(done.mutableSuffix.hasSuffix(PreviewTranscript.sentences.last!))
        #expect(PreviewTranscript.snapshot(wordCount: 1).settled.isEmpty)
    }

    @Test("The preview loop restarts from empty after the full text")
    func transcriptRestarts() async {
        let transcript = PreviewTranscript(wordInterval: .milliseconds(1), holdInterval: .milliseconds(1))
        let full = PreviewTranscript.snapshot(wordCount: PreviewTranscript.wordCount)
        let task = Task { await transcript.run() }
        var sawFull = false
        var sawRestart = false
        for _ in 0..<2_000 where !sawRestart {
            try? await Task.sleep(for: .milliseconds(2))
            if transcript.snapshot == full { sawFull = true }
            if sawFull, transcript.snapshot != full, transcript.snapshot.displayed.count < full.displayed.count {
                sawRestart = true
            }
        }
        task.cancel()
        #expect(sawFull && sawRestart)
    }
}
