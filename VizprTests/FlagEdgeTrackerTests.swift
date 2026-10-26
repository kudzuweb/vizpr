import CoreGraphics
import Testing
@testable import Vizpr

/// Tests for the edge-derivation logic the tap shell relies on: the two shell
/// bugs the PR 2 review surfaced (a packet toggling both the trigger and the
/// secondary combo, and stale edge state after a missed up-event), and the
/// event sequences the trigger-plan review found that break fail-open when
/// each half is right alone.
@Suite("FlagEdgeTracker")
struct FlagEdgeTrackerTests {

    // MARK: Fixtures

    private let leftOption: UInt16 = 58
    private let rightOption: UInt16 = 61
    private let leftCommand: UInt16 = 55
    private let keyD: UInt16 = 2
    private let keyF13: UInt16 = 105

    private func tracker(_ trigger: HotkeyTrigger = .fn) -> FlagEdgeTracker {
        FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate], trigger: trigger)
    }

    /// A flags snapshot for the Fn trigger: Fn detection ignores the keycode.
    private func flags(_ flags: CGEventFlags) -> HotkeyKeyEvent {
        HotkeyKeyEvent(kind: .flagsChanged, keyCode: HotkeyTrigger.fnKeyCode, flags: flags)
    }

    private func modifier(_ keyCode: UInt16, _ flags: CGEventFlags) -> HotkeyKeyEvent {
        HotkeyKeyEvent(kind: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    private func down(_ keyCode: UInt16, _ flags: CGEventFlags = [], repeating: Bool = false) -> HotkeyKeyEvent {
        HotkeyKeyEvent(kind: .keyDown, keyCode: keyCode, flags: flags, isAutorepeat: repeating)
    }

    private func up(_ keyCode: UInt16, _ flags: CGEventFlags = []) -> HotkeyKeyEvent {
        HotkeyKeyEvent(kind: .keyUp, keyCode: keyCode, flags: flags)
    }

    /// Flags as the OS reports them for held sided keys: the family flag plus each key's device bit.
    private func held(_ keyCodes: UInt16...) -> CGEventFlags {
        var raw: UInt64 = 0
        for code in keyCodes {
            let key = HotkeyTrigger.modifierKeys[code]!
            raw |= key.deviceBit | HotkeyTrigger.familyFlags[key.family]!.rawValue
        }
        return CGEventFlags(rawValue: raw)
    }

    private let rightOptionTrigger = HotkeyTrigger(keyCode: 61, modifiers: [])

    // MARK: Fn trigger (the cases from before triggers were configurable)

    @Test("Replacing the secondary mask while Fn is held still yields the Fn up edge")
    func maskChangeKeepsHeldFn() {
        var tracker = tracker()
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
        var replaced = tracker.replacingSecondaryMask([.maskShift, .maskCommand])
        #expect(replaced.secondaryMask == [.maskShift, .maskCommand])
        #expect(replaced.edges(for: flags([])) == [.primaryUp])
    }

    @Test("Replacing the mask carries a held secondary combo and a pending baseline")
    func maskChangeKeepsSecondaryAndSeeding() {
        var held = tracker()
        _ = held.edges(for: flags([.maskControl, .maskAlternate]))
        var replaced = held.replacingSecondaryMask([.maskShift])
        #expect(replaced.edges(for: flags([])) == [.secondaryUp])

        var blind = tracker()
        blind.reset()
        var swapped = blind.replacingSecondaryMask([.maskShift])
        #expect(swapped.edges(for: flags([.maskSecondaryFn])).isEmpty)   // first snapshot after reset is still swallowed
    }

    @Test("Fn down then up yields one edge each")
    func fnDownUp() {
        var tracker = tracker()
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
        #expect(tracker.edges(for: flags([])) == [.primaryUp])
    }

    @Test("Repeated identical snapshots yield no edges")
    func noSpuriousEdges() {
        var tracker = tracker()
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
        #expect(tracker.edges(for: flags([.maskSecondaryFn])).isEmpty)   // unchanged
        #expect(tracker.edges(for: flags([.maskSecondaryFn])).isEmpty)
    }

    @Test("Secondary combo requires all mask bits")
    func secondaryComboNeedsAllBits() {
        var tracker = tracker()
        #expect(tracker.edges(for: flags([.maskControl])).isEmpty)        // partial: no edge
        #expect(tracker.edges(for: flags([.maskControl, .maskAlternate])) == [.secondaryDown])
        #expect(tracker.edges(for: flags([.maskControl])) == [.secondaryUp])   // dropped a bit
    }

    @Test("One packet toggling both Fn and secondary yields both edges, Fn first")
    func bothEdgesInOnePacket() {
        var tracker = tracker()
        // The bug this guards: the old shell early-returned after Fn and dropped
        // the secondary edge, desyncing the secondary source.
        let edges = tracker.edges(for: flags([.maskSecondaryFn, .maskControl, .maskAlternate]))
        #expect(edges == [.primaryDown, .secondaryDown])
    }

    @Test("First snapshot after reset seeds the baseline silently")
    func resetSeedsSilently() {
        var tracker = tracker()
        _ = tracker.edges(for: flags([.maskSecondaryFn]))     // Fn down
        #expect(tracker.fnFlagDown)
        // Tap re-enabled after a blind window; whatever the first snapshot says
        // is adopted as the baseline without emitting edges.
        tracker.reset()
        #expect(tracker.edges(for: flags([.maskSecondaryFn])).isEmpty)   // still held: no edge
        #expect(tracker.fnFlagDown)                                       // baseline adopted
        // The real release, observed live, now produces a correct up edge...
        #expect(tracker.edges(for: flags([])) == [.primaryUp])
        // ...and the next press a correct down edge.
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
    }

    @Test("Ambiguous post-reset packet cannot start a spurious session")
    func postResetPacketWithOtherModifierEmitsNothing() {
        var tracker = tracker()
        _ = tracker.edges(for: flags([.maskSecondaryFn]))     // dictating, Fn held
        tracker.reset()                                        // secure input killed the tap
        // User, still holding Fn, presses Shift to type a password character. The
        // packet {Fn, Shift} must NOT read as an Fn-down edge: the old behavior
        // started a dictation session here and deleted Shift's transition packet.
        #expect(tracker.edges(for: flags([.maskSecondaryFn, .maskShift])).isEmpty)
        // Follow-up changes are tracked normally from the adopted baseline.
        #expect(tracker.edges(for: flags([.maskShift])) == [.primaryUp])
    }

    @Test("A missed trigger is the accepted cost of an ambiguous resync")
    func freshPressAfterResetIsMissedOnce() {
        var tracker = tracker()
        tracker.reset()
        // If the very first packet after re-enable IS a fresh Fn press, it seeds
        // silently: the plan prefers a missed trigger over an ambiguous consume.
        #expect(tracker.edges(for: flags([.maskSecondaryFn])).isEmpty)
        // Releasing and pressing again works normally.
        #expect(tracker.edges(for: flags([])) == [.primaryUp])
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
    }

    @Test("Without reset, a missed up-event would swallow the next down edge")
    func staleStateSwallowsNextDownWithoutReset() {
        var tracker = tracker()
        _ = tracker.edges(for: flags([.maskSecondaryFn]))     // Fn down, taken
        // No up edge delivered (tap was disabled). A later Fn-down snapshot looks
        // identical to the stranded state, so no edge is produced, which is
        // exactly why the shell must call reset() on every re-enable.
        #expect(tracker.edges(for: flags([.maskSecondaryFn])).isEmpty)
    }

    @Test("Init is seeded: the first-ever Fn press emits immediately")
    func initIsSeeded() {
        var tracker = tracker()
        // No silent-seed penalty on a fresh launch: dictation works on the very
        // first press after the tap installs.
        #expect(tracker.edges(for: flags([.maskSecondaryFn])) == [.primaryDown])
    }

    @Test("Fn is detected by its flag whatever keycode the packet carries")
    func fnIgnoresKeyCode() {
        var tracker = tracker()
        #expect(tracker.edges(for: modifier(leftCommand, [.maskSecondaryFn])) == [.primaryDown])
        #expect(tracker.edges(for: modifier(leftCommand, [])) == [.primaryUp])
    }

    @Test("Fn held when the trigger becomes Fn is not taken, so its release is not consumed")
    func fnHeldBeforeBecomingTriggerIsNotTaken() {
        var tracker = tracker(rightOptionTrigger)
        _ = tracker.edges(for: flags([.maskSecondaryFn]))       // Fn passes: not the trigger
        var switched = tracker.replacingTrigger(.fn)
        #expect(switched.edges(for: flags([])).isEmpty)          // its release must pass too
    }

    // MARK: Sided modifier trigger

    @Test("A sided modifier trigger goes down and up by its own device bit")
    func sidedTriggerUsesDeviceBit() {
        var tracker = tracker(rightOptionTrigger)
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
        #expect(tracker.edges(for: modifier(rightOption, [])) == [.primaryUp])
    }

    @Test("Releasing a trigger key whose press passed through never reads as a press")
    func releaseWithSiblingHeldIsNotAPress() {
        var tracker = tracker(rightOptionTrigger)
        // Hold Command, press Right Option: the held Command does not match, so it passes.
        _ = tracker.edges(for: modifier(leftCommand, held(leftCommand)))
        #expect(tracker.edges(for: modifier(rightOption, held(leftCommand, rightOption))).isEmpty)
        // Press Left Option, release Command, then release Right Option. The family
        // flag stays set (Left Option) and the modifiers now match, but the key is
        // not taken and its device bit is clear, so this is not a press.
        _ = tracker.edges(for: modifier(leftOption, held(leftCommand, rightOption, leftOption)))
        _ = tracker.edges(for: modifier(leftCommand, held(rightOption, leftOption)))
        #expect(tracker.edges(for: modifier(rightOption, held(leftOption))).isEmpty)
        // Its next real press is still an ordinary press.
        _ = tracker.edges(for: modifier(leftOption, []))
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
    }

    @Test("The release of a taken key is an up edge even while its sibling is held")
    func releaseOfTakenKeyWithSiblingHeld() {
        var tracker = tracker(rightOptionTrigger)
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
        _ = tracker.edges(for: modifier(leftOption, held(rightOption, leftOption)))
        #expect(tracker.edges(for: modifier(rightOption, held(leftOption))) == [.primaryUp])
    }

    @Test("The sibling key never carries a primary edge")
    func siblingKeyIsNotThePrimary() {
        var tracker = tracker(rightOptionTrigger)
        #expect(tracker.edges(for: modifier(leftOption, held(leftOption))).isEmpty)
        #expect(tracker.edges(for: modifier(leftOption, [])).isEmpty)
    }

    @Test("A bare modifier trigger fires with the trigger key's own family set")
    func bareSidedTriggerExcludesItsOwnFamily() {
        var tracker = tracker(rightOptionTrigger)
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
    }

    @Test("A sided trigger with modifiers fires only on an exact modifier match")
    func sidedTriggerWithModifiers() {
        var tracker = tracker(HotkeyTrigger(keyCode: rightOption, modifiers: ["command"]))
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))).isEmpty)   // missing Command
        _ = tracker.edges(for: modifier(rightOption, []))
        _ = tracker.edges(for: modifier(leftCommand, held(leftCommand)))
        #expect(tracker.edges(for: modifier(rightOption, held(leftCommand, rightOption))) == [.primaryDown])
    }

    @Test("A sided key's secondary edge in the same packet follows the primary edge")
    func sidedTriggerAndChordInOnePacket() {
        var tracker = FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate],
                                      trigger: HotkeyTrigger(keyCode: rightOption, modifiers: ["control"]))
        let control = CGEventFlags(rawValue: HotkeyTrigger.modifierKeys[59]!.deviceBit | CGEventFlags.maskControl.rawValue)
        _ = tracker.edges(for: modifier(59, control))
        let both = tracker.edges(for: modifier(rightOption, [control, held(rightOption)]))
        #expect(both == [.primaryDown, .secondaryDown])
    }

    @Test("Right Option is a trigger while Left Option stays in the chord")
    func sidedTriggerCoexistsWithChordKey() {
        var tracker = tracker(rightOptionTrigger)    // chord is control + option
        #expect(tracker.edges(for: modifier(59, held(59))).isEmpty)
        // Left Option completes the chord; it is a secondary edge, never a primary one.
        #expect(tracker.edges(for: modifier(leftOption, held(59, leftOption))) == [.secondaryDown])
    }

    // MARK: Regular-key trigger

    @Test("A regular-key trigger fires on keyDown and releases on its own keyUp")
    func regularKeyDownUp() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyF13, modifiers: []))
        #expect(tracker.edges(for: down(keyF13)) == [.primaryDown])
        #expect(tracker.edges(for: up(keyF13)) == [.primaryUp])
    }

    @Test("A regular-key trigger with modifiers fires only on an exact match")
    func regularKeyExactModifiers() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: ["command"]))
        #expect(tracker.edges(for: down(keyD)).isEmpty)                                       // no Command
        #expect(tracker.edges(for: up(keyD)).isEmpty)                                         // not taken: never an edge
        #expect(tracker.edges(for: down(keyD, [.maskCommand, .maskShift])).isEmpty)           // extra Shift
        _ = tracker.edges(for: up(keyD))
        #expect(tracker.edges(for: down(keyD, [.maskCommand, .maskAlphaShift, .maskSecondaryFn])) == [.primaryDown])   // Caps Lock and Fn bits are ignored
        #expect(tracker.edges(for: up(keyD, [.maskCommand])) == [.primaryUp])
    }

    @Test("The autorepeat of a taken key is a repeat, never a fresh press")
    func autorepeatOfTakenKey() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        #expect(tracker.edges(for: down(keyD)) == [.primaryDown])
        #expect(tracker.edges(for: down(keyD, repeating: true)) == [.primaryRepeat])
        #expect(tracker.edges(for: down(keyD, repeating: true)) == [.primaryRepeat])
        #expect(tracker.edges(for: up(keyD)) == [.primaryUp])
    }

    @Test("An autorepeat of a key that was not taken never takes it")
    func autorepeatNeverTakes() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: ["command"]))
        // D typed first (passes), then Command pressed while D repeats: the repeat
        // now carries a matching Command but must not take the key.
        #expect(tracker.edges(for: down(keyD)).isEmpty)
        #expect(tracker.edges(for: down(keyD, [.maskCommand], repeating: true)).isEmpty)
        #expect(tracker.edges(for: up(keyD, [.maskCommand])).isEmpty)
    }

    @Test("A keyUp for a key that was not taken is never an edge")
    func keyUpWithoutTake() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        #expect(tracker.edges(for: up(keyD)).isEmpty)
        #expect(tracker.edges(for: up(keyF13)).isEmpty)
    }

    @Test("Other keys never produce primary edges")
    func otherKeysAreIgnored() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        #expect(tracker.edges(for: down(keyF13)).isEmpty)
        #expect(tracker.edges(for: up(keyF13)).isEmpty)
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))).isEmpty)
    }

    @Test("A fresh non-repeat press of the taken key means its up was missed")
    func freshPressOfTakenKey() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: ["command"]))
        #expect(tracker.edges(for: down(keyD, [.maskCommand])) == [.primaryDown])
        // The up was missed; the key goes down again without Command: judged fresh, does not match.
        #expect(tracker.edges(for: down(keyD)).isEmpty)
        #expect(tracker.edges(for: up(keyD)).isEmpty)
    }

    // MARK: Changes while held, and reset

    @Test("A trigger change while the key is held still releases on the old key")
    func triggerChangeWhileHeld() {
        var tracker = tracker(rightOptionTrigger)
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
        var changed = tracker.replacingTrigger(HotkeyTrigger(keyCode: keyD, modifiers: []))
        #expect(changed.edges(for: modifier(rightOption, [])) == [.primaryUp])
        // The new trigger applies from the next press.
        #expect(changed.edges(for: down(keyD)) == [.primaryDown])

        var regular = FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate],
                                      trigger: HotkeyTrigger(keyCode: keyD, modifiers: []))
        _ = regular.edges(for: down(keyD))
        var other = regular.replacingTrigger(.fn)
        #expect(other.edges(for: up(keyD)) == [.primaryUp])
    }

    @Test("Reset clears a taken modifier key")
    func resetClearsTakenModifier() {
        var tracker = tracker(rightOptionTrigger)
        _ = tracker.edges(for: modifier(rightOption, held(rightOption)))
        tracker.reset()
        #expect(tracker.taken == nil)
        #expect(tracker.edges(for: modifier(rightOption, [])).isEmpty)    // re-seed
        #expect(tracker.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
    }

    @Test("Reset keeps a taken regular key, so its repeats and keyUp are still consumed")
    func resetKeepsTakenRegularKey() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        _ = tracker.edges(for: down(keyD))
        tracker.reset()
        #expect(tracker.edges(for: down(keyD, repeating: true)) == [.primaryRepeat])
        #expect(tracker.edges(for: up(keyD)) == [.primaryUp])
    }

    @Test("Reset keeps a taken regular key the probe reports down, and clears one it reports up")
    func resetConsultsTheKeyProbe() {
        var held = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        _ = held.edges(for: down(keyD))
        held.reset(isKeyDown: { $0 == keyD })
        #expect(held.taken == keyD)

        var released = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        _ = released.edges(for: down(keyD))
        released.reset(isKeyDown: { _ in false })
        #expect(released.taken == nil)
    }

    @Test("A new trigger takes on its first press once the old trigger's stale take is cleared")
    func staleTakeDoesNotBlockNewTrigger() {
        var stale = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        _ = stale.edges(for: down(keyD))                 // D's release is then missed
        var withStaleTake = stale.replacingTrigger(rightOptionTrigger)
        withStaleTake.reset()                            // default probe keeps the take
        _ = withStaleTake.edges(for: modifier(rightOption, []))   // re-seed
        #expect(withStaleTake.edges(for: modifier(rightOption, held(rightOption))).isEmpty)

        stale.reset(isKeyDown: { _ in false })
        var cleared = stale.replacingTrigger(rightOptionTrigger)
        _ = cleared.edges(for: modifier(rightOption, []))         // re-seed
        #expect(cleared.edges(for: modifier(rightOption, held(rightOption))) == [.primaryDown])
    }

    @Test("Regular-key events are not held back by an unseeded baseline")
    func regularKeysIgnoreSeeding() {
        var tracker = tracker(HotkeyTrigger(keyCode: keyD, modifiers: []))
        tracker.reset()
        #expect(tracker.edges(for: down(keyD)) == [.primaryDown])
    }
}
