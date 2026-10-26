#if DICT_DEV_LOG
import Foundation

/// Encodes mono float samples as a 16-bit PCM WAV file. Written by hand so it
/// has no AVFoundation dependency and can be tested as bytes.
enum WAVFile {
    private static let headerByteCount = 44

    /// Samples are clamped to -1...1 before conversion; NaN is written as 0.
    static func data(samples: [Float], sampleRate: Int) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let dataByteCount = UInt32(samples.count) * UInt32(blockAlign)

        var data = Data(capacity: headerByteCount + Int(dataByteCount))
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))   // PCM
        data.append(littleEndian: channelCount)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate) * UInt32(blockAlign))
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataByteCount)
        for sample in samples {
            let clamped = sample.isNaN ? 0 : min(max(sample, -1), 1)
            data.append(littleEndian: Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
#endif
