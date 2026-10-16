import Foundation

extension URL {
    /// The file-system path without a trailing slash.
    public var fsPath: String {
        let raw = path(percentEncoded: false)
        return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}

/// Every file root Headroom reads or writes, derived from one home directory so tests can point it anywhere.
public struct HeadroomPaths: Sendable {
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    public static var current: HeadroomPaths {
        HeadroomPaths(home: URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory))
    }

    public var claudeSupport: URL { home.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory) }
    public var claudeConfig: URL { claudeSupport.appending(path: "config.json") }
    public var planUsageHistory: URL { claudeSupport.appending(path: "plan-usage-history.json") }
    public var desktopSessions: URL { claudeSupport.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
    public var claudeProjects: URL { home.appending(path: ".claude/projects", directoryHint: .isDirectory) }
    public var claudeSessions: URL { home.appending(path: ".claude/sessions", directoryHint: .isDirectory) }
    public var claudeJSON: URL { home.appending(path: ".claude.json") }
    public var claudeCredentialsFile: URL { home.appending(path: ".claude/.credentials.json") }
    public var codexHome: URL { home.appending(path: ".codex", directoryHint: .isDirectory) }
    public var codexAuth: URL { codexHome.appending(path: "auth.json") }
    public var codexSessions: URL { codexHome.appending(path: "sessions", directoryHint: .isDirectory) }
    public var codexStateDB: URL { codexHome.appending(path: "state_5.sqlite") }
    public var keychainsDir: URL { home.appending(path: "Library/Keychains", directoryHint: .isDirectory) }
    public var headroomSupport: URL { home.appending(path: "Library/Application Support/Headroom", directoryHint: .isDirectory) }
    public var stateFile: URL { headroomSupport.appending(path: "state.json") }
    public var logFile: URL { home.appending(path: "Library/Logs/Headroom.log") }

    /// Whether a changed path can affect sign-ins, readings or transcript lists.
    public func isRelevant(_ path: String) -> Bool {
        func under(_ dir: URL) -> Bool { path.hasPrefix(dir.fsPath + "/") }
        if under(claudeProjects) { return isTopLevelTranscript(path) }
        if under(claudeSessions) { return path.hasSuffix(".json") }
        if under(codexSessions) { return path.hasSuffix(".jsonl") }
        if under(desktopSessions) { return true }
        if [claudeConfig, planUsageHistory, codexAuth].contains(where: { $0.fsPath == path }) { return true }
        if path.hasPrefix(codexStateDB.fsPath) { return true }
        if under(keychainsDir) { return path.contains("login.keychain") }
        return false
    }

    /// Whether a changed path only affects transcript lists (not sign-ins or readings).
    public func isTranscriptSource(_ path: String) -> Bool {
        func under(_ dir: URL) -> Bool { path.hasPrefix(dir.fsPath + "/") }
        return isTopLevelTranscript(path) || under(desktopSessions) || under(codexSessions) || path.hasPrefix(codexStateDB.fsPath)
            || (under(claudeSessions) && path.hasSuffix(".json"))
    }

    /// `~/.claude/projects/<project>/<session>.jsonl`; subagent transcripts sit deeper and are never listed.
    func isTopLevelTranscript(_ path: String) -> Bool {
        let prefix = claudeProjects.fsPath + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".jsonl") else { return false }
        return path.dropFirst(prefix.count).split(separator: "/").count == 2
    }
}
