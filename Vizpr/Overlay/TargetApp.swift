import AppKit
import Observation

/// What the overlay shows of the app that will receive the text.
enum TargetAppDisplay: String, Codable, CaseIterable, Sendable {
    case off, icon, iconAndName
}

/// The frontmost app, tracked live while the overlay is up: focus moving to
/// another app mid-dictation changes where the commit injects, so the
/// indicator follows. Vizpr itself (its Settings window) never replaces the
/// last other app, because Vizpr is never an injection target.
@MainActor
@Observable
final class TargetApp {
    struct Info {
        let processID: pid_t
        let name: String
        let icon: NSImage?

        init(processID: pid_t, name: String, icon: NSImage?) {
            self.processID = processID
            self.name = name
            self.icon = icon
        }

        init?(_ app: NSRunningApplication) {
            guard let name = app.localizedName else { return nil }
            self.init(processID: app.processIdentifier, name: name, icon: app.icon)
        }
    }

    private(set) var current: Info?
    private var observer: (any NSObjectProtocol)?
    private let ownProcessID: pid_t

    init(ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessID = ownProcessID
    }

    /// Begins observing activations, and adopts the app in front right now.
    func start() {
        stop()
        if let front = NSWorkspace.shared.frontmostApplication { adopt(Info(front)) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Only the process id crosses into the main-actor closure: the
            // notification and NSRunningApplication are not Sendable.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processID = app?.processIdentifier
            MainActor.assumeIsolated {
                let running = processID.flatMap { NSRunningApplication(processIdentifier: $0) }
                self?.adopt(running.flatMap(Info.init))
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// Takes `info` as the target unless it is Vizpr itself or unknown.
    func adopt(_ info: Info?) {
        guard let info, info.processID != ownProcessID else { return }
        current = info
    }
}
