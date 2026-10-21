import SwiftUI

extension Color {
    /// 6-digit RGB hex (pre-sanitized by `VizprSettings.sanitizeHex`).
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    /// 6-digit RGB hex of the color in sRGB (nil if not convertible).
    var hexString: String? {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
