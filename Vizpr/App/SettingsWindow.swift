import SwiftUI

/// The Settings window (PLAN.md §14, PR 11). A standard SwiftUI window — no
/// over-glassing (§14) — hosting the panes. Every control writes through
/// SettingsStore.update, so changes apply LIVE and persist atomically.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(settings: SettingsStore, vocabulary: VocabularyModel, models: ModelsModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsRootView(store: settings, vocab: vocabulary, models: models)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Vizpr Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 820))
        window.isReleasedWhenClosed = false
        self.window = window
        // Closing releases the window and its views, which stops the
        // Appearance preview's animation; the next show() builds a fresh one.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowClosed() }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func windowClosed() {
        closeObserver.map(NotificationCenter.default.removeObserver)
        closeObserver = nil
        window = nil
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var vocab: VocabularyModel
    @ObservedObject var models: ModelsModel
    @State private var confirmReset = false

    var body: some View {
        TabView {
            BehaviorPane(store: store)
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            AppearancePane(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            VocabularyPane(vocab: vocab)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ModelsPane(store: store, models: models)
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(minWidth: 640, minHeight: 600)
        .padding()
        // Field catch (Mauria): grouped-form TextFields render borderless —
        // literally invisible until you click the blank space. Rounded
        // borders for every field in the window.
        .textFieldStyle(.roundedBorder)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Reset All Settings", role: .destructive) { confirmReset = true }
                    .confirmationDialog(
                        "Reset every setting to its default? Color presets are kept.",
                        isPresented: $confirmReset
                    ) {
                        Button("Reset Everything", role: .destructive) { store.resetAll() }
                    }
            }
            .padding([.horizontal, .bottom])
        }
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
            Section("Hotkeys") {
                Toggle("Enable dictation hotkey", isOn: bind(store, \.hotkeyEnabled))
                LabeledContent("Start / stop") {
                    Text("Fn  (hold = push-to-talk, tap = latch)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Cancel") {
                    Text("⎋ Esc").foregroundStyle(.secondary)
                }
                LabeledContent("Secondary chord") {
                    HStack(spacing: 10) {
                        modifierToggle("⌃", "control")
                        modifierToggle("⌥", "option")
                        modifierToggle("⇧", "shift")
                        modifierToggle("⌘", "command")
                    }
                }
                Text("The chord needs at least two modifiers. Trigger reassignment is coming.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Toggle("Fall back to built-in mic if input is silent",
                       isOn: bind(store, \.silentInputFallback))
            }
        }
        .formStyle(.grouped)
    }

    private func modifierToggle(_ symbol: String, _ name: String) -> some View {
        Toggle(symbol, isOn: Binding(
            get: { store.settings.secondaryModifiers.contains(name) },
            set: { on in
                store.update {
                    if on {
                        if !$0.secondaryModifiers.contains(name) {
                            $0.secondaryModifiers.append(name)
                        }
                    } else if $0.secondaryModifiers.count > 2 {
                        $0.secondaryModifiers.removeAll { $0 == name }
                    }
                }
            }
        ))
        .toggleStyle(.button)
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

// MARK: - Vocabulary

extension VocabularyEntry: Identifiable {
    var id: String { pattern + "\u{1F}" + replacement }
}

/// Which level is being edited: the global dictionary or a named bucket.
enum VocabLevel: Hashable {
    case global
    case bucket(String)

    var title: String {
        switch self {
        case .global: return "Global"
        case .bucket(let name): return name
        }
    }
}

/// Master-detail vocabulary editor (Mauria's field feedback, 2026-07-06):
/// levels ALWAYS visible in a sidebar (no dropdown), entries in a multi-
/// select table with row actions, +/- panes in the classic macOS settings
/// style, and app assignment via a real app picker instead of typed bundle
/// ids.
struct VocabularyPane: View {
    @ObservedObject var vocab: VocabularyModel
    @State private var level: VocabLevel = .global
    @State private var selectedEntries = Set<VocabularyEntry.ID>()
    @State private var newBucketName = ""
    @State private var addingBucket = false
    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // USING is separate from EDITING (Mauria): this picker sets the
            // active dictionary (same state the menu/hotkey cycle drives);
            // sidebar selection below only chooses what you're editing.
            HStack {
                Picker("Active dictionary:", selection: activeBinding) {
                    Text("Global only").tag(String?.some(VocabularyLibrary.globalOnly))
                    Text("Automatic (per-app)").tag(String?.none)
                    Divider()
                    ForEach(vocab.library.buckets) { bucket in
                        Text(bucket.name).tag(String?.some(bucket.name))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
            }
            Text("Automatic uses each app's assignment; picking a bucket pins it everywhere. Selecting a level below only chooses what to edit.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 150, maxWidth: 190)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
    }

    private var activeBinding: Binding<String?> {
        Binding(
            get: { vocab.library.manualBucket },
            set: { vocab.library.manualBucket = $0 }
        )
    }

    // MARK: Sidebar — levels, always visible

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $level) {
                HStack {
                    Label("Global", systemImage: "globe")
                    if vocab.library.isGlobalOnly {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .help("Active: global only")
                    }
                }
                .tag(VocabLevel.global)
                Section("Buckets") {
                    ForEach(vocab.library.buckets) { bucket in
                        HStack {
                            Label(bucket.name, systemImage: "tray")
                            if vocab.library.manualBucket == bucket.name {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .help("Active dictionary")
                            }
                        }
                        .tag(VocabLevel.bucket(bucket.name))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 0) {
                Button { addingBucket = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).frame(width: 28, height: 24)
                Button { deleteCurrentBucket() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).frame(width: 28, height: 24)
                    .disabled(currentBucketName == nil)
                Spacer()
            }
            .background(.bar)
        }
        .alert("New Bucket", isPresented: $addingBucket) {
            TextField("Name (e.g. coding, casual)", text: $newBucketName)
            Button("Add") { addBucket() }
            Button("Cancel", role: .cancel) { newBucketName = "" }
        } message: {
            Text("A named dictionary you can assign to apps.")
        }
    }

    // MARK: Detail — entries table, style rules, app assignments

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(level.title).font(.headline)

            Table(currentEntries, selection: $selectedEntries) {
                TableColumn("Heard as…", value: \.pattern)
                TableColumn("Written as…", value: \.replacement)
            }
            .frame(minHeight: 140)

            HStack {
                TextField("Heard as…", text: $newPattern)
                TextField("Written as…", text: $newReplacement)
                Button("Add") { addEntry() }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty
                              || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Button("Remove") { removeSelected() }
                    .disabled(selectedEntries.isEmpty)
                if case .bucket(let name) = level {
                    Button("Copy to Global") { copySelectedToGlobal(from: name) }
                        .disabled(selectedEntries.isEmpty)
                }
                if !otherLevels.isEmpty {
                    Menu("Move to…") {
                        ForEach(otherLevels, id: \.self) { target in
                            Button(target.title) { moveSelected(to: target) }
                        }
                    }
                    .disabled(selectedEntries.isEmpty)
                    .frame(width: 110)
                }
                Spacer()
            }

            GroupBox("Style rules for \(level.title)") {
                TextEditor(text: styleBinding)
                    .frame(height: 48)
                    .font(.body)
            }

            if case .bucket(let name) = level {
                GroupBox("Apps using \(name)") {
                    assignmentsList(bucket: name)
                }
            }
        }
        .padding()
    }

    private func assignmentsList(bucket: String) -> some View {
        VStack(spacing: 0) {
            let assigned = vocab.library.appAssignments
                .filter { $0.value == bucket }.keys.sorted()
            if assigned.isEmpty {
                Text("No apps assigned — this bucket activates only via manual cycling.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                List(assigned, id: \.self) { app in
                    Text(appDisplayName(app))
                }
                .alternatingRowBackgrounds()
                .frame(height: min(CGFloat(assigned.count) * 26 + 12, 110))
            }
            Divider()
            HStack(spacing: 0) {
                Button { pickApp(for: bucket) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).frame(width: 28, height: 22)
                Menu {
                    ForEach(assigned, id: \.self) { app in
                        Button(appDisplayName(app)) {
                            vocab.library.appAssignments[app] = nil
                        }
                    }
                } label: { Image(systemName: "minus") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 22)
                    .disabled(assigned.isEmpty)
                Spacer()
            }
        }
    }

    // MARK: Data helpers

    private var currentEntries: [VocabularyEntry] {
        switch level {
        case .global: return vocab.library.global
        case .bucket(let name):
            return vocab.library.buckets.first { $0.name == name }?.entries ?? []
        }
    }

    private var currentBucketName: String? {
        if case .bucket(let name) = level { return name }
        return nil
    }

    private var otherLevels: [VocabLevel] {
        var levels: [VocabLevel] = level == .global ? [] : [.global]
        levels += vocab.library.buckets.map { VocabLevel.bucket($0.name) }
            .filter { $0 != level }
        return levels
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: {
                switch level {
                case .global: return vocab.library.globalStyleRules
                case .bucket(let name):
                    return vocab.library.buckets.first { $0.name == name }?.styleRules ?? ""
                }
            },
            set: { rules in
                switch level {
                case .global: vocab.library.globalStyleRules = rules
                case .bucket(let name):
                    if let i = vocab.library.buckets.firstIndex(where: { $0.name == name }) {
                        vocab.library.buckets[i].styleRules = rules
                    }
                }
            }
        )
    }

    // MARK: Actions

    private func addBucket() {
        let name = newBucketName.trimmingCharacters(in: .whitespaces)
        newBucketName = ""
        guard !name.isEmpty, name != "Global",
              !vocab.library.buckets.contains(where: { $0.name == name }) else { return }
        vocab.library.buckets.append(VocabularyBucket(name: name))
        level = .bucket(name)
    }

    private func deleteCurrentBucket() {
        guard let name = currentBucketName else { return }
        vocab.library.buckets.removeAll { $0.name == name }
        vocab.library.appAssignments = vocab.library.appAssignments.filter { $0.value != name }
        if vocab.library.manualBucket == name { vocab.library.manualBucket = nil }
        level = .global
    }

    private func addEntry() {
        let entry = VocabularyEntry(
            pattern: newPattern.trimmingCharacters(in: .whitespaces),
            replacement: newReplacement.trimmingCharacters(in: .whitespaces),
            kind: .canonical
        )
        mutateCurrent { $0.removeAll { $0.pattern == entry.pattern }; $0.append(entry) }
        newPattern = ""
        newReplacement = ""
    }

    private func removeSelected() {
        mutateCurrent { entries in entries.removeAll { selectedEntries.contains($0.id) } }
        selectedEntries = []
    }

    private func copySelectedToGlobal(from bucket: String) {
        let picked = currentEntries.filter { selectedEntries.contains($0.id) }
        for entry in picked {
            vocab.library.global.removeAll { $0.pattern == entry.pattern }
            vocab.library.global.append(entry)
        }
        selectedEntries = []
    }

    private func moveSelected(to target: VocabLevel) {
        let picked = currentEntries.filter { selectedEntries.contains($0.id) }
        mutateCurrent { entries in entries.removeAll { selectedEntries.contains($0.id) } }
        for entry in picked {
            mutate(level: target) { $0.removeAll { $0.pattern == entry.pattern }; $0.append(entry) }
        }
        selectedEntries = []
    }

    private func mutateCurrent(_ change: (inout [VocabularyEntry]) -> Void) {
        mutate(level: level, change)
    }

    private func mutate(level: VocabLevel, _ change: (inout [VocabularyEntry]) -> Void) {
        switch level {
        case .global:
            change(&vocab.library.global)
        case .bucket(let name):
            if let i = vocab.library.buckets.firstIndex(where: { $0.name == name }) {
                change(&vocab.library.buckets[i].entries)
            }
        }
    }

    private func pickApp(for bucket: String) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps that should use the \(bucket) dictionary"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                vocab.library.appAssignments[id] = bucket
            }
        }
    }

    private func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - Models

/// The Models pane (§14): two single-select lists (ASR, cleanup), bundled +
/// user models, invalid folders shown disabled with the registry's reason
/// verbatim. The list updates live via the FS watcher; selecting swaps the
/// engine without a relaunch.
struct ModelsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var models: ModelsModel

    var body: some View {
        Form {
            Section("Speech recognition") {
                modelList(kind: .asr, selection: \.asrModelID)
            }
            Section("Cleanup") {
                modelList(kind: .cleanup, selection: \.cleanupModelID)
            }
            Section {
                LabeledContent("Add models") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([models.userRoot])
                    }
                }
                Text("Drop a model folder (with its manifest.json) into "
                     + "Models/asr or Models/cleanup — it appears here "
                     + "immediately. Models load from disk only; nothing is "
                     + "ever downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { models.rescan() }
    }

    @ViewBuilder
    private func modelList(
        kind: ModelKind, selection: WritableKeyPath<VizprSettings, String?> & Sendable
    ) -> some View {
        let entries = models.entries(kind: kind)
        if entries.isEmpty {
            Text("No models found.").foregroundStyle(.secondary)
        }
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            modelRow(entry, kind: kind, selection: selection)
        }
    }

    @ViewBuilder
    private func modelRow(
        _ entry: ModelEntry, kind: ModelKind,
        selection: WritableKeyPath<VizprSettings, String?> & Sendable
    ) -> some View {
        let selectedID = store.settings[keyPath: selection]
        let isActive = ModelsModel.isActive(entry, selectedID: selectedID)
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.manifest?.displayName ?? entry.directory.lastPathComponent)
                Text(detailLine(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = entry.disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .opacity(entry.isUsable ? 1 : 0.55)
            Spacer()
            // Explicit activation (Mauria): adding a model never activates
            // it — the user sets the active one per list, and it applies
            // live (the engine swaps on the spot).
            if isActive {
                Text("Active")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            } else if entry.isUsable {
                Button("Set Active") {
                    // Activating the bundled model stores nil (the default),
                    // so a fresh settings file and "picked bundled" mean the
                    // same thing.
                    let newID = entry.origin == .bundled ? nil : entry.manifest?.id
                    MainActor.assumeIsolated {
                        store.update { $0[keyPath: selection] = newID }
                    }
                }
            }
        }
    }

    private func detailLine(_ entry: ModelEntry) -> String {
        var parts: [String] = []
        if let manifest = entry.manifest {
            parts.append(manifest.runtime)
            parts.append(manifest.language)
        }
        if let size = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append(entry.origin == .bundled ? "bundled" : "user")
        return parts.joined(separator: " · ")
    }
}
