import SwiftUI

/// Reads the active look and writes edits through `SettingsStore.updateActiveLook`,
/// which ignores built-ins. Every editor control binds through this, so a
/// section is a list of controls and no hand-written bindings.
///
/// SwiftUI evaluates Binding closures on the main thread; `assumeIsolated`
/// bridges them to the MainActor store under strict concurrency.
@MainActor
struct LookEditor {
    let store: SettingsStore

    init(_ store: SettingsStore) { self.store = store }

    var look: OverlayLook { store.settings.activeLook }
    var isEditable: Bool { !look.isBuiltIn }

    /// Any field of the look: a `Double`, a `Bool`, an enum, an optional.
    func binding<T: Sendable>(_ keyPath: WritableKeyPath<OverlayLook, T> & Sendable) -> Binding<T> {
        Binding(
            get: { MainActor.assumeIsolated { store.settings.activeLook[keyPath: keyPath] } },
            set: { value in
                MainActor.assumeIsolated { store.updateActiveLook { $0[keyPath: keyPath] = value } }
            }
        )
    }

    /// A 6-digit hex field, as a `ColorPicker` selection.
    func color(_ keyPath: WritableKeyPath<OverlayLook, String> & Sendable) -> Binding<Color> {
        Binding(
            get: { MainActor.assumeIsolated { Color(hex: store.settings.activeLook[keyPath: keyPath]) ?? .white } },
            set: { color in
                guard let hex = color.hexString else { return }
                MainActor.assumeIsolated { store.updateActiveLook { $0[keyPath: keyPath] = hex } }
            }
        )
    }

    /// An optional hex field; while it is nil the picker shows `placeholder`.
    func optionalColor(
        _ keyPath: WritableKeyPath<OverlayLook, String?> & Sendable, placeholder: String
    ) -> Binding<Color> {
        Binding(
            get: {
                MainActor.assumeIsolated {
                    Color(hex: store.settings.activeLook[keyPath: keyPath] ?? placeholder) ?? .white
                }
            },
            set: { color in
                guard let hex = color.hexString else { return }
                MainActor.assumeIsolated { store.updateActiveLook { $0[keyPath: keyPath] = hex } }
            }
        )
    }

    /// Whether an optional field is nil, as a toggle: turning it on clears the
    /// field, turning it off sets it to `fallback`.
    func isNil(
        _ keyPath: WritableKeyPath<OverlayLook, String?> & Sendable, fallback: String
    ) -> Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { store.settings.activeLook[keyPath: keyPath] == nil } },
            set: { on in
                MainActor.assumeIsolated { store.updateActiveLook { $0[keyPath: keyPath] = on ? nil : fallback } }
            }
        )
    }

    /// One of the slab's nine mesh colors.
    func meshColor(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                MainActor.assumeIsolated {
                    let colors = store.settings.activeLook.slab.meshColorsHex
                    return colors.indices.contains(index) ? Color(hex: colors[index]) ?? .black : .black
                }
            },
            set: { color in
                guard let hex = color.hexString else { return }
                MainActor.assumeIsolated {
                    store.updateActiveLook {
                        guard $0.slab.meshColorsHex.indices.contains(index) else { return }
                        $0.slab.meshColorsHex[index] = hex
                    }
                }
            }
        )
    }
}

/// A labelled slider that shows its value.
struct LookSlider: View {
    enum Format {
        case points(decimals: Int = 0)
        case percent
        case seconds

        func string(_ value: Double) -> String {
            switch self {
            case .points(let decimals): String(format: "%.\(decimals)f pt", value)
            case .percent: String(format: "%.0f%%", value * 100)
            case .seconds: String(format: "%.1f s", value)
            }
        }
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: Format

    init(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>, format: Format) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format.string(value))
                .monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}
