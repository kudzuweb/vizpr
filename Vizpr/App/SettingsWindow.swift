import SwiftUI

/// The Settings window (PLAN.md §14, PR 11). A standard SwiftUI window — no
/// over-glassing (§14) — hosting the panes. Every control writes through
/// SettingsStore.update, so changes apply LIVE and persist atomically.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore, vocabulary: VocabularyModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsRootView(store: settings, vocab: vocabulary)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vizpr Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 480))
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var vocab: VocabularyModel

    var body: some View {
        TabView {
            BehaviorPane(store: store)
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            AppearancePane(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            VocabularyPane(vocab: vocab)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
        }
        .frame(minWidth: 560, minHeight: 460)
        .padding()
    }
}

// MARK: - Bindings

private extension SettingsRootView {}

/// SwiftUI evaluates Binding closures on the main thread; assumeIsolated
/// bridges them to the MainActor store under strict concurrency.
private func bind<T: Sendable>(
    _ store: SettingsStore, _ keyPath: WritableKeyPath<VizprSettings, T> & Sendable
) -> Binding<T> {
    Binding(
        get: { MainActor.assumeIsolated { store.settings[keyPath: keyPath] } },
        set: { newValue in
            MainActor.assumeIsolated { store.update { $0[keyPath: keyPath] = newValue } }
        }
    )
}

// MARK: - Behavior

struct BehaviorPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Dictation") {
                Stepper("Settle window: \(store.settings.settleSentences) sentences",
                        value: bind(store, \.settleSentences), in: 1...6)
                sliderRow("Auto-stop after silence", bind(store, \.autoStopSeconds),
                          range: 2...60, unit: "s")
                sliderRow("Hold threshold (tap vs hold)", bind(store, \.holdThresholdMs),
                          range: 100...1000, unit: "ms")
                sliderRow("First-draft delay", bind(store, \.draftMinTailMs),
                          range: 500...4000, unit: "ms")
                sliderRow("Commit settle cap", bind(store, \.settleCapMs),
                          range: 0...1000, unit: "ms")
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts (local LLM)", isOn: bind(store, \.cleanupEnabled))
                Toggle("Always use code mode", isOn: bind(store, \.codeModeOverride))
            }
            Section("Output") {
                Toggle("Restore clipboard after paste", isOn: bind(store, \.restoreClipboard))
                Toggle("Inviz mode (indicator only, no live preview)",
                       isOn: bind(store, \.invizMode))
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ title: String, _ value: Binding<Int>,
                           range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0) }
            ), in: range)
            Text("\(value.wrappedValue)\(unit)")
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var store: SettingsStore
    @State private var presetName = ""

    var body: some View {
        Form {
            Section("Overlay tint") {
                ColorPicker("Background tint", selection: hexBinding(\.tintHex, fallback: "A16FDF"))
                HStack {
                    Text("Tint strength")
                    Slider(value: bind(store, \.tintStrength), in: 0...0.5)
                    Text(String(format: "%.0f%%", store.settings.tintStrength * 100))
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            Section("Text") {
                Toggle("Link text color to tint", isOn: bind(store, \.colorsLinked))
                if !store.settings.colorsLinked {
                    Toggle("Use system text colors", isOn: Binding(
                        get: { store.settings.textBaseHex == nil },
                        set: { on in store.update { $0.textBaseHex = on ? nil : "FFFFFF" } }
                    ))
                    if store.settings.textBaseHex != nil {
                        ColorPicker("Text color", selection: optionalHexBinding(\.textBaseHex))
                    }
                }
                Text("Final and provisional text always keep a fixed contrast ratio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Presets (\(store.settings.colorPresets.count)/\(VizprSettings.maxColorPresets))") {
                ForEach(store.settings.colorPresets) { preset in
                    HStack {
                        Circle().fill(Color(hex: preset.tintHex) ?? .gray)
                            .frame(width: 14, height: 14)
                        Text(preset.name.isEmpty ? preset.tintHex : preset.name)
                        Spacer()
                        Button("Apply") { apply(preset) }
                        Button(role: .destructive) { remove(preset) } label: { Text("Delete") }
                    }
                }
                HStack {
                    TextField("Preset name", text: $presetName)
                    Button("Save current") { saveCurrent() }
                        .disabled(store.settings.colorPresets.count >= VizprSettings.maxColorPresets)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func apply(_ preset: ColorPreset) {
        store.update {
            $0.tintHex = preset.tintHex
            $0.tintStrength = preset.tintStrength
            $0.textBaseHex = preset.textBaseHex
            $0.colorsLinked = preset.colorsLinked
        }
    }

    private func remove(_ preset: ColorPreset) {
        store.update { $0.colorPresets.removeAll { $0.id == preset.id } }
    }

    private func saveCurrent() {
        let snapshot = store.settings
        store.update {
            $0.colorPresets.append(ColorPreset(
                name: presetName,
                tintHex: snapshot.tintHex,
                tintStrength: snapshot.tintStrength,
                textBaseHex: snapshot.textBaseHex,
                colorsLinked: snapshot.colorsLinked
            ))
        }
        presetName = ""
    }

    private func hexBinding(_ keyPath: WritableKeyPath<VizprSettings, String>,
                            fallback: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: store.settings[keyPath: keyPath]) ?? Color(hex: fallback)! },
            set: { color in
                if let hex = color.hexString {
                    store.update { $0[keyPath: keyPath] = hex }
                }
            }
        )
    }

    private func optionalHexBinding(_ keyPath: WritableKeyPath<VizprSettings, String?>) -> Binding<Color> {
        Binding(
            get: { store.settings[keyPath: keyPath].flatMap { Color(hex: $0) } ?? .white },
            set: { color in
                if let hex = color.hexString {
                    store.update { $0[keyPath: keyPath] = hex }
                }
            }
        )
    }
}

extension Color {
    /// 6-digit RGB hex of the color in sRGB (nil if not convertible).
    var hexString: String? {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(converted.redComponent * 255))
        let g = Int(round(converted.greenComponent * 255))
        let b = Int(round(converted.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Vocabulary

struct VocabularyPane: View {
    @ObservedObject var vocab: VocabularyModel
    @State private var selectedBucket: String?
    @State private var newBucketName = ""
    @State private var newPattern = ""
    @State private var newReplacement = ""
    @State private var newAppBundle = ""

    var body: some View {
        Form {
            Section("Level") {
                Picker("Editing", selection: $selectedBucket) {
                    Text("Global").tag(String?.none)
                    ForEach(vocab.library.buckets) { bucket in
                        Text(bucket.name).tag(String?.some(bucket.name))
                    }
                }
                HStack {
                    TextField("New bucket (e.g. coding, casual)", text: $newBucketName)
                    Button("Add") {
                        let name = newBucketName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty,
                              !vocab.library.buckets.contains(where: { $0.name == name })
                        else { return }
                        vocab.library.buckets.append(VocabularyBucket(name: name))
                        newBucketName = ""
                    }
                }
            }
            Section("Entries") {
                ForEach(currentEntries, id: \.pattern) { entry in
                    HStack {
                        Text(entry.pattern)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(entry.replacement)
                        Spacer()
                        if selectedBucket != nil {
                            Button("Promote") {
                                vocab.library.promoteToGlobal(
                                    pattern: entry.pattern, fromBucket: selectedBucket!)
                            }
                        }
                        Button(role: .destructive) { remove(entry) } label: { Text("Remove") }
                    }
                }
                HStack {
                    TextField("Heard as…", text: $newPattern)
                    TextField("Write as…", text: $newReplacement)
                    Button("Add") { addEntry() }
                }
            }
            Section("Style rules for this level") {
                TextEditor(text: styleBinding)
                    .frame(height: 60)
                    .font(.body)
                Text("e.g. \"no capitalization\" or \"formal punctuation; expand contractions\"")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App assignments") {
                ForEach(vocab.library.appAssignments.sorted(by: { $0.key < $1.key }), id: \.key) { app, bucket in
                    HStack {
                        Text(app)
                        Spacer()
                        Text(bucket).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            vocab.library.appAssignments[app] = nil
                        } label: { Text("Remove") }
                    }
                }
                if let bucket = selectedBucket {
                    HStack {
                        TextField("Bundle id (e.g. com.microsoft.VSCode)", text: $newAppBundle)
                        Button("Assign to \(bucket)") {
                            let id = newAppBundle.trimmingCharacters(in: .whitespaces)
                            guard !id.isEmpty else { return }
                            vocab.library.appAssignments[id] = bucket
                            newAppBundle = ""
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var currentEntries: [VocabularyEntry] {
        if let name = selectedBucket {
            return vocab.library.buckets.first { $0.name == name }?.entries ?? []
        }
        return vocab.library.global
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: {
                if let name = selectedBucket {
                    return vocab.library.buckets.first { $0.name == name }?.styleRules ?? ""
                }
                return vocab.library.globalStyleRules
            },
            set: { rules in
                if let name = selectedBucket,
                   let index = vocab.library.buckets.firstIndex(where: { $0.name == name }) {
                    vocab.library.buckets[index].styleRules = rules
                } else {
                    vocab.library.globalStyleRules = rules
                }
            }
        )
    }

    private func addEntry() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !replacement.isEmpty else { return }
        let entry = VocabularyEntry(pattern: pattern, replacement: replacement, kind: .canonical)
        if let name = selectedBucket,
           let index = vocab.library.buckets.firstIndex(where: { $0.name == name }) {
            vocab.library.buckets[index].entries.append(entry)
        } else {
            vocab.library.global.append(entry)
        }
        newPattern = ""
        newReplacement = ""
    }

    private func remove(_ entry: VocabularyEntry) {
        if let name = selectedBucket,
           let index = vocab.library.buckets.firstIndex(where: { $0.name == name }) {
            vocab.library.buckets[index].entries.removeAll { $0.pattern == entry.pattern }
        } else {
            vocab.library.global.removeAll { $0.pattern == entry.pattern }
        }
    }
}
