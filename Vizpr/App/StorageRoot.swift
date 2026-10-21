import Foundation

/// Where the app keeps its files (settings, vocabulary, user models).
enum StorageRoot {
    /// A test run hosts the real app, so it gets a fresh temp directory:
    /// otherwise loading and saving would rewrite the user's real files.
    static let url: URL = {
        if AppDelegate.isHostedByTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("vizpr-test-host-\(UUID().uuidString)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vizpr", isDirectory: true)
    }()
}
