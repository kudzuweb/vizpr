import SwiftUI

struct BorderSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let enabled = editor.look.style.border.enabled
        Section("Border") {
            Toggle("Border", isOn: editor.binding(\.style.border.enabled))
            Group {
                LookSlider("Width", editor.binding(\.style.border.width),
                           range: LookRanges.borderWidth, format: .points(decimals: 1))
                ColorPicker("Color", selection: editor.color(\.style.border.colorHex), supportsOpacity: false)
                LookSlider("Opacity", editor.binding(\.style.border.opacity),
                           range: LookRanges.unit, format: .percent)
            }
            .disabled(!enabled)
        }
        .disabled(!editor.isEditable)
    }
}
