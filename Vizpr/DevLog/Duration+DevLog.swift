#if DICT_DEV_LOG
import Foundation

extension Duration {
    /// Whole milliseconds, truncated; the one conversion every dev-log mark uses.
    var devLogMilliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
