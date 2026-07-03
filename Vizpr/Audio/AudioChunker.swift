/// Accumulates arbitrarily sized sample batches into the fixed-size chunks the
/// VAD model expects (PLAN.md §8: pure core, testable without audio hardware).
///
/// The mic tap delivers whatever buffer sizes the hardware route produces;
/// Silero consumes exactly `VadManager.chunkSize` (4096) samples per inference.
/// This is the seam where those cadences meet, kept pure so boundary math is
/// unit-tested rather than trusted.
struct AudioChunker {
    let chunkSize: Int
    private var pending: [Float] = []

    init(chunkSize: Int) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.chunkSize = chunkSize
    }

    /// Append new samples and return every completed chunk, each exactly
    /// `chunkSize` samples. Residue is held for the next call.
    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        guard pending.count >= chunkSize else { return [] }

        var chunks: [[Float]] = []
        var start = pending.startIndex
        while pending.count - start >= chunkSize {
            chunks.append(Array(pending[start ..< start + chunkSize]))
            start += chunkSize
        }
        pending.removeFirst(start)
        return chunks
    }

    /// Drop any buffered residue (session ended; a partial chunk of trailing
    /// audio is below the VAD's resolution and is intentionally discarded).
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
