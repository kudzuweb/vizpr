import AppKit

/// Application entry point and menu-bar lifecycle owner.
///
/// Vizpr is an `LSUIElement` agent: no Dock icon, no main window, a single
/// `NSStatusItem` in the menu bar. This PR establishes only the skeleton; the
/// hotkey monitor, pipeline, and real menu land in later PRs.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyMonitor = HotkeyMonitor()
    private let permissionProbe = PermissionProbe()
    private var actionsTask: Task<Void, Never>?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // `delegate` is weakly held by NSApplication; the strong reference here
        // lives for the whole process because app.run() blocks until quit.
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already implies accessory; set it explicitly so the policy
        // is unambiguous regardless of how the process was launched.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        consumeHotkeyActions()
        startHotkeyIfPermitted()

        #if DICT_DEV_LOG
        // Present only in Debug; proves the compile gate (verified absent from
        // Release by scripts/check-devlog-absent.sh).
        VizprTranscriptLogger.announce()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        actionsTask?.cancel()
        hotkeyMonitor.stop()
    }

    // MARK: Hotkey wiring

    /// Start the tap if capability allows; otherwise leave it idle and let the
    /// menu surface the grant action. We never prompt on launch — the user opts
    /// in from the menu, so an unprompted Accessibility sheet never appears.
    private func startHotkeyIfPermitted() {
        if permissionProbe.evaluate() == .ready {
            hotkeyMonitor.start()
        }
        refreshMenu()
    }

    /// Drain dictation actions. There is no pipeline yet (PRs 3–9); for now this
    /// keeps the stream live and records intent in the dev logger.
    private func consumeHotkeyActions() {
        // Explicit MainActor isolation: the stream payload is the only thing this
        // task touches, and keeping it on main avoids ever reading monitor state
        // off-thread through the @unchecked Sendable escape hatch.
        actionsTask = Task { @MainActor [hotkeyMonitor] in
            for await action in hotkeyMonitor.actions {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("hotkey action: \(action)")
                #endif
                _ = action
            }
        }
    }

    @objc private func grantAccessibility() {
        let capability = permissionProbe.evaluate()
        switch capability {
        case .needsAccessibility:
            permissionProbe.requestAccessibility()
        case .needsInputMonitoring:
            permissionProbe.requestInputMonitoring()
            permissionProbe.openSettings(for: capability)
        case .grantedButDead:
            // Permission is present but the tap won't deliver until relaunch.
            permissionProbe.openSettings(for: capability)
        case .ready:
            hotkeyMonitor.start()
        }
        refreshMenu()
    }

    // MARK: Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Template image: AppKit tints it automatically for light/dark menu bars.
        let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Vizpr")
        image?.isTemplate = true
        item.button?.image = image

        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Vizpr", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let capability = permissionProbe.evaluate()
        if capability != .ready || !hotkeyMonitor.isTapHealthy {
            let title: String
            switch capability {
            case .grantedButDead: title = "Permission granted — relaunch to enable"
            case .needsInputMonitoring: title = "Enable Input Monitoring…"
            default: title = "Grant Accessibility…"
            }
            let grant = NSMenuItem(title: title, action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        menu.addItem(
            NSMenuItem(
                title: "Quit Vizpr",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem?.menu = menu
    }
}
