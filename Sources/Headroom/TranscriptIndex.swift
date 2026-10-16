import Foundation
import HeadroomCore

struct IndexSnapshot: Sendable {
    var lists: [String: [TranscriptItem]] = [:]
    var accountOrgs: [String: Set<String>] = [:]
    var activity: UsageSamples.Activity = [:]
    var codexAccountIds: [String] = []
}

/// Keeps parsed desktop metadata, transcript scans and Codex threads between refreshes and re-reads
/// only files whose modification time or size changed.
actor TranscriptIndex {
    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    private let paths: HeadroomPaths
    private var metadata: [String: (stamp: Stamp, session: DesktopSession)] = [:]
    private var scans: [String: (stamp: Stamp, scan: TranscriptScan)] = [:]
    private var ends: [String: (stamp: Stamp, end: ConversationEnd)] = [:]
    private var transcriptURLs: [String: URL] = [:]
    private var codexThreads: [CodexThread] = []
    private var codexAccounts: [String] = []
    private var codexStamp: Stamp?

    init(paths: HeadroomPaths) {
        self.paths = paths
    }

    func refresh(timeline: [CLISignIn], emailToAccount: [String: String]) -> IndexSnapshot {
        let desktop = refreshMetadata()
        let files = refreshClaudeFiles(covered: Set(desktop.compactMap(\.cliSessionId)))
        refreshCodex()
        let lists = markUnfinished(TranscriptLists.build(claude: files, desktop: desktop, codex: codexThreads,
                                                         codexFileExists: { FileManager.default.fileExists(atPath: $0) },
                                                         timeline: timeline, emailToAccount: emailToAccount))
        return IndexSnapshot(lists: lists, accountOrgs: DesktopSessions.accountOrgs(root: paths.desktopSessions),
                             activity: activity(desktop), codexAccountIds: codexAccounts)
    }

    /// Injected-email votes from each account's newest desktop transcripts.
    func emailVotes(for accounts: Set<String>, perAccount: Int) -> [(account: String, email: String)] {
        let sessions = metadata.values.map(\.session).filter { accounts.contains($0.accountUuid) }
        var votes: [(account: String, email: String)] = []
        for (account, owned) in Dictionary(grouping: sessions, by: \.accountUuid) {
            let newest = owned.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }.prefix(perAccount)
            for session in newest {
                guard let id = session.cliSessionId, let url = transcriptURLs[id],
                      let email = TranscriptScanner.firstInjectedEmail(url: url) else { continue }
                votes.append((account, email))
            }
        }
        return votes
    }

    private func refreshMetadata() -> [DesktopSession] {
        var sessions: [DesktopSession] = []
        var seen = Set<String>()
        var archivedByOrg: [String: Set<String>] = [:]
        for file in DesktopSessions.metadataFiles(root: paths.desktopSessions) {
            seen.insert(file.url.fsPath)
            guard var session = autoreleasepool(invoking: { cachedSession(file) }) else { continue }
            let orgDir = file.url.deletingLastPathComponent()
            let archived = archivedByOrg[orgDir.fsPath] ?? DesktopSessions.archivedIds(orgDir: orgDir)
            archivedByOrg[orgDir.fsPath] = archived
            if archived.contains(session.localId) { session.isArchived = true }
            sessions.append(session)
        }
        metadata = metadata.filter { seen.contains($0.key) }
        return sessions
    }

    /// The parsed session file, re-read only when its modification time or size changed.
    private func cachedSession(_ file: DesktopSessions.MetadataFile) -> DesktopSession? {
        let path = file.url.fsPath
        guard let stamp = stamp(file.url) else { return nil }
        if let cached = metadata[path], cached.stamp == stamp { return cached.session }
        guard let data = try? Data(contentsOf: file.url),
              let parsed = try? DesktopSessions.parse(data, accountUuid: file.accountUuid, orgUuid: file.orgUuid,
                                                      fileStem: file.url.deletingPathExtension().lastPathComponent)
        else { return nil }
        metadata[path] = (stamp, parsed)
        return parsed
    }

    private func refreshClaudeFiles(covered: Set<String>) -> [ClaudeTranscriptFile] {
        var files: [ClaudeTranscriptFile] = []
        var seen = Set<String>()
        var newest: [String: (url: URL, modified: Date)] = [:]
        for project in (try? FileManager.default.contentsOfDirectory(at: paths.claudeProjects, includingPropertiesForKeys: nil)) ?? [] {
            autoreleasepool {
                let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for url in entries where url.pathExtension == "jsonl" {
                    guard let stamp = stamp(url) else { continue }
                    let sessionId = url.deletingPathExtension().lastPathComponent
                    let path = url.fsPath
                    seen.insert(path)
                    if (newest[sessionId]?.modified ?? .distantPast) < stamp.modified { newest[sessionId] = (url, stamp.modified) }
                    var scan: TranscriptScan?
                    if !covered.contains(sessionId) {
                        if let cached = scans[path], cached.stamp == stamp {
                            scan = cached.scan
                        } else {
                            let resume = scans[path].flatMap { $0.stamp.size <= stamp.size ? $0.scan : nil } ?? TranscriptScan()
                            scan = (try? TranscriptScanner.scan(url: url, resume: resume)) ?? scans[path]?.scan
                            if let scan { scans[path] = (stamp, scan) }
                        }
                    }
                    files.append(ClaudeTranscriptFile(sessionId: sessionId, url: url, modified: stamp.modified, scan: scan))
                }
            }
        }
        scans = scans.filter { seen.contains($0.key) }
        transcriptURLs = newest.mapValues { $0.url }
        return files
    }

    /// Marks listed conversations that stopped before their work was done. Each transcript's ending is
    /// re-read only when the file changes; which Claude sessions are working is read every time.
    private func markUnfinished(_ lists: [String: [TranscriptItem]]) -> [String: [TranscriptItem]] {
        let working = LiveSessions.working(in: paths.claudeSessions) { kill($0, 0) == 0 || errno == EPERM }
        var seen = Set<String>()
        let marked = lists.mapValues { items in
            items.map { item in
                var item = item
                seen.insert(item.fileURL.fsPath)
                if let end = autoreleasepool(invoking: { cachedEnd(item) }) {
                    item.unfinished = item.unfinishedReason(end: end, workingClaudeSessions: working)
                }
                return item
            }
        }
        ends = ends.filter { seen.contains($0.key) }
        return marked
    }

    private func cachedEnd(_ item: TranscriptItem) -> ConversationEnd? {
        let path = item.fileURL.fsPath
        guard let stamp = stamp(item.fileURL) else { return nil }
        if let cached = ends[path], cached.stamp == stamp { return cached.end }
        guard let end = try? ConversationEnd.read(item) else { return nil }
        ends[path] = (stamp, end)
        return end
    }

    private func refreshCodex() {
        let database = paths.codexStateDB
        let wal = URL(filePath: database.fsPath + "-wal")
        guard let current = [stamp(database), stamp(wal)].compactMap({ $0 }).max(by: { $0.modified < $1.modified }),
              current != codexStamp else { return }
        do {
            codexThreads = try CodexThreads.load(db: database)
            codexAccounts = try CodexThreads.accountIds(db: database)
            codexStamp = current
        } catch {
            Log.write("Codex threads unreadable: \(error)")
        }
    }

    private func activity(_ sessions: [DesktopSession]) -> UsageSamples.Activity {
        var result: UsageSamples.Activity = [:]
        for session in sessions {
            guard let start = session.createdAt ?? session.lastActivityAt,
                  let end = session.lastActivityAt ?? session.createdAt else { continue }
            result[session.accountUuid, default: []].append(min(start, end)...max(start, end))
        }
        return result
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return Stamp(modified: modified, size: size)
    }
}
