import Foundation
import HeadroomCore

/// Appends timestamped lines to ~/Library/Logs/Headroom.log. Callers never pass tokens or keys.
enum Log {
    private static let queue = DispatchQueue(label: "ai.askloci.headroom.log")
    private static let url = HeadroomPaths.current.logFile

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Moves a log over `limit` bytes to Headroom.old.log at launch.
    static func rotateIfLarge(limit: Int = 5_000_000) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit else { return }
        let old = url.deletingLastPathComponent().appending(path: "Headroom.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
