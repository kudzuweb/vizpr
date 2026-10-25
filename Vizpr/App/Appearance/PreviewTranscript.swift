import Foundation

/// Sample dictation that types itself into the Settings preview, so a look is
/// judged on moving text the way the real overlay shows it: the first two
/// sentences settle as they finish and everything after stays mutable.
@MainActor
final class PreviewTranscript: ObservableObject {
    static let sentences = [
        "Hold the key, speak, and watch the words appear.",
        "Once a sentence has settled it never changes again.",
        "Words that can still change sit a little lighter,",
        "so you can proofread as you speak and fix a slip before you let go.",
        "Whatever you see when you stop is what gets typed."
    ]
    /// Sentences that settle once finished.
    static let settledSentenceCount = 2

    @Published private(set) var snapshot = DisplaySnapshot.empty

    private let wordInterval: Duration
    /// How long the finished text stays up before the loop restarts.
    private let holdInterval: Duration

    init(wordInterval: Duration = .milliseconds(150), holdInterval: Duration = .seconds(2)) {
        self.wordInterval = wordInterval
        self.holdInterval = holdInterval
    }

    static var wordCount: Int { sentences.reduce(0) { $0 + words(in: $1).count } }

    /// The snapshot after `wordCount` words have been spoken. `settled` holds
    /// the finished sentences among the first `settledSentenceCount`; `live`
    /// holds the rest, with the leading space the real stream gives it, so
    /// `displayed` always begins with `settled`.
    static func snapshot(wordCount: Int) -> DisplaySnapshot {
        var remaining = wordCount
        var settled = ""
        var live = ""
        for (index, sentence) in sentences.enumerated() {
            let words = words(in: sentence)
            guard remaining > 0 else { break }
            let spoken = words.prefix(remaining).joined(separator: " ")
            remaining -= words.count
            let finished = remaining >= 0
            if index < settledSentenceCount, finished, live.isEmpty {
                settled += (settled.isEmpty ? "" : " ") + spoken
            } else {
                live += (settled.isEmpty && live.isEmpty ? "" : " ") + spoken
            }
        }
        return DisplaySnapshot(settled: settled, live: live, draft: "")
    }

    private static func words(in sentence: String) -> [String] {
        sentence.split(separator: " ").map(String.init)
    }

    /// Types the sample out word by word, holds it, and starts over. Runs
    /// until the calling task is cancelled.
    func run() async {
        while !Task.isCancelled {
            snapshot = .empty
            for count in 1...Self.wordCount {
                try? await Task.sleep(for: wordInterval)
                if Task.isCancelled { return }
                snapshot = Self.snapshot(wordCount: count)
            }
            try? await Task.sleep(for: holdInterval)
        }
    }
}
