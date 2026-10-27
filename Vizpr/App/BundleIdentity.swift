import Darwin
import Foundation

/// Whether this process still has the app it was launched from.
///
/// An app whose executable path no longer resolves is not trusted by the OS: in
/// the 2026-10-27 incident WindowServer refused a tap owner it could not map to
/// a file. The check is a pure function over injected probes so each failure is
/// testable; `BundleIdentity.Probe.system` reads the real process and bundle.
enum BundleIdentity {
    /// The file a path names, compared by device and inode, not by path string:
    /// a launch through a symlinked folder makes two strings differ while they
    /// name the same file.
    struct FileID: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    enum Failure: Equatable, Sendable {
        case executableMissing
        case processPathUnresolved
        case processPathDiffers
        case resourceMissing(String)

        var detail: String {
            switch self {
            case .executableMissing:
                "The app's executable is missing."
            case .processPathUnresolved:
                "macOS cannot find the file this copy of Vizpr is running from."
            case .processPathDiffers:
                "The file this copy of Vizpr is running from is not the one in its app bundle."
            case .resourceMissing(let name):
                "\(name) is missing from the app bundle."
            }
        }
    }

    struct Probe {
        /// The bundle's own executable, or nil if it cannot be found.
        var executableFileID: () -> FileID?
        /// The file `proc_pidpath` reports for this process, or nil if it fails.
        var processFileID: () -> FileID?
        /// Whether a path relative to `Contents/Resources` exists.
        var resourceExists: (String) -> Bool
    }

    /// Resources the app loads lazily, so a missing one would only surface
    /// mid-dictation. Existence only: no Metal device is created.
    static let requiredResources = ["default.metallib", "Models", "mlx-swift_Cmlx.bundle"]

    static func firstFailure(_ probe: Probe, resources: [String] = requiredResources) -> Failure? {
        guard let executable = probe.executableFileID() else { return .executableMissing }
        guard let process = probe.processFileID() else { return .processPathUnresolved }
        guard executable == process else { return .processPathDiffers }
        return resources.first { !probe.resourceExists($0) }.map(Failure.resourceMissing)
    }

    /// Whether `proc_pidpath` still resolves this process to a file.
    static func processPathResolves() -> Bool {
        processFileID() != nil
    }

    fileprivate static func processFileID() -> FileID? {
        // proc_pidpath's documented buffer size, PROC_PIDPATHINFO_MAXSIZE (a macro Swift cannot import).
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        guard let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8) else { return nil }
        return fileID(atPath: path)
    }

    fileprivate static func fileID(atPath path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

extension BundleIdentity.Probe {
    static var system: Self {
        Self(
            executableFileID: {
                Bundle.main.executableURL.flatMap { BundleIdentity.fileID(atPath: $0.path) }
            },
            processFileID: { BundleIdentity.processFileID() },
            resourceExists: { name in
                Bundle.main.resourceURL.map {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path)
                } ?? false
            }
        )
    }
}
