import Foundation

/// The flush-settle window (NOTES: §15 amendment, adopted 2026-07-04).
/// Commit no longer snapshots at the instant of release: it waits for the
/// session to DRAIN — every ASR event including the commit-time flush
/// delivered to the display — or a hard cap, whichever first. The overlay
/// shows the flush landing in the mutable color, then the snapshot is taken:
/// WYSIWYG is preserved as displayed==injected, with "at stop" now "at stop +
/// settle".
///
/// This is a data-loss fix, not just accuracy polish: without it, a quick
/// tap-speak-release under ~2 s commits before the first draft decodes and
/// the speech vanishes (field-observed). Measured drain latency after release
/// is 140–250 ms; the cap exists so a hung engine can never hold the commit
/// hostage.
///
/// Cleanup remains STRICT-CANCEL — the settle applies only to the bounded ASR
/// flush; the §15 rejection of a cleanup grace period is untouched.
@MainActor
final class SettleGate {
    private var drained = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Arm for a new session (drain state is per-session).
    func beginSession() {
        drained = false
        resume()   // release any stale waiter defensively
    }

    /// The session's event stream fully drained (AudioPipeline hook).
    func noteDrained() {
        drained = true
        resume()
    }

    /// Wait until the session drains, bounded by `cap`. Returns immediately
    /// if the drain already happened.
    func awaitDrain(cap: Duration) async {
        if drained { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: cap)
            self?.resume()
        }
        await withCheckedContinuation { continuation = $0 }
        timeout.cancel()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }
}
