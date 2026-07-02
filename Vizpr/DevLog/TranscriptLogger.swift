#if DICT_DEV_LOG
import Foundation
import os

/// Dev-only transcript logger (PLAN.md Part III §14).
///
/// Compiled **only** when `DICT_DEV_LOG` is defined (Debug builds), so it is
/// physically absent from Release — there is no toggle, no runtime flag, no
/// dead code in the shipping binary. The full JSONL appender lands in PR 7;
/// this PR establishes the compile gate and proves Release excludes it.
///
/// Output goes through unified logging (`os.Logger`) so it is observable no
/// matter how the app was launched — `print` to stdout is lost when the app is
/// started via LaunchServices (`open`), which is also the launch path that gives
/// the event tap correct TCC attribution. Watch with:
///   log stream --level debug --predicate 'subsystem == "com.kudzuweb.vizpr"'
enum VizprTranscriptLogger {
    /// Distinctive marker string used by scripts/check-devlog-absent.sh to assert
    /// this code is absent from Release binaries. Must not appear in Release.
    static let buildMarker = "VIZPR_DEV_LOG_BUILD_MARKER"

    private static let log = Logger(subsystem: "com.kudzuweb.vizpr", category: "devlog")

    /// Debug breadcrumbs also land here: unified logging drops debug-level
    /// lines under load, and a flat file is diagnosable after the fact.
    private static let debugFileURL: URL = {
        let dir = ("~/Documents/dictation-dev" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return URL(fileURLWithPath: dir + "/debug.log")
    }()

    /// Placeholder behavior: report where the dev transcript log will be written.
    /// Real append-on-dictation logic arrives in PR 7.
    static func announce() {
        let path = ("~/Documents/dictation-dev/transcripts.jsonl" as NSString)
            .expandingTildeInPath
        note("dev transcript log target: \(path)")
    }

    /// Emit a one-off developer breadcrumb. A stand-in until PR 7's structured
    /// JSONL records; useful for eyeballing the pipeline during bring-up.
    /// Called from the main thread only (pipeline + monitor are main-isolated).
    static func note(_ message: String) {
        log.debug("[\(buildMarker, privacy: .public)] \(message, privacy: .public)")
        let line = "\(Date().ISO8601Format()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: debugFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: debugFileURL)
        }
    }
}
#endif
