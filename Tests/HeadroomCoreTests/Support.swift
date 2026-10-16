import Foundation
@testable import HeadroomCore

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}

/// A fresh directory under the temporary directory, removed when released.
final class TempDir {
    let url: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appending(path: "headroom-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // realpath gives the form directory listings report (/private/var/…);
        // URL.resolvingSymlinksInPath() would map it back to /var/….
        guard let resolved = realpath(raw.path(percentEncoded: false), nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

func date(_ iso: String) -> Date { ISODate.parse(iso)! }
