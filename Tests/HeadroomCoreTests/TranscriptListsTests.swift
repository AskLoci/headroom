import Foundation
import SQLite3
import Testing
@testable import HeadroomCore

struct CodexThreadsTests {
    static let threadsTable = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
          first_user_message TEXT NOT NULL DEFAULT '', updated_at_ms INTEGER, preview TEXT NOT NULL DEFAULT '', name TEXT, creator_account_id TEXT)
        """

    /// Two threads that Codex committed in WAL mode and has not checkpointed.
    static let walThreads = """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        \(threadsTable);
        INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, creator_account_id) VALUES ('thread-a', '/tmp/a.jsonl', 1792000000, 1792025195, 'cli', '/Users/example/app', 'Ship the parser', 'acct-1');
        INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, creator_account_id) VALUES ('thread-b', '/tmp/b.jsonl', 1792000000, 1792025000, 'vscode', '/Users/example/auth', 'Refactor auth', 'acct-2');
        """

    /// Codex's stand-in: `/usr/bin/sqlite3` in a process of its own, since connections in one process share
    /// the -shm mapping. It keeps the database open between commands and, as the last connection,
    /// checkpoints and deletes the -wal and -shm when it quits.
    final class SQLiteShell {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()

        init(_ db: URL) throws {
            process.executableURL = URL(filePath: "/usr/bin/sqlite3")
            process.arguments = ["-bail", "-init", "/dev/null", db.fsPath]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            // Codex's SQLite deletes the -wal and -shm on close; Apple's keeps them unless persist_wal is off.
            try run(".filectrl persist_wal 0")
        }

        deinit { quit() }

        /// Returns once the shell has run the SQL; throws if it stopped on an error.
        func run(_ sql: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data("\(sql)\n.print done\n".utf8))
            var printed = ""
            while !printed.hasSuffix("done\n") {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
                printed += String(decoding: chunk, as: UTF8.self)
            }
        }

        func quit() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.waitUntilExit() }
        }

        /// Ends the process without closing the database, so the -wal and -shm stay behind.
        func crash() {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func makeDB(at url: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.fsPath, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// The database's bytes, then its -wal's and -shm's; nil for a file that does not exist.
    func files(_ db: URL) -> [Data?] {
        ["", "-wal", "-shm"].map { try? Data(contentsOf: URL(filePath: db.fsPath + $0)) }
    }

    @Test func readsCodexsOpenDatabaseWithoutWritingToIt() throws {
        let dir = try TempDir()
        let db = dir.url.appending(path: "state_5.sqlite")
        let codex = try SQLiteShell(db)
        try codex.run(Self.walThreads)
        let before = files(db)
        try #require(before[1] != nil && before[2] != nil)
        #expect(try CodexThreads.load(db: db).map(\.id).sorted() == ["thread-a", "thread-b"])
        #expect(try CodexThreads.accountIds(db: db) == ["acct-1", "acct-2"])
        #expect(files(db) == before)
        codex.quit()
    }

    @Test func readsCodexsDatabaseAfterCodexQuits() throws {
        let dir = try TempDir()
        let db = dir.url.appending(path: "state_5.sqlite")
        let codex = try SQLiteShell(db)
        try codex.run(Self.walThreads)
        codex.quit()
        let before = files(db)
        try #require(before[1] == nil && before[2] == nil)
        #expect(try CodexThreads.load(db: db).map(\.id).sorted() == ["thread-a", "thread-b"])
        #expect(try CodexThreads.accountIds(db: db) == ["acct-1", "acct-2"])
        #expect(files(db) == before)
    }

    @Test func readsCodexsDatabaseAfterCodexCrashes() throws {
        let dir = try TempDir()
        let db = dir.url.appending(path: "state_5.sqlite")
        let codex = try SQLiteShell(db)
        try codex.run(Self.walThreads)
        codex.crash()
        let before = files(db)
        try #require(before[1] != nil && before[2] != nil)
        #expect(try CodexThreads.load(db: db).map(\.id).sorted() == ["thread-a", "thread-b"])
        #expect(try CodexThreads.accountIds(db: db) == ["acct-1", "acct-2"])
        #expect(files(db) == before)
    }

    @Test func loadsUserThreadsReadOnly() throws {
        let dir = try TempDir()
        let db = dir.url.appending(path: "state_5.sqlite")
        try makeDB(at: db, [
            Self.threadsTable,
            "INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, name, updated_at_ms, creator_account_id) VALUES ('thread-a', '/tmp/a.jsonl', 1792000000, 1792025195, 'vscode', '/Users/example/app', 'ignored title', 'Ship the parser', 1792025195932, 'acct-1')",
            #"INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, creator_account_id) VALUES ('thread-b', '/tmp/b.jsonl', 1792000000, 1792025000, '{"subagent":{"other":"guardian"}}', '/Users/example/app', 'Guardian', 'acct-1')"#,
            "INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, first_user_message, archived, creator_account_id) VALUES ('thread-c', '/tmp/c.jsonl', 1791990000, 1792000000, 'cli', '/Users/example/auth', '', 'Refactor the auth module please', 1, 'acct-2')",
            "INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title) VALUES ('thread-d', '/tmp/d.jsonl', 1791000000, 1791000000, 'exec', '/Users/example', 'Old thread')",
        ])
        let threads = try CodexThreads.load(db: db).sorted { $0.id < $1.id }
        #expect(threads.map(\.id) == ["thread-a", "thread-c", "thread-d"])
        #expect(threads[0].title == "Ship the parser")
        #expect(threads[0].updatedAt == Date(timeIntervalSince1970: 1_792_025_195.932))
        #expect(threads[0].accountId == "acct-1")
        #expect(threads[1].title == "Refactor the auth module please")
        #expect(threads[1].archived)
        #expect(threads[1].updatedAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(threads[2].title == "Old thread")
        #expect(threads[2].accountId == nil)
        #expect(try CodexThreads.accountIds(db: db) == ["acct-1", "acct-2"])
    }
}

struct TranscriptListsTests {
    let a = "aaaaaaaa-0000-4000-8000-000000000000"
    let b = "bbbbbbbb-0000-4000-8000-000000000000"
    let base = Date(timeIntervalSince1970: 1_792_000_000)

    func file(_ id: String, minutesAgo: Double, scan: TranscriptScan? = nil) -> ClaudeTranscriptFile {
        ClaudeTranscriptFile(sessionId: id, url: URL(filePath: "/p/\(id).jsonl"), modified: base - minutesAgo * 60, scan: scan)
    }

    @Test func attributesAndTitlesClaudeSessions() {
        let meta = DesktopSession(accountUuid: a, orgUuid: "o", localId: "local_1", cliSessionId: "s1", title: "Desktop title",
                                  cwd: "/Users/example/My App", createdAt: base - 7200, lastActivityAt: base - 60, isArchived: true)
        var bridged = TranscriptScan()
        bridged.bridgeOwner = b
        bridged.customTitle = "Bridge title"
        var sdk = TranscriptScan()
        sdk.entrypoint = "sdk-py"
        sdk.firstTimestamp = base - 3600
        sdk.firstPrompt = "Prompt text"
        sdk.cwd = "/Users/example/site"
        var orphan = TranscriptScan()
        orphan.entrypoint = "claude-desktop"

        let lists = TranscriptLists.build(
            claude: [file("s1", minutesAgo: 30), file("s2", minutesAgo: 5, scan: bridged), file("s3", minutesAgo: 10, scan: sdk), file("s4", minutesAgo: 1, scan: orphan)],
            desktop: [meta], codex: [], codexFileExists: { _ in true },
            timeline: [CLISignIn(accountUuid: a, from: base - 86_400)], emailToAccount: [:])

        let forA = lists[Account.key(.claude, a)] ?? []
        #expect(forA.map(\.id) == ["s1", "s3"]) // s1's metadata activity (1 min ago) beats its file time (30 min ago)
        #expect(forA[0].title == "Desktop title")
        #expect(forA[0].archived)
        #expect(forA[0].project == "My App")
        #expect(forA[0].resumeCommand == nil) // Synthetic IDs must never become shell commands.
        #expect(forA[1].title == "Prompt text")
        #expect(lists[Account.key(.claude, b)]?.map(\.title) == ["Bridge title"])
        #expect(!lists.values.joined().contains { $0.id == "s4" })
    }

    @Test func keepsNewestFifteen() {
        var sdk = TranscriptScan()
        sdk.entrypoint = "sdk-py"
        sdk.firstTimestamp = base - 7200
        let files = (0..<20).map { file("s\($0)", minutesAgo: Double($0), scan: sdk) }
        let lists = TranscriptLists.build(claude: files, desktop: [], codex: [], codexFileExists: { _ in true },
                                          timeline: [CLISignIn(accountUuid: a, from: base - 86_400)], emailToAccount: [:])
        #expect(lists[Account.key(.claude, a)]?.map(\.id) == (0..<15).map { "s\($0)" })
    }

    @Test func codexListsSkipMissingRollouts() {
        let threads = [
            CodexThread(id: "t1", rolloutPath: "/r/t1.jsonl", updatedAt: base, cwd: "/Users/example/app", title: "Ship it", archived: false, accountId: "acct-1"),
            CodexThread(id: "t2", rolloutPath: "/r/missing.jsonl", updatedAt: base - 10, cwd: "", title: "", archived: false, accountId: "acct-1"),
            CodexThread(id: "t3", rolloutPath: "/r/t3.jsonl", updatedAt: base - 20, cwd: "", title: "", archived: true, accountId: "acct-1"),
            CodexThread(id: "t4", rolloutPath: "/r/t4.jsonl", updatedAt: base, cwd: "", title: "No account", archived: false, accountId: nil),
        ]
        let lists = TranscriptLists.build(claude: [], desktop: [], codex: threads, codexFileExists: { !$0.contains("missing") },
                                          timeline: [], emailToAccount: [:])
        let items = lists[Account.key(.codex, "acct-1")] ?? []
        #expect(items.map(\.id) == ["t1", "t3"])
        #expect(items[1].title == "Untitled thread")
        #expect(items[1].archived)
        #expect(items[0].resumeCommand == nil)
        #expect(lists.count == 1)
    }

    @Test func shellQuoting() {
        #expect(Shell.quote("/Users/example/app") == "/Users/example/app")
        #expect(Shell.quote("/Users/example/My App") == "'/Users/example/My App'")
        #expect(Shell.quote("/tmp/it's") == "'/tmp/it'\\''s'")
    }
}
