#if DICT_DEV_LOG
import Foundation

/// Append-only JSONL writer for the dev transcript log (§14): one JSON object
/// per line at `transcripts.jsonl` in `VizprDevLogDirectory`. An actor so
/// concurrent records (cleanup outcomes race dictation commits) serialize into
/// whole lines — interleaved partial writes would corrupt the JSONL contract.
///
/// Compiled only under DICT_DEV_LOG; scripts/check-devlog-absent.sh asserts
/// the symbols are physically absent from Release.
actor VizprDevLogWriter {
    static let shared = VizprDevLogWriter()

    private let fileURL: URL
    private let encoder: JSONEncoder

    /// - Parameter fileURL: override for tests; defaults to the §14 path.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? VizprDevLogDirectory.transcriptsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        self.fileURL = url
        let encoder = JSONEncoder()
        // Sorted keys keep the lines diffable; no pretty-printing — the record
        // must stay on one line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func append(_ record: some Encodable & Sendable) {
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            // The logger must never take the pipeline down, but a broken dev
            // log shouldn't be silent either — breadcrumb it.
            VizprTranscriptLogger.note("devlog append failed: \(error)")
        }
    }
}
#endif
