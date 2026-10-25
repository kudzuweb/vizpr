#if DICT_DEV_LOG
import Foundation

/// Keeps the last dictation session's audio in memory so a lost ending can be
/// diagnosed by listening to it: `raw` is everything the microphone delivered,
/// `gated` is exactly what the speech gate let through to the engine.
///
/// Every call carries the session epoch (the same one the settle gate uses), so
/// the tail of a cancelled session, still draining after a new one has begun,
/// cannot write into the new session's buffers.
@MainActor
final class LastSessionAudio {
    /// 15 minutes per buffer, so a forgotten latched session cannot grow without bound.
    static let maxSamples = 15 * 60 * Int(MicrophoneCapture.sampleRate)

    private(set) var raw: [Float] = []
    private(set) var gated: [Float] = []
    private(set) var startedAt: Date?
    private(set) var isComplete = false
    private var epoch: Int?
    private var truncationNoted = false

    func begin(at date: Date, epoch: Int) {
        raw = []
        gated = []
        startedAt = date
        isComplete = false
        truncationNoted = false
        self.epoch = epoch
    }

    func appendRaw(_ samples: [Float], epoch: Int) {
        guard epoch == self.epoch else { return }
        append(samples, to: &raw)
    }

    func appendGated(_ samples: [Float], epoch: Int) {
        guard epoch == self.epoch else { return }
        append(samples, to: &gated)
    }

    func end(epoch: Int) {
        guard epoch == self.epoch else { return }
        isComplete = true
    }

    private func append(_ samples: [Float], to buffer: inout [Float]) {
        let room = Self.maxSamples - buffer.count
        guard room > 0 else { return noteTruncation() }
        buffer.append(contentsOf: samples.prefix(room))
        if samples.count > room { noteTruncation() }
    }

    private func noteTruncation() {
        guard !truncationNoted else { return }
        truncationNoted = true
        VizprTranscriptLogger.note("last-session audio: a buffer reached its 15 minute cap, later audio is not kept")
    }

    /// Writes both buffers as WAV files into `directory`, named from the
    /// session's start time, and returns their URLs.
    nonisolated static func write(
        raw: [Float], gated: [Float], startedAt: Date, to directory: URL
    ) throws -> (raw: URL, gated: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: startedAt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rate = Int(MicrophoneCapture.sampleRate)
        let rawURL = directory.appendingPathComponent("\(stamp)-raw.wav")
        let gatedURL = directory.appendingPathComponent("\(stamp)-gated.wav")
        try WAVFile.data(samples: raw, sampleRate: rate).write(to: rawURL)
        try WAVFile.data(samples: gated, sampleRate: rate).write(to: gatedURL)
        return (rawURL, gatedURL)
    }
}
#endif
