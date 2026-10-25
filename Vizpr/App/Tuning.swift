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
    /// Tails shorter than 1.5 s decode to junk (set 2026-10-25).
    static let draftMinTailMs = 1500
}
