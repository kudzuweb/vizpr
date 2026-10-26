import SwiftUI

/// The light drawn over the surface: matte to shiny, edge light, bevel, a
/// moving sheen and grain.
struct FinishSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        Section("Finish") {
            LookSlider("Matte ↔ Shiny", editor.binding(\.style.light.gloss),
                       range: LookRanges.unit, format: .percent)
            LookSlider("Edge light", editor.binding(\.style.light.edgeLight),
                       range: LookRanges.unit, format: .percent)
            LookSlider("Bevel", editor.binding(\.style.light.bevel),
                       range: LookRanges.unit, format: .percent)
            LookSlider("Sheen", editor.binding(\.style.light.sheen),
                       range: LookRanges.unit, format: .percent)
            LookSlider("Sheen sweep", editor.binding(\.style.light.sheenSweepSeconds),
                       range: LookRanges.sheenSweepSeconds, format: .seconds)
                .disabled(editor.look.style.light.sheen == 0)
            LookSlider("Grain", editor.binding(\.style.light.grain),
                       range: LookRanges.grain, format: .percent)
        }
        .disabled(!editor.isEditable)
    }
}
