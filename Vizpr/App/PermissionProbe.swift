import AppKit
import ApplicationServices

/// The capability the hotkey tap currently has.
///
/// We probe capability instead of encoding OS versions, because the TCC
/// requirements for a consuming event tap have shifted across macOS releases and
/// some Sequoia setups need Input Monitoring in addition to Accessibility
/// (PLAN.md §9). A non-nil tap is not proof of health — `grantedButDead` captures
/// the case where permission appears present but no events flow, which a relaunch
/// usually fixes.
enum HotkeyCapability: Equatable, Sendable {
    case ready                  // tap can be created and is live
    case needsAccessibility     // Accessibility not granted — request it
    case needsInputMonitoring   // AX granted but a consuming tap still fails — try Input Monitoring
    case grantedButDead         // permission present, tap won't deliver — prompt a relaunch
}

/// Capability probe + permission requests for the consuming Fn tap (PLAN.md §9).
///
/// All system calls are isolated here; the probe owns no long-lived state. The
/// runtime liveness watchdog lives in `HotkeyMonitor`; this type covers the
/// onboarding/grant flow and the one-shot capability evaluation.
@MainActor
struct PermissionProbe {

    /// Evaluate current capability without prompting.
    ///
    /// Deviation from §9 noted honestly: the spec asks to confirm health by
    /// observing a *test event*, because "a non-nil tap is not a healthy tap."
    /// Injecting a synthetic event requires a run-loop-attached probe plus event-
    /// post access and risks side effects, so this uses the strongest *synchronous*
    /// signals instead — the probe tap creates (permission allows a consuming tap)
    /// and reports enabled. The remaining silent-disable race (enabled but
    /// delivering nothing) is caught at runtime by the monitor's `tapIsEnabled`
    /// watchdog. Crucially we do NOT infer `grantedButDead` from a live tap simply
    /// not having seen an event yet — a freshly-granted, idle tap is healthy.
    func evaluate() -> HotkeyCapability {
        let trusted = AXIsProcessTrusted()   // cached per process; see relaunch note below

        guard let probe = makeProbeTap() else {
            // Cannot create a consuming tap. Without trust → request Accessibility.
            // Trusted-but-cannot-create is either the Input-Monitoring-also-required
            // case or a grant that hasn't taken effect until relaunch.
            if !trusted { return .needsAccessibility }
            return CGPreflightListenEventAccess() ? .grantedButDead : .needsInputMonitoring
        }
        let enabled = CGEvent.tapIsEnabled(tap: probe)
        teardown(probe)

        if !trusted { return .needsAccessibility }
        return enabled ? .ready : .grantedButDead
    }

    /// Prompt for Accessibility. Shows the System Settings sheet if not yet
    /// trusted. The grant typically does not take effect until relaunch.
    @discardableResult
    func requestAccessibility() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable global under Swift 6
        // strict concurrency; its documented value is this constant string.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Request Input Monitoring (the listen-event TCC service) as the fallback for
    /// setups where Accessibility alone does not enable a consuming tap.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    /// Open the relevant Privacy & Security pane so the user can grant access.
    func openSettings(for capability: HotkeyCapability) {
        let anchor: String
        switch capability {
        case .needsInputMonitoring:
            anchor = "Privacy_ListenEvent"
        default:
            anchor = "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Probe tap

    /// Create a throwaway consuming tap to test whether we *can*. It is never
    /// added to a run loop, so it observes nothing — non-nil means "permission
    /// allows creating a consuming tap," which is the strongest synchronous
    /// signal available. True liveness is confirmed by the monitor having
    /// observed real events.
    private func makeProbeTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
    }

    private func teardown(_ port: CFMachPort) {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }
}
