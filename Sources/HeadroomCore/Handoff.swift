import Foundation

extension TranscriptViewer {
    /// Entries for a listed transcript, read with its provider's parser.
    public static func entries(for item: TranscriptItem) throws -> [ViewerEntry] {
        switch item.provider {
        case .claude: try claudeEntries(url: item.fileURL)
        case .codex: try codexEntries(url: item.fileURL)
        }
    }
}

/// A conversation as Markdown, to paste into a new session and continue the work there.
public enum Handoff {
    /// Characters kept on the clipboard; a saved export keeps everything.
    public static let copyLimit = 100_000

    /// The opening line of a handoff for a conversation that stopped before its work was done.
    static let continueLine = "Continue the work from this unfinished conversation."

    public static func markdown(item: TranscriptItem, entries: [ViewerEntry], lastActive: String, limit: Int? = nil) -> String {
        var lines = item.unfinished == nil ? [] : [continueLine, ""]
        lines += ["# Conversation handoff: \(item.title)", ""]
        if let cwd = item.cwd { lines.append("Project folder: \(cwd)") }
        let source = item.provider == .claude ? "Claude Code session" : "Codex thread"
        lines.append("From: \(source) \(item.id), last active \(lastActive)")
        if let reason = item.unfinished { lines.append("Stopped: \(reason.detail)") }
        lines += ["", "The conversation so far is below. Continue from its last message.", "", "---", ""]
        let header = lines.joined(separator: "\n") + "\n"

        let blocks = entries.map { block($0, clip: limit != nil) }
        var body = blocks.joined(separator: "\n\n")
        if let limit, header.count + body.count + 1 > limit {
            body = trimmed(blocks, budget: max(0, limit - header.count - 1))
        }
        return header + body + "\n"
    }

    /// The handoff built from the transcript file as it is now, so the latest turns are included.
    public static func export(item: TranscriptItem, lastActive: String, limit: Int? = nil) throws -> String {
        markdown(item: item, entries: try TranscriptViewer.entries(for: item), lastActive: lastActive, limit: limit)
    }

    /// The title without path separators, plus ".md".
    public static func fileName(for item: TranscriptItem) -> String {
        let cleaned = String(item.title.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? item.id : String(cleaned.prefix(80))) + ".md"
    }

    static func block(_ entry: ViewerEntry, clip: Bool) -> String {
        let text = clip ? TranscriptViewer.clipped(entry.text) : entry.text
        switch entry.role {
        case .user: return "**User:**\n\(text)"
        case .assistant: return "**Assistant:**\n\(text)"
        case .tool: return "`\(text)`"
        }
    }

    /// The opening block plus as many of the latest blocks as fit in `budget`, noting how many were left out.
    static func trimmed(_ blocks: [String], budget: Int) -> String {
        guard let first = blocks.first else { return "" }
        let markerRoom = 64
        var used = first.count + markerRoom
        var latest: [String] = []
        for block in blocks.dropFirst().reversed() {
            guard used + block.count + 2 <= budget else { break }
            latest.append(block)
            used += block.count + 2
        }
        latest.reverse()
        let omitted = blocks.count - 1 - latest.count
        let marker = omitted > 0 ? ["*[\(omitted) earlier messages omitted]*"] : []
        return ([first] + marker + latest).joined(separator: "\n\n")
    }
}
