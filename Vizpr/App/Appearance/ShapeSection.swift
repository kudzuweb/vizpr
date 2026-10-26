import SwiftUI

/// Pane width and the padding around the text.
struct ShapeSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        Section("Shape") {
            LookSlider("Pane width", editor.binding(\.style.pane.width),
                       range: LookRanges.paneWidth, format: .points())
            LookSlider("Horizontal padding", editor.binding(\.style.pane.paddingHorizontal),
                       range: LookRanges.panePadding, format: .points())
            LookSlider("Vertical padding", editor.binding(\.style.pane.paddingVertical),
                       range: LookRanges.panePadding, format: .points())
        }
        .disabled(!editor.isEditable)
    }
}
