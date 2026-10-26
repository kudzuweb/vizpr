import CoreGraphics

/// Derives discrete key edges from keyboard events (PLAN.md §6 + §8): the
/// primary trigger's down, repeat and up, and the secondary chord's down and up.
///
/// **Which events become primary edges.** Only the trigger key's own events,
/// identified by keycode and, for a sided modifier such as Right Option, by that
/// key's own device bit in the event flags. Fn is the exception: it has no
/// device bit and its keycode is unverified across keyboards, so it keeps the
/// field-tested detection by comparing the Fn flag with the previous snapshot.
/// A key the tracker takes is *taken* until its up edge, and the tracker emits an
/// up edge only for a key it took, so a key whose down reached an app is not
/// followed by an up the app does not see, with two exceptions documented under
/// `reset()` and in NOTES.md "Known limits": an Fn held at a silent re-seed, and
/// a regular key released and re-pressed inside one blind window.
///
/// "Modifiers match" means the held modifier families, masked to the four
/// families, equal the trigger's modifiers exactly; for a modifier-key trigger
/// the trigger key's own family is excluded from the held set. Every other flag
/// bit is ignored, so a trigger "⌘D" does not fire on "⌘⇧D". The Fn trigger has
/// no modifiers and ignores the held ones, as it always has.
///
/// `flagsChanged` reports the *entire* modifier set on every change, so the
/// secondary chord and Fn are detected by comparing against the previous
/// snapshot. That comparison has real failure modes (stale state after a missed
/// event; two modifiers changing in one packet), so it lives here as a pure
/// value type, testable with synthetic events and no CGEventTap.
struct FlagEdgeTracker {
    /// A single key transition derived from an event.
    enum Edge: Equatable, Sendable {
        case primaryDown, primaryUp
        /// An autorepeat of the taken key's down.
        case primaryRepeat
        case secondaryDown, secondaryUp

        var isPrimary: Bool {
            switch self {
            case .primaryDown, .primaryUp, .primaryRepeat: return true
            case .secondaryDown, .secondaryUp: return false
            }
        }
    }

    /// The modifiers that together form the secondary activation combo.
    let secondaryMask: CGEventFlags
    let trigger: HotkeyTrigger

    /// The keycode of the primary key whose down was turned into an edge and
    /// whose up has not yet arrived.
    private(set) var taken: UInt16?
    private(set) var fnFlagDown = false
    private(set) var secondaryActive = false
    /// True while an Fn press that reached the app (it was not the trigger when it
    /// went down) is still held. Survives `reset()`, so a re-seed never mistakes
    /// that Fn for the trigger's own press.
    private var fnPassedThrough = false

    /// Whether the `fnFlagDown`/`secondaryActive` baselines are trustworthy.
    /// True from init (a fresh launch starts from "nothing held", so the first
    /// Fn press must emit immediately); false after `reset()`, because a reset
    /// follows a blind window in which any number of events were missed.
    private(set) var isSeeded = true

    init(secondaryMask: CGEventFlags, trigger: HotkeyTrigger = .fn) {
        // The secondary combo must not include Fn, or one physical key would be
        // both consumed (as the trigger) and tracked as a benign modifier.
        precondition(!secondaryMask.contains(.maskSecondaryFn),
                     "secondaryMask must not include the Fn flag")
        self.secondaryMask = secondaryMask
        self.trigger = trigger
    }

    /// A tracker for a different chord that keeps this one's held-key state and
    /// seeding, so a key held across the change still yields its up edge, and a
    /// pending post-`reset()` baseline is still swallowed.
    func replacingSecondaryMask(_ mask: CGEventFlags) -> FlagEdgeTracker {
        carrying(secondaryMask: mask, trigger: trigger)
    }

    /// A tracker for a different trigger that keeps the held-key state. The key
    /// already taken stays taken, so its up is still consumed and the session
    /// ends normally; the new trigger applies from the next press.
    func replacingTrigger(_ trigger: HotkeyTrigger) -> FlagEdgeTracker {
        carrying(secondaryMask: secondaryMask, trigger: trigger)
    }

    private func carrying(secondaryMask: CGEventFlags, trigger: HotkeyTrigger) -> FlagEdgeTracker {
        var replacement = FlagEdgeTracker(secondaryMask: secondaryMask, trigger: trigger)
        replacement.taken = taken
        replacement.fnFlagDown = fnFlagDown
        replacement.fnPassedThrough = fnPassedThrough
        replacement.secondaryActive = secondaryActive
        replacement.isSeeded = isSeeded
        return replacement
    }

    /// Fold one event in and return the edges it produced, primary first. Updates
    /// internal state. Returns an empty array when nothing crossed a boundary.
    mutating func edges(for event: HotkeyKeyEvent) -> [Edge] {
        switch event.kind {
        case .flagsChanged: return flagsChangedEdges(event)
        case .keyDown: return keyDownEdges(event)
        case .keyUp: return keyUpEdges(event)
        }
    }

    /// Clear edge state after a blind window (tap disable/re-enable, stop, a
    /// suspension). The next `flagsChanged` re-seeds the baseline silently: after
    /// a blind window we cannot tell "Fn is newly down" from "Fn was held the
    /// whole time", and emitting a down edge on that guess would start a spurious
    /// session and delete a packet that may carry another modifier's real
    /// transition (e.g. Shift while typing a password, the very situation that
    /// disables the tap). A missed trigger is annoying; an ambiguous consume is
    /// unacceptable.
    ///
    /// A taken modifier key is cleared: passing its release is self-correcting,
    /// because the event carries the full flag state. A taken regular key is kept
    /// while `isKeyDown` says it is physically down, so its repeats and its `keyUp`
    /// are still consumed after the blind window instead of reaching the app as a
    /// key-down-less repeat. A taken regular key that is already up is cleared,
    /// because its release was missed and a stale take would leave a newly chosen
    /// trigger dead until the old key was pressed again.
    mutating func reset(isKeyDown: (UInt16) -> Bool = { _ in true }) {
        if let taken, isModifierKeyCode(taken) || !isKeyDown(taken) { self.taken = nil }
        fnFlagDown = false
        secondaryActive = false
        isSeeded = false
    }

    // MARK: flagsChanged

    private mutating func flagsChangedEdges(_ event: HotkeyKeyEvent) -> [Edge] {
        let fn = event.flags.contains(.maskSecondaryFn)
        let combo = event.flags.contains(secondaryMask)

        guard isSeeded else {
            // An Fn held at the re-seed that was not seen passing through is treated
            // as the trigger's own press, whose up is consumed, exactly as before
            // triggers were configurable.
            if fn, taken == nil, trigger.isFn, !fnPassedThrough { taken = HotkeyTrigger.fnKeyCode }
            if !fn { fnPassedThrough = false }
            fnFlagDown = fn
            secondaryActive = combo
            isSeeded = true
            return []
        }

        var result: [Edge] = []
        let primary = primaryFlagsEdge(event, fn: fn)
        if let primary { result.append(primary) }
        if !fn {
            fnPassedThrough = false
        } else if !fnFlagDown, primary != .primaryDown {
            fnPassedThrough = true
        }
        fnFlagDown = fn

        if combo != secondaryActive {
            result.append(combo ? .secondaryDown : .secondaryUp)
            secondaryActive = combo
        }
        return result
    }

    private mutating func primaryFlagsEdge(_ event: HotkeyKeyEvent, fn: Bool) -> Edge? {
        if taken == HotkeyTrigger.fnKeyCode || (taken == nil && trigger.isFn) {
            // Fn is detected by its flag, whatever keycode the packet carries.
            if taken == nil, fn, !fnFlagDown {
                taken = HotkeyTrigger.fnKeyCode
                return .primaryDown
            }
            if taken != nil, !fn {
                taken = nil
                return .primaryUp
            }
            return nil
        }

        if let key = taken.flatMap({ HotkeyTrigger.modifierKeys[$0] }), event.keyCode == taken {
            // Down exactly while the key's own device bit is set, so a sibling
            // key keeping the family flag set never turns a release into a press.
            guard event.flags.rawValue & key.deviceBit == 0 else { return nil }
            taken = nil
            return .primaryUp
        }

        if taken == nil, event.keyCode == trigger.keyCode, let key = trigger.sidedKey,
           event.flags.rawValue & key.deviceBit != 0,
           modifiersMatch(event.flags, excludingFamily: key.family) {
            taken = event.keyCode
            return .primaryDown
        }
        return nil
    }

    // MARK: keyDown and keyUp

    private mutating func keyDownEdges(_ event: HotkeyKeyEvent) -> [Edge] {
        if event.isAutorepeat {
            // Only a non-repeat key-down can take a key.
            return event.keyCode == taken && !isModifierKeyCode(event.keyCode) ? [.primaryRepeat] : []
        }
        // A non-repeat down of the taken key means its up was missed: judge it
        // as a fresh press.
        if event.keyCode == taken, !isModifierKeyCode(event.keyCode) { taken = nil }

        guard taken == nil, event.keyCode == trigger.keyCode, !trigger.isModifierKey,
              modifiersMatch(event.flags, excludingFamily: nil)
        else { return [] }
        taken = event.keyCode
        return [.primaryDown]
    }

    private mutating func keyUpEdges(_ event: HotkeyKeyEvent) -> [Edge] {
        guard event.keyCode == taken, !isModifierKeyCode(event.keyCode) else { return [] }
        taken = nil
        return [.primaryUp]
    }

    // MARK: Helpers

    private func modifiersMatch(_ flags: CGEventFlags, excludingFamily family: String?) -> Bool {
        var held = flags.intersection(HotkeyTrigger.allFamilyFlags)
        if let family, let own = HotkeyTrigger.familyFlags[family] { held.remove(own) }
        return held == trigger.modifierMask
    }

    private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == HotkeyTrigger.fnKeyCode || HotkeyTrigger.modifierKeys[keyCode] != nil
    }
}
