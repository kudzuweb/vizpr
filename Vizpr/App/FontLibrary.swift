import AppKit
import CoreText

/// The fonts a look can use: every installed family plus any font file the
/// user drops into the Fonts folder (PR 15). Files are registered with
/// process scope, so they load into Vizpr only and are never installed
/// system-wide.
@MainActor
enum FontLibrary {
    /// What a registration pass found in the folder.
    struct Report: Equatable {
        /// Family names declared by the font files in the folder.
        var families: [String]
        /// Files that could not be registered.
        var failedFiles: [String]
    }

    static let fileExtensions: Set<String> = ["ttf", "otf", "ttc"]

    static var folder: URL {
        StorageRoot.url.appendingPathComponent("Fonts", isDirectory: true)
    }

    /// Families registered from the Fonts folder so far. `NSFontManager` does
    /// not list a newly registered family until a later run-loop turn, so the
    /// picker list adds these itself.
    private static var registeredFamilies: Set<String> = []

    /// Every installed family plus the ones registered from the Fonts folder, sorted.
    static var families: [String] {
        Set(NSFontManager.shared.availableFontFamilies).union(registeredFamilies).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Creates the folder if it is missing, then registers every font file in
    /// it. Registering a file that is already registered is not an error, so
    /// this can run again to pick up newly added files.
    @discardableResult
    static func registerAll(in folder: URL = FontLibrary.folder) -> Report {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var report = Report(families: [], failedFiles: [])
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where fileExtensions.contains(file.pathExtension.lowercased()) {
            guard register(file) else {
                report.failedFiles.append(file.lastPathComponent)
                continue
            }
            for family in familyNames(in: file) where !report.families.contains(family) {
                report.families.append(family)
                registeredFamilies.insert(family)
            }
        }
        return report
    }

    private static func register(_ file: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) { return true }
        let failure = error?.takeRetainedValue()
        return failure.map { CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue } ?? false
    }

    private static func familyNames(in file: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }
    }
}
