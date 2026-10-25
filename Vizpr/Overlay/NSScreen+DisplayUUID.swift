import AppKit

extension NSScreen {
    /// A stable identifier for this display (its CoreGraphics UUID), used as
    /// the key for per-display overlay positions. Unlike the display's frame
    /// or its number, it survives reconnects and arrangement changes.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
