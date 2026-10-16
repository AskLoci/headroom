import Foundation

public enum ViewerRole: String, Sendable {
    case user, assistant, tool
}

public struct ViewerEntry: Sendable, Equatable, Identifiable {
    public var id: Int
    public var role: ViewerRole
    public var text: String
}

/// User and assistant text in order, with each tool call as one line. Meta lines, system reminders,
/// tool results, reasoning and instruction preambles are left out.
public enum TranscriptViewer {
    /// Characters of one entry shown in the viewer and kept in a copied handoff; a saved export keeps all.
    public static let maxEntryLength = 12_000

    public static func clipped(_ text: String) -> String {
        text.count > maxEntryLength ? String(text.prefix(maxEntryLength)) + "…" : text
    }

    struct ClaudeLine: Decodable {
        struct Message: Decodable { let content: MessageContent? }
        let type: String?
        let isMeta: Bool?
        let isSidechain: Bool?
        let message: Message?
    }

    public static func claudeEntries(url: URL) throws -> [ViewerEntry] {
        var builder = EntryBuilder()
        let decoder = JSONDecoder()
        try LineReader.forEachLine(url: url, from: 0) { line, _ in
            let isUser = line.containsBytes("\"type\":\"user\"")
            let isAssistant = line.containsBytes("\"type\":\"assistant\"")
            guard isUser || isAssistant else { return true }
            if isUser, !isAssistant, line.containsBytes("\"tool_use_id\"") { return true }
            guard let parsed = try? decoder.decode(ClaudeLine.self, from: Data(line)), parsed.isMeta != true,
                  parsed.isSidechain != true, let content = parsed.message?.content
            else { return true }
            switch parsed.type {
            case "user":
                for text in content.texts {
                    let cleaned = TextCleaning.stripSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty, !TextCleaning.isWrapperMarkup(cleaned) { builder.add(.user, cleaned) }
                }
            case "assistant":
                for block in content.blocks {
                    if block.type == "text", let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        builder.add(.assistant, text)
                    } else if block.type == "tool_use" {
                        builder.add(.tool, toolLine(block.name ?? "Tool", block.input?.summary))
                    }
                }
            default:
                break
            }
            return true
        }
        return builder.entries
    }

    public static func codexEntries(url: URL) throws -> [ViewerEntry] {
        var builder = EntryBuilder()
        let decoder = JSONDecoder()
        try LineReader.forEachLine(url: url, from: 0) { line, _ in
            guard line.containsBytes("\"item_completed\""),
                  let parsed = try? decoder.decode(CodexLine.self, from: Data(line)),
                  parsed.type == "event_msg", parsed.payload?.type == "item_completed", let item = parsed.payload?.item
            else { return true }
            let kind = item.type ?? ""
            switch kind {
            case "UserMessage", "AgentMessage":
                let text = item.texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { builder.add(kind == "UserMessage" ? .user : .assistant, text) }
            case "", "Reasoning", "ContextCompaction":
                break
            default:
                builder.add(.tool, item.summary ?? kind)
            }
            return true
        }
        return builder.entries
    }

    static func toolLine(_ name: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return name }
        return "\(name): \(TextCleaning.oneLine(detail, max: 160))"
    }

    struct EntryBuilder {
        var entries: [ViewerEntry] = []

        mutating func add(_ role: ViewerRole, _ text: String) {
            entries.append(ViewerEntry(id: entries.count, role: role, text: text))
        }
    }

    struct CodexLine: Decodable {
        struct Payload: Decodable {
            let type: String?
            let item: CodexItem?
        }
        let type: String?
        let payload: Payload?
    }

    /// One completed Codex item, read leniently because item shapes vary by type.
    struct CodexItem: Decodable {
        var type: String?
        var texts: [String] = []
        var summary: String?

        struct Part: Decodable { let text: String? }
        struct Ignored: Decodable { init(from decoder: Decoder) throws {} }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ToolInput.Key.self)
            func string(_ key: String) -> String? { try? container.decodeIfPresent(String.self, forKey: ToolInput.Key(key)) }
            type = string("type")
            texts = (try? container.decodeIfPresent([Part].self, forKey: ToolInput.Key("content")))?.compactMap(\.text) ?? []
            switch type {
            case "McpToolCall":
                let arguments = try? container.decodeIfPresent(ToolInput.self, forKey: ToolInput.Key("arguments"))
                let name = [string("server"), string("tool")].compactMap { $0 }.joined(separator: ".")
                summary = TranscriptViewer.toolLine(name.isEmpty ? "Tool" : name, arguments?.summary)
            case "CommandExecution":
                let argv = try? container.decodeIfPresent([String].self, forKey: ToolInput.Key("command"))
                summary = TranscriptViewer.toolLine("Shell", argv?.last ?? string("command"))
            case "FileChange":
                let changes = (try? container.decodeIfPresent([String: Ignored].self, forKey: ToolInput.Key("changes"))) ?? [:]
                let names = changes.keys.map { URL(filePath: $0).lastPathComponent }.sorted()
                summary = TranscriptViewer.toolLine("Edited", names.joined(separator: ", "))
            case "Extension":
                summary = TranscriptViewer.toolLine(string("kind") ?? "Extension", string("query"))
            case "ImageView":
                summary = TranscriptViewer.toolLine("Viewed image", string("path").map { URL(string: $0)?.lastPathComponent ?? $0 })
            case "SubAgentActivity":
                summary = TranscriptViewer.toolLine("Subagent", string("agent_path"))
            default:
                summary = nil
            }
        }
    }
}
