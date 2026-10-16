import Foundation
import Testing
@testable import HeadroomCore

struct LineReaderTests {
    func lines(_ url: URL, from offset: UInt64 = 0, chunk: Int = 7) throws -> (lines: [String], offsets: [UInt64], end: UInt64) {
        var lines: [String] = []
        var offsets: [UInt64] = []
        let end = try LineReader.forEachLine(url: url, from: offset, chunkSize: chunk) { line, start in
            lines.append(String(decoding: line, as: UTF8.self))
            offsets.append(start)
            return true
        }
        return (lines, offsets, end)
    }

    func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func readsAcrossChunkBoundaries() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", "alpha\nbeta\ngamma\n")
        let result = try lines(file)
        #expect(result.lines == ["alpha", "beta", "gamma"])
        #expect(result.offsets == [0, 6, 11])
        #expect(result.end == 17)
    }

    @Test func leavesPartialLastLineForNextScan() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", "one\ntwo\nthr")
        let first = try lines(file)
        #expect(first.lines == ["one", "two"])
        #expect(first.end == 8)
        try append(file, "ee\n")
        let second = try lines(file, from: first.end)
        #expect(second.lines == ["three"])
        #expect(second.end == 14)
    }

    @Test func readsLineLongerThanChunk() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", String(repeating: "x", count: 5000) + "\nshort\n")
        #expect(try lines(file, chunk: 1024).lines.map(\.count) == [5000, 5])
    }

    @Test func stopsWhenBodyReturnsFalse() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", "a\nb\nc\n")
        var seen: [String] = []
        try LineReader.forEachLine(url: file, from: 0) { line, _ in
            seen.append(String(decoding: line, as: UTF8.self))
            return false
        }
        #expect(seen == ["a"])
    }

    @Test func tailLinesNewestFirst() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", "first-line\nsecond\nthird\n")
        let aligned = try LineReader.tailLines(url: file, maxBytes: 14)
        #expect(aligned.map { String(decoding: $0, as: UTF8.self) } == ["third", "second"])
        let midLine = try LineReader.tailLines(url: file, maxBytes: 12)
        #expect(midLine.map { String(decoding: $0, as: UTF8.self) } == ["third"])
    }

    @Test func firstLineOnly() throws {
        let dir = try TempDir()
        let file = try dir.write("a.jsonl", "{\"type\":\"session_meta\"}\n{\"x\":1}\n")
        #expect(try LineReader.firstLine(url: file).map { String(decoding: $0, as: UTF8.self) } == "{\"type\":\"session_meta\"}")
    }

    @Test func byteSearch() {
        let data = Data(#"{"type":"custom-title","customTitle":"x"}"#.utf8)
        #expect(data.containsBytes("\"type\":\"custom-title\""))
        #expect(!data.containsBytes("bridge-session"))
        data.withUnsafeBytes { #expect($0.offset(of: "customTitle") == 24) }
    }
}
