import AppKit

/// What the app does so a tap macOS refuses, or an app that has lost its own
/// files, cannot hold the keyboard (2026-10-27). The rules live in
/// `TapDisablePolicy`, `BundleIdentity` and `BundleWatcher`; this is the wiring.
extension AppDelegate {
    private static let hotkeyGaveUpSummary =
        "Vizpr stopped listening for the hotkey because macOS kept refusing it."

    /// Checks the bundle at launch and, if it is intact, starts the watcher that
    /// quits the app when the bundle disappears later. False means the launch
    /// check failed and the app must not continue starting.
    func verifyBundleAndWatch() -> Bool {
        if let failure = BundleIdentity.firstFailure(.system) {
            failLoudly(
                "Vizpr's app files are missing or damaged.",
                detail: "\(failure.detail) Rebuild or reinstall Vizpr."
            )
            return false
        }
        guard let executableURL = Bundle.main.executableURL,
              let launchFileID = BundleIdentity.processFileID() else { return true }
        let watcher = BundleWatcher(
            executableURL: executableURL,
            launchFileID: launchFileID,
            terminatesProcess: !Self.isHostedByTests,
            tearDownTap: { [hotkeyMonitor] done in hotkeyMonitor.tearDownForExit(completion: done) },
            presentLoss: { [weak self] in
                Task { @MainActor in
                    self?.failLoudly(
                        "Vizpr's app files were removed or replaced while it was running, so it is quitting.",
                        detail: "Reopen Vizpr from its current location."
                    )
                }
            }
        )
        bundleWatcher = watcher
        watcher.start()
        return true
    }

    /// The monitor stopped re-arming a refused tap and tore it down; the keyboard
    /// is already free, so a modal here is safe.
    func hotkeyGaveUp() {
        refreshMenu()
        presentAlert(
            Self.hotkeyGaveUpSummary,
            detail: "Use Restart Hotkey in the menu, or quit and reopen Vizpr."
        )
    }

    /// The gave-up notice and the only way back from it short of relaunch.
    func addGaveUpItems(to menu: NSMenu) {
        let notice = NSMenuItem(title: Self.hotkeyGaveUpSummary, action: nil, keyEquivalent: "")
        notice.isEnabled = false
        menu.addItem(notice)
        menu.addItem(cycleItem("Restart Hotkey", #selector(restartHotkey)))
        menu.addItem(.separator())
    }

    /// An explicit user action: the one thing that clears the give-up latch.
    @objc private func restartHotkey() {
        hotkeyMonitor.resetGiveUp()
        if settingsStore.settings.hotkeyEnabled { hotkeyMonitor.start() }
        refreshMenu()
    }
}
