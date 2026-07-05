import AppKit
import ApplicationServices

/// What the reader could learn about the focused field at session start.
struct FieldContext: Sendable, Equatable {
    /// Text surrounding the caret in the focused element, bounded — nil
    /// wherever AX is unsupported (Electron/web/terminal frequently).
    var surroundingText: String?
    /// Frontmost app's bundle identifier.
    var bundleID: String?
    /// Frame of the focused window (screen coordinates, AX top-left origin) —
    /// lets the overlay pick the display actually holding the dictation
    /// target (§13 multi-display, deferred from PR 9).
    var focusedWindowFrame: CGRect?

    static let empty = FieldContext(
        surroundingText: nil, bundleID: nil, focusedWindowFrame: nil
    )
}

/// AX read of the focused element (PLAN.md PR 10). READ-ONLY — no AX writes
/// exist anywhere in the codebase; Accessibility is for reading context and
/// the injector writes only via pasteboard+events (§12). Every step fails
/// soft to nil: a context-less session is fully functional, just less
/// informed (acceptance: nil-context leaves cleanup working).
///
/// Context never leaves the process except into the dev logger.
@MainActor
struct FieldContextReader {
    /// Bound on the surrounding-text read (§10's prompt slot doesn't want
    /// documents, it wants vicinity).
    static let maxLength = 500

    func read() -> FieldContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .empty }
        var context = FieldContext.empty
        context.bundleID = app.bundleIdentifier

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success, let window = focusedWindow {
            if let windowElement = Self.axElement(window) {
                context.focusedWindowFrame = Self.frame(of: windowElement)
            }
        }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return context }

        var value: CFTypeRef?
        if let focusedElement = Self.axElement(element),
           AXUIElementCopyAttributeValue(
               focusedElement, kAXValueAttribute as CFString, &value
           ) == .success, let text = value as? String, !text.isEmpty {
            context.surroundingText = Self.bounded(text, limit: Self.maxLength)
        }
        return context
    }

    /// Tail-biased bound: the caret is usually at the end of what the user is
    /// writing, so the RECENT text is the relevant vicinity. Cuts on a
    /// character boundary (never splits a grapheme). nonisolated: pure.
    nonisolated static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                  window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionRaw = positionRef, let sizeRaw = sizeRef,
              let positionValue = axValue(positionRaw),
              let sizeValue = axValue(sizeRaw),
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// CF downcasts: type-checked before the cast (CF types have no
    /// conditional-cast support, so the force cast is gated on CFGetTypeID).
    private static func axElement(_ ref: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXUIElement)
    }

    private static func axValue(_ ref: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXValue)
    }
}
