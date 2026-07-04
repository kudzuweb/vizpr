import Foundation

/// The flush-settle window (NOTES: §15 amendment, adopted 2026-07-04).
/// Commit no longer snapshots at the instant of release: it waits for the
/// session to DRAIN — every ASR event including the commit-time flush
/// delivered to the display — or a hard cap, whichever first. WYSIWYG is
/// preserved as displayed==injected, with "at stop" now "at stop + settle".
///
/// This is a data-loss fix (quick tap-speak-release under ~2 s used to
/// commit an empty display and the speech vanished; field-verified fixed).
/// Cleanup remains STRICT-CANCEL — the settle applies only to the bounded
/// ASR flush.
///
/// Session identity: drains are epoch-tagged. A late drain from a cancelled
/// or capped session must not satisfy the NEXT session's settle (review
/// finding: an unkeyed drain silently reopened the quick-tap hole), and a
/// cancelled timeout must not release a later waiter.
@MainActor
final class SettleGate {
    private(set) var epoch = 0
    private var drained = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Arm for a new session; returns its epoch for the pipeline to echo.
    @discardableResult
    func beginSession() -> Int {
        epoch += 1
        drained = false
        resume()   // release any stale waiter defensively
        return epoch
    }

    /// A session's event stream fully drained. Stale epochs are ignored.
    func noteDrained(epoch drainedEpoch: Int) {
        guard drainedEpoch == epoch else { return }
        drained = true
        resume()
    }

    /// Wait until the current session drains, bounded by `cap`.
    func awaitDrain(cap: Duration) async {
        if drained { return }
        let waitEpoch = epoch
        let timeout = Task { @MainActor [weak self] in
            // A cancelled timeout must NOT fall through to resume (review
            // finding: try? swallowed the cancellation and the stale timeout
            // collapsed the next session's settle window to zero).
            guard (try? await Task.sleep(for: cap)) != nil else { return }
            guard let self, self.epoch == waitEpoch else { return }
            self.resume()
        }
        // Single-waiter invariant: the serialized action loop is the only
        // caller. Release any (impossible today) prior waiter before parking
        // rather than leaking it.
        resume()
        await withCheckedContinuation { continuation = $0 }
        timeout.cancel()
    }

    /// App terminating: release any parked waiter so shutdown can proceed.
    func releaseAll() {
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }
}
