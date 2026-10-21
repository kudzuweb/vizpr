import AppKit
import SwiftUI

/// The overlay's content view. The pane is draggable anywhere on it: every
/// click inside the view lands here (not on SwiftUI internals such as the
/// transcript's scroll view, which could swallow it) and starts a window drag.
final class DragHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        (window as? PreviewPanel)?.drag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
