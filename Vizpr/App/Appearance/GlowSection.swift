import SwiftUI

/// A glow around the pane's outline.
struct GlowSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let enabled = editor.look.style.outerGlow.enabled
        Section("Glow") {
            Toggle("Glow", isOn: editor.binding(\.style.outerGlow.enabled))
            Group {
                ColorPicker("Color", selection: editor.color(\.style.outerGlow.colorHex), supportsOpacity: false)
                LookSlider("Radius", editor.binding(\.style.outerGlow.radius),
                           range: LookRanges.glowRadius, format: .points())
                LookSlider("Strength", editor.binding(\.style.outerGlow.strength),
                           range: LookRanges.unit, format: .percent)
            }
            .disabled(!enabled)
        }
        .disabled(!editor.isEditable)
    }
}
