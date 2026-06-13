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

        #if DICT_DEV_LOG
        // Present only in Debug; proves the compile gate (verified absent from
        // Release by scripts/check-devlog-absent.sh).
        VizprTranscriptLogger.announce()
        #endif
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Template image: AppKit tints it automatically for light/dark menu bars.
        let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Vizpr")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        let header = NSMenuItem(title: "Vizpr", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Vizpr",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu

        statusItem = item
    }
}
