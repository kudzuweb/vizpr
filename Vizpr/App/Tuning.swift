/// Development levers: values tuned by measurement, not choices a user makes.
/// Change one here and every consumer follows. User choices live in
/// `VizprSettings`.
enum Tuning {
    /// Longest the commit waits for the tail's last decode, milliseconds.
    /// A cap below the decode time commits the last draft and drops the decode.
    /// Rule: 2 x p90(15 s tail decode) + 100 ms, rounded up to 50 ms. The 2
    /// covers a draft decode still running when the input ends plus the commit
    /// decode queued behind it. Measured 2026-10-25 on the bundled model: p90
    /// of 180.6 ms over 10 runs gives 500.
    static let settleCapMs = 500

    /// Audio the draft track needs before its first decode, milliseconds.
    /// Tails shorter than 1.5 s decode to junk (field-observed; a constant since 2026-10-25).
    static let draftMinTailMs = 1500

    /// Timeout disables the hotkey tap tolerates inside `tapDisableWindowSeconds`
    /// before it stops re-arming. Evidence (debug.log, 2026-07-03 to 2026-10-27):
    /// normal use shows at most one disable per launch window (six watchdog
    /// finds on 2026-10-21 and 2026-10-24, each 3 to 20 s after a launch), and
    /// the 2026-10-27 incident paced three timeouts in 7.5 s (02:55:47.09,
    /// :50.56, :54.64). A limit of 3 leaves a margin of two over anything
    /// observed in normal use and gives up 11 s into the incident.
    static let tapDisableLimit = 3

    /// The sliding window those disables are counted in, seconds. See
    /// `tapDisableLimit` for the measurements.
    static let tapDisableWindowSeconds = 30
}
