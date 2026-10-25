import SwiftUI

/// A neutral dimming layer behind the pane, so busy content behind it does not
/// fight the text, without changing how the glass looks.
struct BackdropSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let enabled = editor.look.style.backdrop.enabled
        Section("Backdrop") {
            Toggle("Backdrop", isOn: editor.binding(\.style.backdrop.enabled))
            Group {
                ColorPicker("Color", selection: editor.color(\.style.backdrop.colorHex), supportsOpacity: false)
                LookSlider("Strength", editor.binding(\.style.backdrop.strength),
                           range: LookRanges.backdropStrength, format: .percent)
                LookSlider("Feather", editor.binding(\.style.backdrop.feather),
                           range: LookRanges.backdropFeather, format: .points())
            }
            .disabled(!enabled)
        }
        .disabled(!editor.isEditable)
    }
}
