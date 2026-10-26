import SwiftUI

/// Surface kind, corner radius, and the controls of the chosen surface: tint
/// and frost for glass, color and opacity for solid, the mesh for the slab.
struct SurfaceSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let editor = LookEditor(store)
        let look = editor.look
        Section("Surface") {
            Picker("Surface", selection: editor.binding(\.surface)) {
                ForEach(OverlayLook.Surface.allCases, id: \.self) { surface in
                    Text(surface.rawValue.capitalized).tag(surface)
                }
            }
            LookSlider("Corner radius", editor.binding(\.cornerRadius),
                       range: OverlayLook.cornerRadiusRange, format: .points())
            if look.surface == .glass {
                ColorPicker("Tint", selection: editor.color(\.tintHex), supportsOpacity: false)
                LookSlider("Tint strength", editor.binding(\.tintStrength),
                           range: OverlayLook.tintStrengthRange, format: .percent)
                LookSlider("Frost: clear → solid", editor.binding(\.style.fill.frost),
                           range: LookRanges.unit, format: .percent)
                ColorPicker("Frost color", selection: editor.color(\.style.fill.colorHex), supportsOpacity: false)
            } else if look.surface == .slab {
                slabControls(editor)
            } else {
                ColorPicker("Color", selection: editor.color(\.style.fill.colorHex), supportsOpacity: false)
                LookSlider("Opacity", editor.binding(\.style.fill.frost),
                           range: LookRanges.unit, format: .percent)
            }
        }
        .disabled(!editor.isEditable)
    }

    @ViewBuilder
    private func slabControls(_ editor: LookEditor) -> some View {
        LookSlider("Mesh drift", editor.binding(\.slab.meshDrift),
                   range: LookRanges.meshDrift, format: .percent)
        LookSlider("Drift loop", editor.binding(\.slab.meshLoopSeconds),
                   range: LookRanges.meshLoopSeconds, format: .seconds)
        LabeledContent("Mesh colors") {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            ColorPicker("", selection: editor.meshColor(row * 3 + column), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 48, height: 24)
                        }
                    }
                }
            }
        }
    }
}
