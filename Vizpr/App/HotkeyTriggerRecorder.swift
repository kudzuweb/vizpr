import AppKit

/// Records a new dictation trigger from the keyboard while the Behavior pane's
/// button is armed.
///
/// While recording, the hotkey monitor is suspended (it passes every event
/// through, so the key being recorded is not consumed as the old trigger) and a
/// local `NSEvent` monitor reads `keyDown` and `flagsChanged`. Recording ends on
/// a capture, on Esc, when the window closes or resigns key, and when the app
/// resigns active, so the monitor is never left suspended.
///
/// A capture is refused, with a one-line reason in `message`, whenever the
/// trigger would not work or would consume more than the user pressed: Fn held
/// with another key, Esc in any combination, Caps Lock, a keycode outside the
/// range `clamped()` accepts, or a combination that holds the whole secondary
/// chord. A key a laptop reaches only through Fn (F1 to F20, Home, End, Page Up,
/// Page Down, Forward Delete) is accepted while Fn is down and is stored without
/// Fn. The recorder never writes a value `clamped()` would change.
@MainActor
final class HotkeyTriggerRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Why the last capture was refused, shown in place of the pane's caption.
    @Published private(set) var message: String?

    private let store: SettingsStore
    private let setSuspended: (Bool) -> Void
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    // What has been pressed since all modifiers were last released.
    /// Tracked by keycode 63 from `flagsChanged`: the function flag alone is also
    /// set by arrow and function keys.
    private var fnHeld = false
    private var fnUsed = false
    private var otherModifierPressed = false
    private var lastModifier: (keyCode: UInt16, others: [String])?

    /// Carries an `NSEvent` out of the main-actor closure that `NSEvent` monitors need.
    private struct UncheckedEvent: @unchecked Sendable {
        let event: NSEvent?
        init(_ event: NSEvent?) { self.event = event }
    }

    init(store: SettingsStore, setSuspended: @escaping (Bool) -> Void) {
        self.store = store
        self.setSuspended = setSuspended
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        message = nil
        clearPressed()
        fnHeld = false
        setSuspended(true)
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // AppKit calls local monitors on the main thread; NSEvent is not Sendable.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { UncheckedEvent(self?.handle(event) ?? event) }.event
        }
        let center = NotificationCenter.default
        let endings: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, nil),
            (NSWindow.willCloseNotification, nil),
            (NSApplication.didResignActiveNotification, nil)
        ]
        observers = endings.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        eventMonitor.map(NSEvent.removeMonitor)
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isRecording = false
        message = nil
        setSuspended(false)
    }

    // MARK: Events

    /// Returns nil for every event the recorder consumes, so a captured ⌘W or ⌘Q
    /// does not act on the Settings window.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            if !event.isARepeat { captureKeyDown(event) }
            return nil
        case .flagsChanged:
            trackModifier(event)
            return event
        default:
            return event
        }
    }

    private func captureKeyDown(_ event: NSEvent) {
        let families = Self.heldFamilies(event.modifierFlags)
        if event.keyCode == HotkeyTrigger.escapeKeyCode, families.isEmpty, !fnHeld {
            message = nil
            stop()
            return
        }
        clearPressed()
        guard !fnHeld || HotkeyTrigger.fnReachedKeyCodes.contains(event.keyCode) else {
            message = HotkeyTrigger.fnAloneReason
            return
        }
        commit(HotkeyTrigger(keyCode: event.keyCode, modifiers: families))
    }

    private func trackModifier(_ event: NSEvent) {
        let flags = event.modifierFlags
        let code = event.keyCode

        if code == HotkeyTrigger.capsLockKeyCode {
            message = HotkeyTrigger(keyCode: code, modifiers: []).refusal(secondaryModifiers: [])
            return
        }
        if code == HotkeyTrigger.fnKeyCode {
            fnHeld = flags.contains(.function)
            if fnHeld { fnUsed = true }
        } else if let key = HotkeyTrigger.modifierKeys[code] {
            let down = UInt64(flags.rawValue) & key.deviceBit != 0
            if down {
                otherModifierPressed = true
                let others = Self.heldFamilies(flags).filter { $0 != key.family }
                lastModifier = (code, others)
            } else if Self.heldFamilies(flags).contains(key.family), !Self.hasDeviceBits(flags) {
                message = "This keyboard doesn't say which side a modifier is on, so a side-specific modifier can't be the trigger."
                clearPressed()
                return
            }
        }

        // Every modifier released with no key pressed between: a modifier-only trigger.
        guard Self.heldFamilies(flags).isEmpty, !fnHeld else { return }
        defer { clearPressed() }
        if fnUsed {
            if otherModifierPressed {
                message = HotkeyTrigger.fnAloneReason
            } else {
                commit(.fn)
            }
        } else if let last = lastModifier {
            commit(HotkeyTrigger(keyCode: last.keyCode, modifiers: last.others))
        }
    }

    private func commit(_ captured: HotkeyTrigger) {
        let trigger = captured.normalized()
        if let reason = trigger.refusal(secondaryModifiers: store.settings.secondaryModifiers) {
            message = reason
            return
        }
        message = nil
        store.update { $0.trigger = trigger }
        stop()
    }

    private func clearPressed() {
        fnUsed = false
        otherModifierPressed = false
        lastModifier = nil
    }

    private static func heldFamilies(_ flags: NSEvent.ModifierFlags) -> [String] {
        HotkeyTrigger.orderedFamilyFlags.filter { flags.contains($0.flag) }.map(\.name)
    }

    private static func hasDeviceBits(_ flags: NSEvent.ModifierFlags) -> Bool {
        UInt64(flags.rawValue) & HotkeyTrigger.allDeviceBits != 0
    }
}
