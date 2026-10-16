import Foundation

extension UnsafeRawBufferPointer {
    public func containsBytes(_ needle: StaticString) -> Bool {
        offset(of: needle) != nil
    }

    /// Byte offset of the first occurrence of `needle`, found with memmem.
    public func offset(of needle: StaticString) -> Int? {
        guard let base = baseAddress, count > 0 else { return nil }
        return needle.withUTF8Buffer { pattern -> Int? in
            guard let hit = memmem(base, count, pattern.baseAddress, pattern.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }
}

extension Data {
    public func containsBytes(_ needle: StaticString) -> Bool {
        withUnsafeBytes { $0.containsBytes(needle) }
    }
}

public enum LineReader {
    /// Calls `body` with each complete line (without its newline) and the file offset where it starts,
    /// beginning at `offset`. Returns the offset just past the last complete line; a trailing line with
    /// no newline yet is left for the next call. `body` returns false to stop early.
    @discardableResult
    public static func forEachLine(url: URL, from offset: UInt64, chunkSize: Int = 1 << 20,
                                   _ body: (UnsafeRawBufferPointer, UInt64) throws -> Bool) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var pending: [UInt8] = []
        var chunkOffset = offset
        var lineStart = offset
        var stopped = false
        while !stopped {
            // FileHandle returns autoreleased buffers; a pool per chunk keeps a long scan on a
            // background thread from holding every chunk it has read until the scan ends.
            let readMore = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var start = 0
                    while start < raw.count {
                        guard let hit = memchr(base + start, 0x0A, raw.count - start) else {
                            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[start...]))
                            return
                        }
                        let end = base.distance(to: UnsafeRawPointer(hit))
                        let keepGoing: Bool
                        if pending.isEmpty {
                            keepGoing = try body(UnsafeRawBufferPointer(rebasing: raw[start..<end]), lineStart)
                        } else {
                            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[start..<end]))
                            keepGoing = try pending.withUnsafeBytes { try body($0, lineStart) }
                            pending.removeAll(keepingCapacity: true)
                        }
                        start = end + 1
                        lineStart = chunkOffset + UInt64(start)
                        if !keepGoing {
                            stopped = true
                            return
                        }
                    }
                }
                chunkOffset += UInt64(chunk.count)
                return true
            }
            if !readMore { break }
        }
        return lineStart
    }

    /// Complete lines within the last `maxBytes` of the file, newest first.
    public static func tailLines(url: URL, maxBytes: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0 {
            // Drop the line the window starts inside.
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = Data(data[(newline + 1)...])
        }
        guard let last = data.lastIndex(of: 0x0A) else { return [] }
        data = Data(data[...last])
        return data.split(separator: 0x0A).reversed().map { Data($0) }
    }

    public static func firstLine(url: URL) throws -> Data? {
        var first: Data?
        try forEachLine(url: url, from: 0) { line, _ in
            first = Data(line)
            return false
        }
        return first
    }
}
