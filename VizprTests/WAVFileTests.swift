#if DICT_DEV_LOG
import Foundation
import Testing
@testable import Vizpr

@Suite("WAVFile")
struct WAVFileTests {

    @Test("Header and data chunk are the expected bytes for three samples, with out-of-range input clamped")
    func encodesThreeSamples() {
        let data = [UInt8](WAVFile.data(samples: [0, 2, -2], sampleRate: 16_000))

        let expectedHeader: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,  // "RIFF"
            42, 0, 0, 0,             // RIFF size: 36 + 6 data bytes
            0x57, 0x41, 0x56, 0x45,  // "WAVE"
            0x66, 0x6D, 0x74, 0x20,  // "fmt "
            16, 0, 0, 0,             // fmt chunk size
            1, 0,                    // PCM
            1, 0,                    // mono
            0x80, 0x3E, 0, 0,        // 16000 Hz
            0x00, 0x7D, 0, 0,        // byte rate 32000
            2, 0,                    // block align
            16, 0,                   // bits per sample
            0x64, 0x61, 0x74, 0x61,  // "data"
            6, 0, 0, 0,              // data size
        ]
        #expect(Array(data.prefix(44)) == expectedHeader)
        // 0 -> 0, 2 -> clamped to +1 -> 32767, -2 -> clamped to -1 -> -32767.
        #expect(Array(data.dropFirst(44)) == [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80])
    }
}
#endif
