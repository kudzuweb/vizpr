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

    /// The moment the logger was first used; launch marks are measured from it.
    /// `announce()` runs first in the launch sequence so this is launch time.
    private static let openedAt = ContinuousClock.now

    static func millisecondsSinceOpen() -> Int {
        let parts = (ContinuousClock.now - openedAt).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Report where the dev transcript log is written (the structured JSONL
    /// records land there via VizprDevLogWriter) and which build is running.
    /// `VIZPR_BUILD_ID` is exported by scripts/run-dev.sh.
    static func announce() {
        _ = openedAt
        note("dev transcript log target: \(VizprDevLogDirectory.transcriptsURL.path)")
        let buildID = ProcessInfo.processInfo.environment["VIZPR_BUILD_ID"] ?? "unknown"
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        note("build: \(buildID) \(configuration)")
    }

    // MARK: Dictation session id

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var openSessionID: String?

    /// Open a dictation session: every line noted until `endSession` carries
    /// its id, so the log lines and the JSONL records of one session join.
    static func beginSession() -> String {
        let id = String(UUID().uuidString.prefix(8))
        sessionLock.lock()
        defer { sessionLock.unlock() }
        openSessionID = id
        return id
    }

    /// Close the session at its drain. Ignored when a newer session has
    /// already opened, so a late drain cannot strip the new session's id.
    static func endSession(_ id: String) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if openSessionID == id { openSessionID = nil }
    }

    private static var sessionPrefix: String {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return openSessionID.map { "[s:\($0)] " } ?? ""
    }

    /// `2026-10-25T05:24:00.123Z`: the same shape as before with milliseconds.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let fileLock = NSLock()

    /// Emit a one-off developer breadcrumb — the human-readable running
    /// commentary next to the structured JSONL records; useful for eyeballing
    /// the pipeline live. Safe from any thread; returns after the line is written.
    static func note(_ message: String) {
        log.debug("[\(buildMarker, privacy: .public)] \(message, privacy: .public)")
        let line = "\(Date().formatted(timestampStyle)) \(sessionPrefix)\(message)\n"
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
