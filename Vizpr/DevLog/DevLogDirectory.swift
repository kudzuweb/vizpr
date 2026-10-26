#if DICT_DEV_LOG
import Foundation

/// The one place the dev log directory is chosen, so the breadcrumb file and
/// the JSONL writer always agree.
enum VizprDevLogDirectory {
    /// A test run hosts the real Debug app, so its fake engines would
    /// otherwise append test traffic to the developer's real logs.
    static let url: URL = {
        if AppDelegate.isHostedByTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("vizpr-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return URL(fileURLWithPath: ("~/Documents/dictation-dev" as NSString).expandingTildeInPath, isDirectory: true)
    }()

    static let debugLogURL = url.appendingPathComponent("debug.log")
    static let transcriptsURL = url.appendingPathComponent("transcripts.jsonl")
}
#endif
