import Foundation

/// What Headroom needs from a Claude transcript to list it: owner hints, a title, and where to resume.
public struct TranscriptScan: Sendable, Equatable {
    public var entrypoint: String?
    public var cwd: String?
    public var firstTimestamp: Date?
    public var bridgeOwner: String?
    public var injectedEmail: String?
    public var customTitle: String?
    public var firstPrompt: String?
    /// Offset just past the last complete line read.
    public var scannedBytes: UInt64 = 0

    public init() {}
}

public enum TranscriptScanner {
    struct HeadLine: Decodable {
        let timestamp: String?
        let entrypoint: String?
        let cwd: String?
    }

    struct BridgeLine: Decodable { let ownerAccountUuid: String? }
    struct TitleLine: Decodable { let customTitle: String? }

    struct UserLine: Decodable {
        struct Message: Decodable { let content: MessageContent? }
        let type: String?
        let isMeta: Bool?
        let message: Message?
    }

    /// Scans from `resume.scannedBytes` to the last complete line, carrying earlier findings forward.
    /// Lines are only decoded when a byte prefilter says they can matter.
    public static func scan(url: URL, resume: TranscriptScan = TranscriptScan(), chunkSize: Int = 1 << 20) throws -> TranscriptScan {
        var scan = resume
        let decoder = JSONDecoder()
        let end = try LineReader.forEachLine(url: url, from: resume.scannedBytes, chunkSize: chunkSize) { line, _ in
            if scan.firstTimestamp == nil || scan.entrypoint == nil, line.containsBytes("\"timestamp\":\""),
               let head = try? decoder.decode(HeadLine.self, from: Data(line)) {
                if scan.firstTimestamp == nil { scan.firstTimestamp = head.timestamp.flatMap(ISODate.parse) }
                if scan.entrypoint == nil, let entrypoint = head.entrypoint {
                    scan.entrypoint = entrypoint
                    scan.cwd = head.cwd
                }
            }
            if scan.bridgeOwner == nil, line.containsBytes("\"type\":\"bridge-session\"") {
                scan.bridgeOwner = (try? decoder.decode(BridgeLine.self, from: Data(line)))?.ownerAccountUuid
            }
            if line.containsBytes("\"type\":\"custom-title\""),
               let title = (try? decoder.decode(TitleLine.self, from: Data(line)))?.customTitle, !title.isEmpty {
                scan.customTitle = title
            }
            if scan.injectedEmail == nil {
                scan.injectedEmail = injectedEmail(in: line)
            }
            if scan.firstPrompt == nil, line.containsBytes("\"type\":\"user\"") {
                scan.firstPrompt = prompt(in: Data(line), decoder: decoder)
            }
            return true
        }
        scan.scannedBytes = end
        return scan
    }

    /// The first `The user's email address is …` line within the first `maxBytes`.
    public static func firstInjectedEmail(url: URL, maxBytes: UInt64 = 4 << 20) -> String? {
        var email: String?
        _ = try? LineReader.forEachLine(url: url, from: 0) { line, start in
            email = injectedEmail(in: line)
            return email == nil && start < maxBytes
        }
        return email
    }

    static func injectedEmail(in line: UnsafeRawBufferPointer) -> String? {
        let phrase: StaticString = "The user's email address is "
        guard let at = line.offset(of: phrase) else { return nil }
        let start = at + phrase.utf8CodeUnitCount
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<min(line.count, start + 320)]), as: UTF8.self)
        guard let match = text.firstMatch(of: /^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) else { return nil }
        return String(match.output).lowercased()
    }

    static func prompt(in data: Data, decoder: JSONDecoder) -> String? {
        guard let line = try? decoder.decode(UserLine.self, from: data), line.type == "user", line.isMeta != true,
              let content = line.message?.content
        else { return nil }
        for text in content.texts {
            let cleaned = TextCleaning.stripSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || TextCleaning.isWrapperMarkup(cleaned) { continue }
            return TextCleaning.oneLine(cleaned, max: 80)
        }
        return nil
    }
}

/// A Claude message's `content`: a plain string or a list of blocks.
enum MessageContent: Decodable {
    case text(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .blocks((try? container.decode([ContentBlock].self)) ?? [])
        }
    }

    var texts: [String] {
        switch self {
        case .text(let string): [string]
        case .blocks(let blocks): blocks.compactMap { $0.type == "text" ? $0.text : nil }
        }
    }

    var blocks: [ContentBlock] {
        switch self {
        case .text(let string): [ContentBlock(type: "text", text: string, name: nil, input: nil)]
        case .blocks(let blocks): blocks
        }
    }
}

struct ContentBlock: Decodable {
    let type: String?
    let text: String?
    let name: String?
    let input: ToolInput?
}

/// The one string that best describes a tool call's input, read leniently from any object.
struct ToolInput: Decodable {
    let summary: String?

    struct Key: CodingKey {
        let stringValue: String
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    static let preferredKeys = ["description", "command", "file_path", "pattern", "query", "url", "skill", "prompt", "title", "path"]

    init(from decoder: Decoder) throws {
        var found: String?
        if let container = try? decoder.container(keyedBy: Key.self) {
            for key in Self.preferredKeys {
                if let value = try? container.decodeIfPresent(String.self, forKey: Key(key)), !value.isEmpty {
                    found = value
                    break
                }
            }
        }
        summary = found
    }
}
