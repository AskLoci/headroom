import Foundation

public struct TranscriptItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: Provider
    public var accountId: String
    public var title: String
    public var cwd: String?
    public var lastActivity: Date
    public var archived: Bool
    public var fileURL: URL
    /// Set when the conversation stopped before its work was done and is not running now.
    public var unfinished: StopReason? = nil

    public var project: String {
        cwd.map { URL(filePath: $0).lastPathComponent } ?? ""
    }

    public var resumeCommand: String {
        switch provider {
        case .claude:
            guard let cwd, !cwd.isEmpty else { return "claude --resume \(id)" }
            return "cd \(Shell.quote(cwd)) && claude --resume \(id)"
        case .codex:
            return "codex resume \(id)"
        }
    }
}

public enum Shell {
    public static func quote(_ text: String) -> String {
        let safe = !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@%:,".contains($0) }
        return safe ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ClaudeTranscriptFile: Sendable, Equatable {
    public var sessionId: String
    public var url: URL
    public var modified: Date
    /// Present for transcripts without desktop metadata.
    public var scan: TranscriptScan?

    public init(sessionId: String, url: URL, modified: Date, scan: TranscriptScan?) {
        self.sessionId = sessionId
        self.url = url
        self.modified = modified
        self.scan = scan
    }
}

public enum TranscriptLists {
    public static let limit = 15

    /// Each account's most recent transcripts by last activity, keyed by `Account.key`.
    public static func build(claude files: [ClaudeTranscriptFile], desktop: [DesktopSession], codex threads: [CodexThread],
                             codexFileExists: (String) -> Bool, timeline: [CLISignIn], emailToAccount: [String: String],
                             limit: Int = TranscriptLists.limit) -> [String: [TranscriptItem]] {
        var lists: [String: [TranscriptItem]] = [:]

        var newest: [String: ClaudeTranscriptFile] = [:]
        for file in files where (newest[file.sessionId]?.modified ?? .distantPast) < file.modified {
            newest[file.sessionId] = file
        }
        let metadata = Dictionary(desktop.compactMap { session in session.cliSessionId.map { ($0, session) } },
                                  uniquingKeysWith: { lhs, rhs in (lhs.lastActivityAt ?? .distantPast) >= (rhs.lastActivityAt ?? .distantPast) ? lhs : rhs })
        for file in newest.values {
            let meta = metadata[file.sessionId]
            guard let owner = Attribution.owner(desktopAccount: meta?.accountUuid, scan: file.scan,
                                                emailToAccount: emailToAccount, timeline: timeline) else { continue }
            let title = [meta?.title, file.scan?.customTitle, file.scan?.firstPrompt]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled session"
            lists[Account.key(.claude, owner.accountUuid), default: []].append(TranscriptItem(
                id: file.sessionId, provider: .claude, accountId: owner.accountUuid, title: title,
                cwd: meta?.cwd ?? file.scan?.cwd, lastActivity: max(meta?.lastActivityAt ?? .distantPast, file.modified),
                archived: meta?.isArchived ?? false, fileURL: file.url))
        }
        for key in lists.keys {
            lists[key] = Array(lists[key]!.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
        }

        var codexCounts: [String: Int] = [:]
        for thread in threads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard let account = thread.accountId, codexCounts[account, default: 0] < limit,
                  codexFileExists(thread.rolloutPath) else { continue }
            codexCounts[account, default: 0] += 1
            lists[Account.key(.codex, account), default: []].append(TranscriptItem(
                id: thread.id, provider: .codex, accountId: account,
                title: thread.title.isEmpty ? "Untitled thread" : thread.title,
                cwd: thread.cwd.isEmpty ? nil : thread.cwd, lastActivity: thread.updatedAt,
                archived: thread.archived, fileURL: URL(filePath: thread.rolloutPath)))
        }
        return lists
    }
}
