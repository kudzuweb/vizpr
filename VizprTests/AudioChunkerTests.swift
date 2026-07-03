import Testing
@testable import Vizpr

@Suite("AudioChunker")
struct AudioChunkerTests {

    @Test("Batches smaller than a chunk accumulate until one completes")
    func accumulatesAcrossBatches() {
        var chunker = AudioChunker(chunkSize: 10)
        #expect(chunker.append(Array(repeating: 0, count: 4)).isEmpty)
        #expect(chunker.append(Array(repeating: 0, count: 5)).isEmpty)
        let chunks = chunker.append(Array(repeating: 0, count: 3))   // total 12
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 10)
    }

    @Test("A large batch yields several chunks and keeps the residue")
    func splitsLargeBatches() {
        var chunker = AudioChunker(chunkSize: 10)
        let chunks = chunker.append(Array(repeating: 0, count: 35))
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 10 })
        // 5 residue + 5 new completes the next chunk exactly.
        #expect(chunker.append(Array(repeating: 0, count: 5)).count == 1)
    }

    @Test("Sample order is preserved across chunk boundaries")
    func preservesOrder() {
        var chunker = AudioChunker(chunkSize: 4)
        let first = chunker.append([0, 1, 2])
        #expect(first.isEmpty)
        let chunks = chunker.append([3, 4, 5, 6, 7])
        #expect(chunks == [[0, 1, 2, 3], [4, 5, 6, 7]])
    }

    @Test("reset discards residue")
    func resetDiscardsResidue() {
        var chunker = AudioChunker(chunkSize: 4)
        _ = chunker.append([9, 9, 9])
        chunker.reset()
        // Post-reset, three fresh samples complete nothing…
        #expect(chunker.append([1, 2, 3]).isEmpty)
        // …and the completed chunk contains only post-reset samples.
        #expect(chunker.append([4]) == [[1, 2, 3, 4]])
    }

    @Test("Exact-size batch yields exactly one chunk and no residue")
    func exactFit() {
        var chunker = AudioChunker(chunkSize: 8)
        #expect(chunker.append(Array(0..<8).map(Float.init)).count == 1)
        #expect(chunker.append([]).isEmpty)
    }
}
