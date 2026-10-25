import SwiftUI

struct ShadowSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let enabled = editor.look.style.dropShadow.enabled
        Section("Shadow") {
            Toggle("Drop shadow", isOn: editor.binding(\.style.dropShadow.enabled))
            Group {
                ColorPicker("Color", selection: editor.color(\.style.dropShadow.colorHex), supportsOpacity: false)
                LookSlider("Radius", editor.binding(\.style.dropShadow.radius),
                           range: LookRanges.shadowRadius, format: .points())
                LookSlider("Offset x", editor.binding(\.style.dropShadow.x),
                           range: LookRanges.shadowOffset, format: .points())
                LookSlider("Offset y", editor.binding(\.style.dropShadow.y),
                           range: LookRanges.shadowOffset, format: .points())
                LookSlider("Opacity", editor.binding(\.style.dropShadow.opacity),
                           range: LookRanges.unit, format: .percent)
            }
            .disabled(!enabled)
        }
        .disabled(!editor.isEditable)
    }
}
