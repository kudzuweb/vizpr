import SwiftUI

/// The Appearance tab: the list of looks, a live preview pinned above the
/// editor, and one section of controls per aspect of the active look. Every
/// control writes through `SettingsStore.updateActiveLook`, so edits apply live
/// and persist.
struct AppearancePane: View {
    @ObservedObject var store: SettingsStore

    private var activeLook: OverlayLook { store.settings.activeLook }
    private var editable: Bool { !activeLook.isBuiltIn }

    var body: some View {
        VStack(spacing: 0) {
            LivePreview(look: activeLook)
                .padding(.bottom, 8)
            Form {
                lookSection
                SurfaceSection(store: store)
                BackdropSection(store: store)
                FinishSection(store: store)
                BorderSection(store: store)
                GlowSection(store: store)
                ShadowSection(store: store)
                ShapeSection(store: store)
                TextSection(store: store)
                DotSection(store: store)
            }
            .formStyle(.grouped)
        }
    }

    private var lookSection: some View {
        Section("Looks (\(store.settings.looks.count)/\(VizprSettings.maxLooks))") {
            ForEach(OverlayLook.builtIns + store.settings.looks) { look in
                Button { store.selectLook(look.id) } label: {
                    HStack {
                        Circle().fill(look.tintColor).frame(width: 14, height: 14)
                        Text(look.name)
                        Spacer()
                        if look.id == activeLook.id {
                            Image(systemName: "checkmark")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if editable {
                TextField("Name", text: Binding(
                    get: { activeLook.name },
                    set: { name in store.updateActiveLook { $0.name = name } }
                ))
            } else {
                Text("Duplicate a built-in look to edit it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Duplicate") { store.duplicateLook(activeLook) }
                    .disabled(store.settings.looks.count >= VizprSettings.maxLooks)
                Button("Delete", role: .destructive) { store.deleteLook(activeLook.id) }
                    .disabled(!editable)
            }
            Button("Delete All Looks", role: .destructive) {
                store.deleteAllLooks()
            }
            .disabled(store.settings.looks.isEmpty)
            HStack {
                Button("Open Looks Folder") { NSWorkspace.shared.open(store.looksFolderForOpening()) }
                Button("Reload Looks") { store.reloadLooks() }
            }
            fileCaptions
        }
    }

    @ViewBuilder
    private var fileCaptions: some View {
        let unreadable = store.lookFileFailures.filter { $0.kind == .unreadable }
        let overLimit = store.lookFileFailures.filter { $0.kind == .overLimit }
        let notSaved = store.lookFileFailures.filter { $0.kind == .notSaved }
        let notDeleted = store.lookFileFailures.filter { $0.kind == .notDeleted }
        if !notSaved.isEmpty {
            HStack {
                Text("\(notSaved.count) \(notSaved.count == 1 ? "look" : "looks") could not be saved and will be gone after Vizpr quits")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Looks Folder") { NSWorkspace.shared.open(store.looksFolderForOpening()) }
            }
        }
        if !notDeleted.isEmpty {
            HStack {
                Text("\(notDeleted.count) look \(notDeleted.count == 1 ? "file" : "files") could not be moved to the Trash and will return after a relaunch")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(notDeleted.map(\.url))
                }
            }
        }
        if !unreadable.isEmpty {
            HStack {
                Text("\(unreadable.count) look \(unreadable.count == 1 ? "file" : "files") could not be read")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(unreadable.map(\.url))
                }
            }
        }
        if !overLimit.isEmpty {
            Text("Over the limit of \(VizprSettings.maxLooks), not loaded: "
                + overLimit.map { $0.url.lastPathComponent }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let problem = store.lookMigrationProblem {
            Text("Your looks are still stored in settings.json: \(problem)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
