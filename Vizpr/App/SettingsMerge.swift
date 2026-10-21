import Foundation

/// Loads saved settings by laying the saved JSON over the encoded defaults, so
/// a field absent from the file takes its default and a new field needs no
/// loading code.
enum SettingsMerge {
    /// - Parameters:
    ///   - saved: the parsed settings file.
    ///   - defaults: the encoded default settings.
    ///   - elementDefaults: a template per array key. Array elements have no
    ///     default of their own, so each saved element is merged over its
    ///     key's template.
    ///
    /// A key present on both sides as dictionaries recurses. Any other saved
    /// value replaces the default. A key only in `defaults` stays, and a key
    /// only in `saved` passes through (synthesized decoding ignores unknown
    /// keys).
    static func merged(
        saved: [String: Any],
        over defaults: [String: Any],
        elementDefaults: [String: [String: Any]]
    ) -> [String: Any] {
        var result = defaults
        for (key, value) in saved {
            if let savedChild = value as? [String: Any], let defaultChild = defaults[key] as? [String: Any] {
                result[key] = merged(saved: savedChild, over: defaultChild, elementDefaults: elementDefaults)
            } else if let template = elementDefaults[key], let elements = value as? [[String: Any]] {
                result[key] = elements.map {
                    merged(saved: $0, over: template, elementDefaults: elementDefaults)
                }
            } else {
                result[key] = value
            }
        }
        return result
    }
}
