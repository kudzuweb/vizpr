import Foundation

// MARK: - Time

/// A monotonic timestamp in nanoseconds since an arbitrary epoch.
///
/// Time is carried *in the inputs* rather than read inside the machine, so the
/// state machine stays a pure function. Tests drive it with a fake clock simply
/// by constructing inputs with chosen timestamps; production stamps inputs from
/// a monotonic clock in the shell.
struct MonotonicTime: Comparable, Hashable, Sendable {
    let nanoseconds: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    /// Elapsed time since an earlier instant. Saturates at zero — time is
    /// monotonic, so a non-increasing delta means clock noise, not a negative
    /// duration, and the safe interpretation is "no time passed."
    func elapsed(since earlier: MonotonicTime) -> Duration {
        let delta = nanoseconds >= earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
        return .nanoseconds(Int64(min(delta, UInt64(Int64.max))))
    }
}

// MARK: - Inputs

/// Which key started the current dictation. The primary trigger and the
/// secondary combo drive the same machine; tracking the source lets us pair a
/// down with its own up and suppress only the primary trigger (never the
/// secondary modifiers — see `EventDisposition`).
enum ActivationSource: Sendable, Hashable {
    case primary
    case secondary
}

/// Why the OS disabled our event tap. Both route to the same fail-open reset.
enum TapDisableReason: Sendable, Hashable {
    case timeout       // kCGEventTapDisabledByTimeout — callback was too slow
    case userInput     // kCGEventTapDisabledByUserInput — e.g. secure input engaged
}

/// Every event the machine can receive. Primary/secondary carry a timestamp so
/// the tap-vs-hold decision is a pure comparison. `thresholdElapsed` is delivered
/// by a shell timer to promote a held key into `holding`; it is an *optimization*
/// for reflecting hold state early — correctness does not depend on it, because
/// `primaryUp`/`secondaryUp` re-check the duration in `pressed` and `holding`
/// alike.
enum HotkeyInput: Sendable {
    case primaryDown(at: MonotonicTime)
    case primaryUp(at: MonotonicTime)
    case primaryRepeat                     // autorepeat of the held primary key: swallowed, never acts
    case secondaryDown(at: MonotonicTime)
    case secondaryUp(at: MonotonicTime)
    case escape
    case autoStop                          // VAD silence timeout in a latched session
    case captureFailed                     // audio capture died: end the session, nothing to commit
    case thresholdElapsed(at: MonotonicTime)
    case tapDisabled(TapDisableReason)
}

// MARK: - Outputs

/// What to do with the dictation session as a result of an input.
enum DictationAction: Sendable, Hashable {
    case startDictation
    case commit          // snapshot displayed text and inject (WYSIWYG)
    case cancel          // discard, inject nothing
}

/// What to do with the underlying CGEvent.
///
/// **Fail-open invariant:** `.consume` is emitted *only* for primary-trigger
/// inputs (down, up and repeat). Every other input — secondary modifiers,
/// Escape, and the non-CGEvent signals (autoStop / captureFailed /
/// thresholdElapsed / tapDisabled) — yields `.passThrough`. There is no state in
/// which any other key can be suppressed. Which physical events become primary
/// inputs is the tracker's job (the trigger key's own events, identified by
/// keycode and, for sided modifiers, device bit). This is the property the
/// randomized tests pin down; it is the point-for-point inversion of the Wispr
/// stale-key bug that swallowed spacebars.
enum EventDisposition: Sendable, Hashable {
    case consume         // return nil from the tap callback — event is deleted
    case passThrough     // return the event unchanged
}

/// The machine's decision for one input: an optional session action plus the
/// disposition of the triggering event.
struct HotkeyDecision: Sendable, Hashable {
    let action: DictationAction?
    let disposition: EventDisposition

    static let ignorePassThrough = HotkeyDecision(action: nil, disposition: .passThrough)
    static let ignoreConsume = HotkeyDecision(action: nil, disposition: .consume)
}

// MARK: - State

/// The machine's states. `pressed` and `holding` hold the press start time and
/// source so the tap-vs-hold threshold can be evaluated when the key is released.
enum HotkeyState: Sendable, Hashable {
    case idle
    case pressed(since: MonotonicTime, source: ActivationSource)
    case holding(since: MonotonicTime, source: ActivationSource)   // promoted by the threshold timer → push-to-talk
    case latched(source: ActivationSource)        // hands-free; next press commits
}

// MARK: - Machine

/// Pure hotkey state machine (PLAN.md Part III §6 + §8).
///
/// One adaptive behavior, not a mode setting: dictation starts the instant the
/// key goes down; a quick release (< threshold) latches into hands-free listening
/// and the next press commits, while a hold (≥ threshold) is push-to-talk and the
/// release commits. Escape discards. Auto-stop in a latched session is just
/// another commit input — there is exactly one commit path.
///
/// All logic lives in the static `reduce`; the struct is a thin stateful wrapper.
/// No system APIs, no clock reads, no I/O — every transition is a value→value
/// function, exhaustively testable with synthetic inputs and chosen timestamps.
struct HotkeyStateMachine {
    /// Tap-vs-hold boundary. Named, injectable parameter. Default 280 ms: the
    /// plan's ~200 ms proved too tight against real fingers (a relaxed human tap
    /// runs 150-250 ms and was misread as a hold, committing on release).
    let holdThreshold: Duration
    private(set) var state: HotkeyState

    init(holdThreshold: Duration, state: HotkeyState = .idle) {
        self.holdThreshold = holdThreshold
        self.state = state
    }

    /// Advance the machine and return its decision.
    mutating func handle(_ input: HotkeyInput) -> HotkeyDecision {
        let (next, decision) = Self.reduce(state: state, input: input, holdThreshold: holdThreshold)
        state = next
        return decision
    }

    /// The pure transition function. `(state, input) → (state, decision)`.
    static func reduce(
        state: HotkeyState,
        input: HotkeyInput,
        holdThreshold: Duration
    ) -> (HotkeyState, HotkeyDecision) {
        switch state {
        case .idle:
            return reduceIdle(input)
        case let .pressed(since, source):
            return reducePressed(since: since, source: source, input: input, holdThreshold: holdThreshold)
        case let .holding(since, source):
            return reduceHolding(since: since, source: source, input: input, holdThreshold: holdThreshold)
        case let .latched(source):
            return reduceLatched(source: source, input: input)
        }
    }

    // MARK: idle

    private static func reduceIdle(_ input: HotkeyInput) -> (HotkeyState, HotkeyDecision) {
        switch input {
        case let .primaryDown(at):
            // Start dictating immediately; consume the trigger so the system (the
            // globe/Dictation for Fn) or the focused app never sees it.
            return (.pressed(since: at, source: .primary),
                    HotkeyDecision(action: .startDictation, disposition: .consume))
        case let .secondaryDown(at):
            // Secondary modifiers are benign to other apps and may be part of real
            // shortcuts — start dictating but never suppress them.
            return (.pressed(since: at, source: .secondary),
                    HotkeyDecision(action: .startDictation, disposition: .passThrough))
        case .primaryUp, .primaryRepeat:
            // Stray trigger up or repeat (we may have eaten the down): still
            // consume to be safe.
            return (.idle, .ignoreConsume)
        case .secondaryUp:
            return (.idle, .ignorePassThrough)
        case .escape:
            // Not dictating: Escape is a normal key — never touch it.
            return (.idle, .ignorePassThrough)
        case .autoStop, .thresholdElapsed, .captureFailed:
            return (.idle, .ignorePassThrough)
        case .tapDisabled:
            // Already idle; the shell re-enables the tap. Nothing to discard.
            return (.idle, .ignorePassThrough)
        }
    }

    // MARK: pressed

    private static func reducePressed(
        since: MonotonicTime,
        source: ActivationSource,
        input: HotkeyInput,
        holdThreshold: Duration
    ) -> (HotkeyState, HotkeyDecision) {
        switch input {
        case let .primaryUp(at) where source == .primary:
            return release(since: since, at: at, source: .primary, holdThreshold: holdThreshold, consume: true)
        case let .secondaryUp(at) where source == .secondary:
            return release(since: since, at: at, source: .secondary, holdThreshold: holdThreshold, consume: false)

        case let .thresholdElapsed(at):
            // Promote to holding once the key has genuinely been down for the
            // threshold. Guard with the timestamp so a stale/early timer can't
            // mislabel a tap as a hold.
            if at.elapsed(since: since) >= holdThreshold {
                return (.holding(since: since, source: source), .ignorePassThrough)
            }
            return (.pressed(since: since, source: source), .ignorePassThrough)

        case .escape:
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))
        case .tapDisabled, .captureFailed:
            // Fail-open: discard the in-flight session and reset; shell re-enables.
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))

        // Cross-source and stray events: never get stuck, only ever suppress the trigger.
        case .primaryDown, .primaryUp, .primaryRepeat:
            return (.pressed(since: since, source: source), .ignoreConsume)
        case .secondaryDown, .secondaryUp:
            return (.pressed(since: since, source: source), .ignorePassThrough)
        case .autoStop:
            // Auto-stop applies to latched sessions only; ignore while a key is held.
            return (.pressed(since: since, source: source), .ignorePassThrough)
        }
    }

    /// Resolve a key release in `pressed` or `holding`: tap (< threshold) latches;
    /// hold (≥ threshold) commits. Authoritative duration check, independent of
    /// any `thresholdElapsed` delivery — a timer that fired late must not turn a
    /// quick tap into a commit.
    private static func release(
        since: MonotonicTime,
        at: MonotonicTime,
        source: ActivationSource,
        holdThreshold: Duration,
        consume: Bool
    ) -> (HotkeyState, HotkeyDecision) {
        let disposition: EventDisposition = consume ? .consume : .passThrough
        if at.elapsed(since: since) < holdThreshold {
            // Tap → latch into hands-free listening; keep dictating, no action yet.
            return (.latched(source: source), HotkeyDecision(action: nil, disposition: disposition))
        }
        // Hold → release commits.
        return (.idle, HotkeyDecision(action: .commit, disposition: disposition))
    }

    // MARK: holding (push-to-talk, key still down past threshold)

    private static func reduceHolding(
        since: MonotonicTime,
        source: ActivationSource,
        input: HotkeyInput,
        holdThreshold: Duration
    ) -> (HotkeyState, HotkeyDecision) {
        switch input {
        case let .primaryUp(at) where source == .primary:
            return release(since: since, at: at, source: .primary, holdThreshold: holdThreshold, consume: true)
        case let .secondaryUp(at) where source == .secondary:
            return release(since: since, at: at, source: .secondary, holdThreshold: holdThreshold, consume: false)

        case .escape:
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))
        case .tapDisabled, .captureFailed:
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))

        case .primaryDown, .primaryUp, .primaryRepeat:
            return (.holding(since: since, source: source), .ignoreConsume)
        case .secondaryDown, .secondaryUp:
            return (.holding(since: since, source: source), .ignorePassThrough)
        case .thresholdElapsed, .autoStop:
            return (.holding(since: since, source: source), .ignorePassThrough)
        }
    }

    // MARK: latched (hands-free; next press commits)

    private static func reduceLatched(
        source: ActivationSource,
        input: HotkeyInput
    ) -> (HotkeyState, HotkeyDecision) {
        switch input {
        case .primaryDown:
            // The "next press" commits. Either source may stop a latched session.
            return (.idle, HotkeyDecision(action: .commit, disposition: .consume))
        case .secondaryDown:
            return (.idle, HotkeyDecision(action: .commit, disposition: .passThrough))

        case .autoStop:
            // VAD silence routes through the one commit path, same as a key press.
            return (.idle, HotkeyDecision(action: .commit, disposition: .passThrough))

        case .escape:
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))
        case .tapDisabled, .captureFailed:
            return (.idle, HotkeyDecision(action: .cancel, disposition: .passThrough))

        // Strays (e.g. the up that paired the latching tap arrives late, or the
        // held key repeating after a commit press): consume the trigger's events,
        // pass the rest, stay latched.
        case .primaryUp, .primaryRepeat:
            return (.latched(source: source), .ignoreConsume)
        case .secondaryUp:
            return (.latched(source: source), .ignorePassThrough)
        case .thresholdElapsed:
            return (.latched(source: source), .ignorePassThrough)
        }
    }
}
