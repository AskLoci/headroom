import Foundation

/// Why a conversation stopped before its work was done.
public enum StopReason: Sendable, Equatable {
    /// The account ran out of usage; carries the message the session showed.
    case usageLimit(String)
    /// An API or connection error, or a safety refusal; carries its message.
    case error(String)
    /// Stopped by the person using it.
    case interrupted
    /// The session ended before its last turn finished.
    case midTask

    /// A word or two for the transcript list, after "Unfinished · ".
    public var label: String {
        switch self {
        case .usageLimit: "usage limit"
        case .error: "error"
        case .interrupted: "interrupted"
        case .midTask: "stopped mid-task"
        }
    }

    /// One line for a handoff and a tooltip.
    public var detail: String {
        switch self {
        case .usageLimit(let message), .error(let message): message
        case .interrupted: "Interrupted by the user"
        case .midTask: "The session ended before its last turn finished"
        }
    }
}

/// How a transcript's last turn ended.
public enum ConversationEnd: Sendable, Equatable {
    case finished
    case stopped(StopReason)
    /// The last turn has not ended: its session is still working, or went away partway through.
    case unended

    /// How a listed transcript ends, read with its provider's rules.
    public static func read(_ item: TranscriptItem) throws -> ConversationEnd {
        switch item.provider {
        case .claude: try claude(url: item.fileURL)
        case .codex: try codex(url: item.fileURL)
        }
    }

    /// The newest user or assistant entry of a Claude Code transcript decides. Meta, sidechain and
    /// compaction entries and slash-command markup are passed over. A tool result is judged by its call:
    /// a `StructuredOutput` call is how an SDK run ends.
    public static func claude(url: URL, window: Int = 64 << 10) throws -> ConversationEnd {
        try widening(url: url, window: window) { lines, complete in
            let decoder = JSONDecoder()
            var awaitingCall = false
            for line in lines where line.containsBytes("\"type\":\"user\"") || line.containsBytes("\"type\":\"assistant\"") {
                guard let parsed = try? decoder.decode(ClaudeEndLine.self, from: line), let kind = parsed.kind else { continue }
                if awaitingCall {
                    switch kind {
                    case .result: continue
                    case .call(let names): return names.contains("StructuredOutput") ? .finished : .unended
                    default: return .unended
                    }
                }
                switch kind {
                case .reply: return .finished
                case .stop(let reason): return .stopped(reason)
                case .call, .open: return .unended
                case .result: awaitingCall = true
                }
            }
            guard complete else { return nil }
            return awaitingCall ? .unended : .finished
        }
    }

    /// The newest turn event of a Codex rollout decides; a failed turn completes with an `error`.
    public static func codex(url: URL, window: Int = 64 << 10) throws -> ConversationEnd {
        try widening(url: url, window: window) { lines, complete in
            let decoder = JSONDecoder()
            for line in lines where line.containsBytes("\"task_complete\"") || line.containsBytes("\"turn_aborted\"")
                || line.containsBytes("\"task_started\"") {
                guard let parsed = try? decoder.decode(CodexTurnLine.self, from: line), parsed.type == "event_msg" else { continue }
                switch parsed.payload?.type {
                case "task_complete":
                    guard let failure = parsed.payload?.error?.value else { return .finished }
                    let message = TextCleaning.oneLine(failure.message ?? "", max: 300)
                    return .stopped(failure.codexErrorInfo?.value == "usage_limit_exceeded" ? .usageLimit(message) : .error(message))
                case "turn_aborted": return .stopped(.interrupted)
                case "task_started": return .unended
                default: continue
                }
            }
            return complete ? .finished : nil
        }
    }

    /// Calls `decide` with the complete lines in the last `window` bytes, newest first, doubling the
    /// window until it decides. `complete` is true once the window covers the whole file.
    static func widening(url: URL, window: Int, _ decide: ([Data], Bool) -> ConversationEnd?) throws -> ConversationEnd {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var window = max(window, 1)
        while true {
            let complete = window >= size
            if let end = decide(try LineReader.tailLines(url: url, maxBytes: window), complete) { return end }
            if complete { return .finished }
            window *= 2
        }
    }
}

extension TranscriptItem {
    /// Why this conversation is unfinished, or nil when it finished or may still be running. Claude
    /// sessions report whether they are running; Codex records no running turn, so an open Codex turn
    /// is taken to be running.
    public func unfinishedReason(end: ConversationEnd, workingClaudeSessions: Set<String>) -> StopReason? {
        let working = provider == .claude ? workingClaudeSessions.contains(id) : nil
        switch end {
        case .finished: return nil
        case .stopped(let reason): return working == true ? nil : reason
        case .unended: return working == false ? .midTask : nil
        }
    }
}

/// Claude Code's registry of running sessions: `~/.claude/sessions/<pid>.json`.
public enum LiveSessions {
    struct Record: Decodable {
        let pid: Int32?
        let sessionId: String?
        let status: String?
    }

    /// Ids of sessions whose process is running and not idle.
    public static func working(in directory: URL, isRunning: (Int32) -> Bool) -> Set<String> {
        let decoder = JSONDecoder()
        var ids = Set<String>()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.fsPath)) ?? [] where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let record = try? decoder.decode(Record.self, from: data),
                  let pid = record.pid, let id = record.sessionId, record.status != "idle", isRunning(pid)
            else { continue }
            ids.insert(id)
        }
        return ids
    }
}

/// A field read as nil, instead of failing the whole line, when it has a different shape.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct ClaudeEndLine: Decodable {
    struct Message: Decodable {
        let content: MessageContent?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    enum Kind {
        case reply, stop(StopReason), call([String]), result, open
    }

    let type: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let isCompactSummary: Bool?
    let isApiErrorMessage: Bool?
    let interruptedByShutdown: Bool?
    let error: Lenient<String>?
    let message: Message?

    /// What this entry says about the turn, or nil when it does not count.
    var kind: Kind? {
        guard isMeta != true, isSidechain != true, isCompactSummary != true, let content = message?.content else { return nil }
        switch type {
        case "assistant":
            if isApiErrorMessage == true {
                let text = TextCleaning.oneLine(content.texts.joined(separator: " "), max: 300)
                return .stop(error?.value == "rate_limit" ? .usageLimit(text) : .error(text))
            }
            switch message?.stopReason {
            case "end_turn", "stop_sequence": return .reply
            case "refusal": return .stop(.error("Stopped by the model's safeguards"))
            default: return .call(content.blocks.compactMap { $0.type == "tool_use" ? $0.name : nil })
            }
        case "user":
            let texts = content.texts.map { TextCleaning.stripSystemReminders($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if texts.contains(where: { $0.hasPrefix("[Request interrupted by user") }) {
                return .stop(interruptedByShutdown == true ? .midTask : .interrupted)
            }
            if content.blocks.contains(where: { $0.type == "tool_result" }) { return .result }
            if texts.contains(where: { !$0.isEmpty && !TextCleaning.isWrapperMarkup($0) }) { return .open }
            return content.blocks.contains { $0.type == "image" || $0.type == "document" } ? .open : nil
        default:
            return nil
        }
    }
}

struct CodexTurnLine: Decodable {
    struct Payload: Decodable {
        struct Failure: Decodable {
            let message: String?
            let codexErrorInfo: Lenient<String>?

            enum CodingKeys: String, CodingKey {
                case message
                case codexErrorInfo = "codex_error_info"
            }
        }

        let type: String?
        let error: Lenient<Failure>?
    }

    let type: String?
    let payload: Payload?
}
