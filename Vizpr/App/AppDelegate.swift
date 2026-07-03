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
    private var audioPipeline: AudioPipeline?

    /// NSApplication holds its delegate weakly, and a local would be releasable
    /// by the optimizer after its last use even though app.run() never returns —
    /// deallocating the delegate (and the hotkey tap with it) mid-flight in
    /// Release builds. A static keeps ownership unambiguous.
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already implies accessory; set it explicitly so the policy
        // is unambiguous regardless of how the process was launched.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpAudioPipeline()
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
        audioPipeline?.stop()
        hotkeyMonitor.stop()
    }

    /// Build the capture→VAD→auto-stop pipeline against the bundled VAD model.
    /// A load failure means a broken bundle: fail loudly (invariant — never limp
    /// along without the model).
    private func setUpAudioPipeline() {
        audioPipeline = AudioPipeline.makeDefault { [hotkeyMonitor] in
            hotkeyMonitor.injectAutoStop()
        }
        if audioPipeline == nil {
            let alert = NSAlert()
            alert.messageText = "Vizpr's bundled voice-detection model failed to load."
            alert.informativeText = "The app bundle is damaged — rebuild or reinstall Vizpr."
            alert.runModal()
            NSApp.terminate(nil)
        }
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
        actionsTask = Task { @MainActor [hotkeyMonitor, weak self] in
            for await action in hotkeyMonitor.actions {
                #if DICT_DEV_LOG
                VizprTranscriptLogger.note("hotkey action: \(action)")
                #endif
                switch action {
                case .startDictation:
                    self?.audioPipeline?.start()
                case .commit, .cancel:
                    // Text handling arrives with TokenStream (PR 5) and the
                    // injector (PR 8); for now both just end audio capture.
                    self?.audioPipeline?.stop()
                }
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
