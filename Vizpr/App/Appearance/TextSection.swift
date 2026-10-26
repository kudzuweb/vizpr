import SwiftUI

/// Font family (including fonts from the Fonts folder), weight, size, spacing,
/// color and glow of the transcript text.
struct TextSection: View {
    @ObservedObject var store: SettingsStore
    @State private var families: [String] = []
    @State private var failedFontFiles: [String] = []

    var body: some View {
        let editor = LookEditor(store)
        let look = editor.look
        Section("Text") {
            FontFamilyList(family: editor.binding(\.style.text.fontFamily), families: families)
                .disabled(!editor.isEditable)
            HStack {
                Button("Open Fonts Folder") { openFontsFolder() }
                Button("Reload Fonts") { reloadFonts() }
            }
            if !failedFontFiles.isEmpty {
                Text("Could not load: \(failedFontFiles.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Picker("System design", selection: editor.binding(\.fontDesign)) {
                    ForEach(OverlayLook.FontDesign.allCases, id: \.self) { design in
                        Text(design.rawValue.capitalized).tag(design)
                    }
                }
                .disabled(look.style.text.fontFamily != nil)
                Picker("Weight", selection: editor.binding(\.style.text.weight)) {
                    ForEach(TextStyle.Weight.allCases, id: \.self) { weight in
                        Text(weight.rawValue.capitalized).tag(weight)
                    }
                }
                LookSlider("Font size", editor.binding(\.fontSize),
                           range: OverlayLook.fontSizeRange, format: .points())
                LookSlider("Line spacing", editor.binding(\.style.text.lineSpacing),
                           range: LookRanges.lineSpacing, format: .points())
                colorControls(editor)
                glowControls(editor)
            }
            .disabled(!editor.isEditable)
            Text("Final and provisional text always keep a fixed contrast ratio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { families = FontLibrary.families }
    }

    @ViewBuilder
    private func colorControls(_ editor: LookEditor) -> some View {
        Toggle("Link text color to tint", isOn: editor.binding(\.colorsLinked))
        if !editor.look.colorsLinked {
            Toggle("Use system text colors", isOn: editor.isNil(\.textBaseHex, fallback: "FFFFFF"))
            if editor.look.textBaseHex != nil {
                ColorPicker("Text color", selection: editor.optionalColor(\.textBaseHex, placeholder: "FFFFFF"),
                            supportsOpacity: false)
            }
        }
    }

    @ViewBuilder
    private func glowControls(_ editor: LookEditor) -> some View {
        Toggle("Text glow", isOn: editor.binding(\.style.text.glowEnabled))
        Group {
            ColorPicker("Glow color", selection: editor.color(\.style.text.glowColorHex), supportsOpacity: false)
            LookSlider("Glow radius", editor.binding(\.style.text.glowRadius),
                       range: LookRanges.textGlowRadius, format: .points())
        }
        .disabled(!editor.look.style.text.glowEnabled)
    }

    private func openFontsFolder() {
        FontLibrary.registerAll()
        NSWorkspace.shared.open(FontLibrary.folder)
    }

    private func reloadFonts() {
        failedFontFiles = FontLibrary.registerAll().failedFiles
        families = FontLibrary.families
    }
}
