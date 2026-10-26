/// The shell's per-event decision as a pure function: the tracker turns one
/// keyboard event into edges, the machine decides what each edge does, and the
/// event is deleted when any of those decisions consumed it.
///
/// The fail-open property is a property of this composition. The tracker's
/// "taken" bookkeeping assumes the machine consumes every primary input, and the
/// shell deletes a whole packet when any edge in it was consumed; keeping the
/// three together in one function is what lets the composed property tests
/// (`HotkeyEventRouterTests`) pin it.
enum HotkeyEventRouter {
    struct Outcome: Equatable {
        /// The edges the event produced, in the order the machine saw them.
        let edges: [FlagEdgeTracker.Edge]
        /// The machine's decision for each edge, for the shell to act on.
        let decisions: [HotkeyDecision]
        /// Whether the event is deleted rather than forwarded.
        var suppress: Bool { decisions.contains { $0.disposition == .consume } }
    }

    /// - Parameter now: the event's own time (see `EventTimestamp`), so a
    ///   late-serviced callback cannot turn a quick tap into a hold.
    static func route(
        _ event: HotkeyKeyEvent,
        at now: MonotonicTime,
        tracker: inout FlagEdgeTracker,
        machine: inout HotkeyStateMachine
    ) -> Outcome {
        // One packet can toggle both the trigger and the secondary combo, so
        // every edge is processed; never early-return after the first.
        let edges = tracker.edges(for: event)
        let decisions = edges.map { machine.handle(input(for: $0, at: now)) }
        return Outcome(edges: edges, decisions: decisions)
    }

    private static func input(for edge: FlagEdgeTracker.Edge, at now: MonotonicTime) -> HotkeyInput {
        switch edge {
        case .primaryDown: return .primaryDown(at: now)
        case .primaryUp: return .primaryUp(at: now)
        case .primaryRepeat: return .primaryRepeat
        case .secondaryDown: return .secondaryDown(at: now)
        case .secondaryUp: return .secondaryUp(at: now)
        }
    }
}
