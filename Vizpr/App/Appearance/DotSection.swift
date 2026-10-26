import SwiftUI

/// The recording indicator.
struct DotSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let usesTint = editor.look.style.dot.colorHex == nil
        Section("Recording dot") {
            Toggle("Use tint", isOn: editor.isNil(\.style.dot.colorHex, fallback: "FF3B30"))
            if !usesTint {
                ColorPicker("Color", selection: editor.optionalColor(\.style.dot.colorHex, placeholder: "FF3B30"),
                            supportsOpacity: false)
            }
            LookSlider("Size", editor.binding(\.style.dot.size),
                       range: LookRanges.dotSize, format: .points())
            Toggle("Pulse", isOn: editor.binding(\.style.dot.pulse))
        }
        .disabled(!editor.isEditable)
    }
}
