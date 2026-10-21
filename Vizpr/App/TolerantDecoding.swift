import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key`, or returns `fallback` when the key is missing or holds
    /// an unreadable value. Settings and looks use this so one absent or
    /// malformed field never discards the rest of a saved file.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
