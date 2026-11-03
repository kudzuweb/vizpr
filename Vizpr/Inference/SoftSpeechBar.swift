/// Absolute sample ranges of the session that the speech gate forwarded after
/// the VAD went inactive (a trailing span or a re-onset span). The engine
/// appends one per soft batch, so contiguous batches merge into one run.
struct SoftRuns: Equatable {
    private(set) var ranges: [Range<Int>] = []

    mutating func append(_ range: Range<Int>) {
        if let last = ranges.last, last.upperBound == range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound ..< range.upperBound
        } else {
            ranges.append(range)
        }
    }

    /// Forgets runs that end at or before `sample`, the start of the audio the
    /// engine still buffers.
    mutating func trim(before sample: Int) {
        ranges.removeAll { $0.upperBound <= sample }
    }

    /// Whether `span` lies inside one run, so every sample of it was soft.
    func covers(_ span: Range<Int>) -> Bool {
        ranges.contains { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }
    }
}

/// The confidence bar on audio forwarded after the VAD went inactive.
/// Noise that gets through the gate decodes at low confidence, so text from an
/// entirely soft span is kept only above `Tuning.softSpeechMinConfidence`.
/// Audio that mixes soft and ordinary samples is judged as it always was.
enum SoftSpeechBar {

    /// Whether a final's text may be emitted.
    static func keeps(_ cut: TimedCut.Cut, entirelySoft: Bool) -> Bool {
        !entirelySoft || cut.confidence >= Tuning.softSpeechMinConfidence
    }

    /// A draft's text, or empty when the draft is entirely soft and under the
    /// bar. The empty draft replaces any earlier one for the same window.
    static func draftText(_ text: String, confidence: Float, entirelySoft: Bool) -> String {
        entirelySoft && confidence < Tuning.softSpeechMinConfidence ? "" : text
    }
}
