import CoreGraphics
import Testing
@testable import Vizpr

/// The fail-open property is a property of the tracker, the machine and the
/// shell's packet deletion together: each half behaves as specified in the
/// sequences the trigger-plan review found, and the composition eats the wrong
/// event. These tests run `HotkeyEventRouter.route` over random streams of
/// physical key presses and assert, for the composition:
///
/// 1. A consumed event's keycode is the configured trigger's or the taken key's.
/// 2. For each physical press, either none of its events are consumed or its
///    down was consumed.
/// 3. A consumed down is followed by a consumed up, except across a reset that
///    clears a modifier key (passing a modifier's release is self-correcting).
/// 4. Every autorepeat of a press whose down was consumed is consumed.
///
/// Two exceptions are by design and are modeled by name, not hidden (see
/// NOTES.md "Known limits"):
/// - Fn keeps its field-tested flag detection, so an Fn held at a silent re-seed
///   while Fn is the trigger is treated as the trigger's own press and its up is
///   consumed although its down was not seen (`takenAtReseed`).
/// - A regular key taken across a reset stays taken, so a press made in the same
///   blind window as the earlier release has its release consumed
///   (`inheritedStaleTake`).
@Suite("HotkeyEventRouter composed fail-open properties")
struct HotkeyEventRouterTests {

    // MARK: Universe

    private static let sidedKeys: [UInt16] = [54, 55, 56, 58, 59, 60, 61, 62]
    private static let regularKeys: [UInt16] = [0, 2, 49, 105]
    private static let allKeys: [UInt16] = sidedKeys + [HotkeyTrigger.fnKeyCode] + regularKeys

    private static let triggers: [HotkeyTrigger] = [
        .fn,
        HotkeyTrigger(keyCode: 61, modifiers: []),                  // Right Option
        HotkeyTrigger(keyCode: 55, modifiers: []),                  // Left Command
        HotkeyTrigger(keyCode: 61, modifiers: ["command"]),
        HotkeyTrigger(keyCode: 62, modifiers: []),                  // Right Control
        HotkeyTrigger(keyCode: 2, modifiers: []),                   // D
        HotkeyTrigger(keyCode: 2, modifiers: ["command"]),
        HotkeyTrigger(keyCode: 105, modifiers: ["control"]),        // F13
        HotkeyTrigger(keyCode: 49, modifiers: ["shift"]),           // Space
        HotkeyTrigger(keyCode: 2, modifiers: ["control", "option"]) // contains the default chord: refused by clamped(), must still be safe
    ]

    private static let masks: [CGEventFlags] = [
        [.maskControl, .maskAlternate], [.maskShift, .maskCommand], [.maskControl, .maskShift]
    ]

    // MARK: Simulation

    private struct Press {
        /// nil when the down was never delivered (a blind window).
        var downConsumed: Bool?
        /// Fn held at a silent re-seed while Fn was the trigger: the tracker took it
        /// although its down was not consumed.
        var takenAtReseed = false
        var resetSinceDown = false
        /// A regular key pressed in a blind window while the tracker still held it
        /// as taken from an earlier press whose release was also missed. The plan
        /// keeps a taken regular key across a reset so a held key's repeats do not
        /// leak; the cost is that this press's release is consumed too.
        var inheritedStaleTake = false
    }

    private final class Simulation {
        var rng: SplitMix64
        var tracker = FlagEdgeTracker(secondaryMask: HotkeyEventRouterTests.masks[0])
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200))
        var keysDown: Set<UInt16> = []
        var presses: [UInt16: Press] = [:]
        var clock: UInt64 = 1
        var blind = false
        var violations: [String] = []
        /// Whether the most recent `deliver` took Fn at a silent re-seed.
        var lastDeliverTookFnAtReseed = false
        /// The last events and operations, printed with a violation.
        var history: [String] = []
        let seed: UInt64

        init(seed: UInt64) {
            self.seed = seed
            rng = SplitMix64(seed: seed)
        }

        private func isModifier(_ key: UInt16) -> Bool {
            key == HotkeyTrigger.fnKeyCode || HotkeyTrigger.modifierKeys[key] != nil
        }

        private func currentFlags() -> CGEventFlags {
            var raw: UInt64 = 0
            for key in keysDown {
                if let sided = HotkeyTrigger.modifierKeys[key] {
                    raw |= sided.deviceBit | HotkeyTrigger.familyFlags[sided.family]!.rawValue
                }
                if key == HotkeyTrigger.fnKeyCode { raw |= CGEventFlags.maskSecondaryFn.rawValue }
            }
            return CGEventFlags(rawValue: raw)
        }

        private func fail(_ message: String, _ event: HotkeyKeyEvent) {
            let press = String(describing: presses[event.keyCode])
            let recent = history.suffix(30).joined(separator: " | ")
            violations.append("seed \(seed): \(message) on \(event) with trigger \(tracker.trigger); press \(press); recent: \(recent)")
        }

        /// Run one event through the router and check properties 1 and 0.
        private func deliver(_ event: HotkeyKeyEvent) -> HotkeyEventRouter.Outcome {
            clock += UInt64.random(in: 0...400, using: &rng)
            let takenBefore = tracker.taken
            let triggerKey = tracker.trigger.keyCode
            let fnReseedPossible = event.kind == .flagsChanged && !tracker.isSeeded
                && tracker.trigger.isFn && keysDown.contains(HotkeyTrigger.fnKeyCode) && takenBefore == nil
            let outcome = HotkeyEventRouter.route(
                event, at: MonotonicTime(nanoseconds: clock * 1_000_000),
                tracker: &tracker, machine: &machine
            )
            lastDeliverTookFnAtReseed = fnReseedPossible && tracker.taken == HotkeyTrigger.fnKeyCode
            if lastDeliverTookFnAtReseed { presses[HotkeyTrigger.fnKeyCode]?.takenAtReseed = true }
            let repeatMark = event.isAutorepeat ? "r" : ""
            let takenAfter = String(describing: tracker.taken)
            history.append("\(event.kind) k\(event.keyCode)\(repeatMark) \(outcome.edges) taken=\(String(describing: takenBefore))->\(takenAfter)")
            if outcome.suppress != outcome.edges.contains(where: \.isPrimary) {
                fail("an event was consumed without a primary edge, or the reverse", event)
            }
            if outcome.suppress, event.keyCode != triggerKey, event.keyCode != takenBefore {
                fail("consumed an event of key \(event.keyCode), which is neither the trigger nor the taken key", event)
            }
            return outcome
        }

        func press(_ key: UInt16) {
            guard !keysDown.contains(key) else { return }
            keysDown.insert(key)
            if blind {
                history.append("blind press k\(key)")
                presses[key] = Press(
                    downConsumed: nil,
                    inheritedStaleTake: !isModifier(key) && tracker.taken == key
                )
                return
            }
            let event = isModifier(key)
                ? HotkeyKeyEvent(kind: .flagsChanged, keyCode: key, flags: currentFlags())
                : HotkeyKeyEvent(kind: .keyDown, keyCode: key, flags: currentFlags())
            let outcome = deliver(event)
            presses[key] = Press(
                downConsumed: outcome.suppress,
                takenAtReseed: key == HotkeyTrigger.fnKeyCode && lastDeliverTookFnAtReseed
            )
        }

        func autorepeat(_ key: UInt16) {
            guard !blind, keysDown.contains(key), !isModifier(key) else { return }
            let event = HotkeyKeyEvent(kind: .keyDown, keyCode: key, flags: currentFlags(), isAutorepeat: true)
            let outcome = deliver(event)
            if outcome.suppress, !consumptionAllowed(key) { fail("consumed a repeat whose down was not consumed", event) }
            if !outcome.suppress, let press = presses[key], press.downConsumed == true || press.inheritedStaleTake {
                fail("a repeat of a consumed press reached the app", event)
            }
        }

        func release(_ key: UInt16) {
            guard keysDown.contains(key) else { return }
            keysDown.remove(key)
            guard !blind else { history.append("blind release k\(key)"); return }
            let event = isModifier(key)
                ? HotkeyKeyEvent(kind: .flagsChanged, keyCode: key, flags: currentFlags())
                : HotkeyKeyEvent(kind: .keyUp, keyCode: key, flags: currentFlags())
            let outcome = deliver(event)
            if outcome.suppress, !consumptionAllowed(key) { fail("consumed an up whose down was not consumed", event) }
            if !outcome.suppress, let press = presses[key], press.downConsumed == true, !press.resetSinceDown {
                fail("a consumed down was followed by an up that reached the app", event)
            }
        }

        private func consumptionAllowed(_ key: UInt16) -> Bool {
            guard let press = presses[key] else { return false }
            if press.downConsumed == true || press.inheritedStaleTake { return true }
            // Fn's by-design exception: taken at a silent re-seed while Fn is the trigger.
            return press.takenAtReseed
        }

        /// The shell's blind-window recovery: events during the window reach the
        /// app untouched, then the tracker and machine are reset.
        func blindWindow() {
            history.append("BLIND start")
            blind = true
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let key = HotkeyEventRouterTests.allKeys.randomElement(using: &rng)!
                keysDown.contains(key) ? release(key) : press(key)
            }
            blind = false
            tracker.reset(isKeyDown: { [keysDown] in keysDown.contains($0) })
            history.append("BLIND end, down=\(keysDown.sorted()) taken=\(String(describing: tracker.taken))")
            _ = machine.handle(.tapDisabled(.timeout))
            for key in presses.keys where isModifier(key) { presses[key]?.resetSinceDown = true }
        }

        func step() {
            let keys = HotkeyEventRouterTests.allKeys
            switch UInt8.random(in: 0...14, using: &rng) {
            case 0...4:
                press(keys.randomElement(using: &rng)!)
            case 5...8:
                let held = keysDown.sorted()
                if let key = held.randomElement(using: &rng) { release(key) }
            case 9, 10:
                let held = keysDown.sorted()
                if let key = held.randomElement(using: &rng) { autorepeat(key) }
            case 11:
                blindWindow()
            case 12:
                tracker = tracker.replacingTrigger(HotkeyEventRouterTests.triggers.randomElement(using: &rng)!)
                history.append("TRIGGER \(tracker.trigger)")
            case 13:
                tracker = tracker.replacingSecondaryMask(HotkeyEventRouterTests.masks.randomElement(using: &rng)!)
            default:
                // Non-key machine inputs that change what the machine would do next.
                let input: HotkeyInput = [.escape, .autoStop, .captureFailed][Int.random(in: 0...2, using: &rng)]
                _ = machine.handle(input)
            }
        }
    }

    // MARK: Properties

    @Test("Across random physical key streams, only the trigger's own events are consumed, and a down and its up are consumed together")
    func composedFailOpen() {
        for seed in UInt64(1)...600 {
            let simulation = Simulation(seed: seed)
            simulation.tracker = simulation.tracker.replacingTrigger(
                Self.triggers.randomElement(using: &simulation.rng)!
            )
            for _ in 0..<200 { simulation.step() }
            #expect(simulation.violations.isEmpty, "\(simulation.violations.first ?? "")")
        }
    }

    // MARK: The sequences the review found, end to end

    private func route(
        _ event: HotkeyKeyEvent, at ms: UInt64,
        _ tracker: inout FlagEdgeTracker, _ machine: inout HotkeyStateMachine
    ) -> HotkeyEventRouter.Outcome {
        HotkeyEventRouter.route(event, at: MonotonicTime(nanoseconds: ms * 1_000_000),
                                tracker: &tracker, machine: &machine)
    }

    @Test("Holding a regular-key trigger past the repeat delay after the commit press starts nothing")
    func commitPressRepeatDoesNotRestart() {
        var tracker = FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate],
                                      trigger: HotkeyTrigger(keyCode: 2, modifiers: []))
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200))
        func key(_ kind: HotkeyKeyEvent.Kind, repeating: Bool = false) -> HotkeyKeyEvent {
            HotkeyKeyEvent(kind: kind, keyCode: 2, flags: [], isAutorepeat: repeating)
        }
        #expect(route(key(.keyDown), at: 0, &tracker, &machine).decisions.first?.action == .startDictation)
        #expect(route(key(.keyUp), at: 100, &tracker, &machine).suppress)               // tap: latches
        #expect(route(key(.keyDown), at: 2000, &tracker, &machine).decisions.first?.action == .commit)
        let repeats = route(key(.keyDown, repeating: true), at: 2500, &tracker, &machine)
        #expect(repeats.suppress)
        #expect(repeats.decisions.allSatisfy { $0.action == nil })
        #expect(machine.state == .idle)
        #expect(route(key(.keyUp), at: 3000, &tracker, &machine).suppress)
    }

    @Test("A typed key that gains the trigger's modifiers while repeating is never eaten")
    func typedKeyThenModifierIsNotTaken() {
        var tracker = FlagEdgeTracker(secondaryMask: [.maskShift, .maskControl],
                                      trigger: HotkeyTrigger(keyCode: 2, modifiers: ["command"]))
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200))
        let typed = HotkeyKeyEvent(kind: .keyDown, keyCode: 2, flags: [], isAutorepeat: false)
        let repeated = HotkeyKeyEvent(kind: .keyDown, keyCode: 2, flags: [.maskCommand], isAutorepeat: true)
        let released = HotkeyKeyEvent(kind: .keyUp, keyCode: 2, flags: [.maskCommand])
        #expect(!route(typed, at: 0, &tracker, &machine).suppress)
        #expect(!route(repeated, at: 500, &tracker, &machine).suppress)
        #expect(!route(released, at: 900, &tracker, &machine).suppress)
    }

    @Test("A trigger key held across a blind window has its repeats and release consumed")
    func heldRegularKeyAcrossBlindWindow() {
        var tracker = FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate],
                                      trigger: HotkeyTrigger(keyCode: 2, modifiers: []))
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200))
        _ = route(HotkeyKeyEvent(kind: .keyDown, keyCode: 2, flags: []), at: 0, &tracker, &machine)
        tracker.reset()
        _ = machine.handle(.tapDisabled(.timeout))
        let held = route(HotkeyKeyEvent(kind: .keyDown, keyCode: 2, flags: [], isAutorepeat: true),
                         at: 500, &tracker, &machine)
        #expect(held.suppress)
        #expect(held.decisions.allSatisfy { $0.action == nil })
        #expect(route(HotkeyKeyEvent(kind: .keyUp, keyCode: 2, flags: []), at: 900, &tracker, &machine).suppress)
    }

    @Test("Right Option as the trigger leaves Left Option's events alone")
    func siblingModifierIsNeverConsumed() {
        var tracker = FlagEdgeTracker(secondaryMask: [.maskControl, .maskAlternate],
                                      trigger: HotkeyTrigger(keyCode: 61, modifiers: []))
        var machine = HotkeyStateMachine(holdThreshold: .milliseconds(200))
        let leftBit = HotkeyTrigger.modifierKeys[58]!.deviceBit
        let rightBit = HotkeyTrigger.modifierKeys[61]!.deviceBit
        let option = CGEventFlags.maskAlternate.rawValue
        let leftDown = HotkeyKeyEvent(kind: .flagsChanged, keyCode: 58, flags: CGEventFlags(rawValue: option | leftBit))
        let rightDown = HotkeyKeyEvent(kind: .flagsChanged, keyCode: 61,
                                       flags: CGEventFlags(rawValue: option | leftBit | rightBit))
        let rightUp = HotkeyKeyEvent(kind: .flagsChanged, keyCode: 61, flags: CGEventFlags(rawValue: option | leftBit))
        let leftUp = HotkeyKeyEvent(kind: .flagsChanged, keyCode: 58, flags: [])
        #expect(!route(leftDown, at: 0, &tracker, &machine).suppress)
        #expect(route(rightDown, at: 100, &tracker, &machine).suppress)
        #expect(route(rightUp, at: 200, &tracker, &machine).suppress)
        #expect(!route(leftUp, at: 300, &tracker, &machine).suppress)
    }
}
