import Testing
@testable import Vizpr

@Suite("TapDisablePolicy")
struct TapDisablePolicyTests {

    private func at(_ seconds: Double) -> MonotonicTime {
        MonotonicTime(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func policy() -> TapDisablePolicy {
        TapDisablePolicy(limit: 3, window: .seconds(30))
    }

    @Test("Disables under the limit are re-armed, and report their running count")
    func underTheLimit() {
        var policy = policy()
        #expect(policy.recordDisable(at: at(0)) == .reArm(count: 1))
        #expect(policy.recordDisable(at: at(5)) == .reArm(count: 2))
        #expect(policy.mayArm)
    }

    @Test("The disable that reaches the limit gives up and closes the latch")
    func atTheLimit() {
        var policy = policy()
        _ = policy.recordDisable(at: at(0))
        _ = policy.recordDisable(at: at(3))
        #expect(policy.recordDisable(at: at(7)) == .giveUp(count: 3))
        #expect(!policy.mayArm)
    }

    @Test("Disables past the limit keep reporting a give-up")
    func overTheLimit() {
        var policy = policy()
        for second in [0.0, 1, 2] { _ = policy.recordDisable(at: at(second)) }
        #expect(policy.recordDisable(at: at(3)) == .giveUp(count: 4))
    }

    @Test("Disables that slide out of the window no longer count")
    func windowSlides() {
        var policy = policy()
        _ = policy.recordDisable(at: at(0))
        _ = policy.recordDisable(at: at(10))
        // The first two are 31 s and 21 s old: only the first has left the window.
        #expect(policy.recordDisable(at: at(31)) == .reArm(count: 2))
        #expect(policy.mayArm)
    }

    @Test("A disable exactly one window old still counts")
    func windowEdgeIsInclusive() {
        var policy = policy()
        _ = policy.recordDisable(at: at(0))
        _ = policy.recordDisable(at: at(15))
        #expect(policy.recordDisable(at: at(30)) == .giveUp(count: 3))
    }

    @Test("Spread-out disables, as in normal use, never give up")
    func spreadOutDisablesNeverGiveUp() {
        var policy = policy()
        #expect(policy.recordDisable(at: at(0)) == .reArm(count: 1))
        for index in 1..<20 {
            // 20 s apart: the one before is inside the 30 s window, the one before that is not.
            #expect(policy.recordDisable(at: at(Double(index) * 20)) == .reArm(count: 2))
        }
        #expect(policy.mayArm)
    }

    @Test("After a give-up the latch holds until reset, and reset forgets old disables")
    func latchHoldsUntilReset() {
        var policy = policy()
        for second in [0.0, 1, 2] { _ = policy.recordDisable(at: at(second)) }
        #expect(!policy.mayArm)

        policy.reset()
        #expect(policy.mayArm)
        #expect(policy.recordDisable(at: at(3)) == .reArm(count: 1))
    }
}
