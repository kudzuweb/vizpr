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
///
/// `note` is called from several threads (main, the pipeline's fan-out task,
/// engine actors). Each call opens, seeks and writes the file, so two callers
/// at the same instant seek to the same end offset and one line overwrites the
/// other. A lock around the open-write-close keeps every line, in call order.
enum VizprTranscriptLogger {
    /// Distinctive marker string used by scripts/check-devlog-absent.sh to assert
    /// this code is absent from Release binaries. Must not appear in Release.
    static let buildMarker = "VIZPR_DEV_LOG_BUILD_MARKER"

    private static let log = Logger(subsystem: "com.kudzuweb.vizpr", category: "devlog")

    /// Debug breadcrumbs also land here: unified logging drops debug-level
    /// lines under load, and a flat file is diagnosable after the fact.
    private static let debugFileURL: URL = {
        try? FileManager.default.createDirectory(
            at: VizprDevLogDirectory.url, withIntermediateDirectories: true
        )
        return VizprDevLogDirectory.debugLogURL
    }()

    /// Report where the dev transcript log is written (the structured JSONL
    /// records land there via VizprDevLogWriter).
    static func announce() {
        note("dev transcript log target: \(VizprDevLogDirectory.transcriptsURL.path)")
    }

    private static let fileLock = NSLock()

    /// Emit a one-off developer breadcrumb — the human-readable running
    /// commentary next to the structured JSONL records; useful for eyeballing
    /// the pipeline live. Safe from any thread; returns after the line is written.
    static func note(_ message: String) {
        log.debug("[\(buildMarker, privacy: .public)] \(message, privacy: .public)")
        let line = "\(Date().ISO8601Format()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        append(data, to: debugFileURL)
    }

    static func append(_ data: Data, to url: URL) {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
