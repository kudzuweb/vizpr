import Foundation

/// Pure bundle-id → mode table (PLAN.md PR 10): dictating into an editor or
/// terminal flips cleanup's code mode (§10: preserve identifiers, no prose
/// re-punctuation of code-ish text).
enum CodeDetector {
    /// Exact bundle ids that are code surfaces.
    private static let codeBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "com.sublimetext.4",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed",
    ]

    /// Bundle-id prefixes that are code surfaces (families of apps).
    private static let codeBundlePrefixes = [
        "com.jetbrains.",
        "org.vim.",
    ]

    static func isCodeSurface(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if codeBundleIDs.contains(bundleID) { return true }
        return codeBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }
}
