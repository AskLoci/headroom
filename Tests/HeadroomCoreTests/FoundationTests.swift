import Foundation
import Testing
@testable import HeadroomCore

struct ISODateTests {
    @Test func parsesMicrosecondsWithOffset() {
        let parsed = ISODate.parse("2026-10-16T22:00:00.399846+00:00")!
        #expect(abs(parsed.timeIntervalSince1970 - 1_792_188_000.399846) < 0.0001)
    }

    @Test func parsesMillisecondsZulu() {
        let parsed = ISODate.parse("2026-10-14T23:27:10.501Z")!
        #expect(abs(parsed.timeIntervalSince1970 - 1_792_020_430.501) < 0.0001)
    }

    @Test func parsesNegativeOffsetWithoutFraction() {
        #expect(ISODate.parse("2026-10-14T19:27:10-04:00")!.timeIntervalSince1970 == 1_792_020_430)
    }

    @Test func parsesWholeSecondsZulu() {
        #expect(ISODate.parse("2026-10-18T21:00:00Z")!.timeIntervalSince1970 == 1_792_357_200)
    }

    @Test(arguments: ["", "yesterday", "2026-13-01T00:00:00Z", "2026-10-14T23:27:10.Z", "2026-10-14T23:27:10+0400x"])
    func rejectsMalformed(_ input: String) {
        #expect(ISODate.parse(input) == nil)
    }
}

struct TextCleaningTests {
    @Test func stripsSystemReminders() {
        let text = "<system-reminder>\nctx\n</system-reminder>\nAdd a toggle<system-reminder>x</system-reminder>"
        #expect(TextCleaning.stripSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines) == "Add a toggle")
    }

    @Test func detectsWrapperMarkup() {
        #expect(TextCleaning.isWrapperMarkup("<command-name>/clear</command-name>"))
        #expect(TextCleaning.isWrapperMarkup("<local-command-stdout>ok</local-command-stdout>"))
        #expect(!TextCleaning.isWrapperMarkup("<div> is an HTML tag"))
        #expect(!TextCleaning.isWrapperMarkup("Plain request"))
    }

    @Test func oneLineCollapsesAndTruncates() {
        #expect(TextCleaning.oneLine("a\n\n  b\tc", max: 80) == "a b c")
        let cut = TextCleaning.oneLine(String(repeating: "x", count: 100), max: 80)
        #expect(cut.count == 80)
        #expect(cut.hasSuffix("…"))
    }
}

struct AccountTests {
    @Test func displayNameFallsBackToShortId() {
        let account = Account(provider: .codex, id: "cccccccc-0000-4000-8000-000000000000", firstSeen: .now, lastSeen: .now)
        #expect(account.displayName == "Codex account cccccccc")
        #expect(account.key == "codex:cccccccc-0000-4000-8000-000000000000")
    }
}

struct HeadroomPathsTests {
    let paths = HeadroomPaths(home: URL(filePath: "/Users/example", directoryHint: .isDirectory))

    @Test func rootsHangOffHome() {
        #expect(paths.claudeConfig.fsPath == "/Users/example/Library/Application Support/Claude/config.json")
        #expect(paths.claudeProjects.fsPath == "/Users/example/.claude/projects")
        #expect(paths.codexStateDB.fsPath == "/Users/example/.codex/state_5.sqlite")
        #expect(paths.stateFile.fsPath == "/Users/example/Library/Application Support/Headroom/state.json")
    }

    @Test func relevantPathsOnly() {
        #expect(paths.isRelevant("/Users/example/.claude/projects/-Users-example-app/abc.jsonl"))
        #expect(paths.isRelevant("/Users/example/Library/Application Support/Claude/config.json"))
        #expect(paths.isRelevant("/Users/example/Library/Application Support/Claude/plan-usage-history.json"))
        #expect(paths.isRelevant("/Users/example/Library/Application Support/Claude/claude-code-sessions/a/o/local_1.json"))
        #expect(!paths.isRelevant("/Users/example/Library/Application Support/Claude/IndexedDB/x.log"))
        #expect(paths.isRelevant("/Users/example/.codex/auth.json"))
        #expect(paths.isRelevant("/Users/example/.codex/state_5.sqlite-wal"))
        #expect(paths.isRelevant("/Users/example/.codex/sessions/2026/10/14/rollout-x.jsonl"))
        #expect(!paths.isRelevant("/Users/example/.codex/logs_2.sqlite-wal"))
        #expect(paths.isRelevant("/Users/example/Library/Keychains/login.keychain-db"))
        #expect(!paths.isRelevant("/Users/example/Library/Keychains/metadata.keychain-db"))
        #expect(paths.isRelevant("/Users/example/.claude/sessions/10743.json"))
        #expect(!paths.isRelevant("/Users/example/.claude/sessions/10743.45b99de0.key"))
    }

    @Test func nestedSubagentTranscriptsAreIgnored() {
        let nested = "/Users/example/.claude/projects/-Users-example-app/abc/subagents/agent-1.jsonl"
        #expect(!paths.isRelevant(nested))
        #expect(!paths.isTranscriptSource(nested))
        #expect(paths.isTranscriptSource("/Users/example/.claude/projects/-Users-example-app/abc.jsonl"))
    }

    @Test func transcriptSourcesAreTold() {
        #expect(paths.isTranscriptSource("/Users/example/.claude/projects/-Users-example-app/abc.jsonl"))
        #expect(paths.isTranscriptSource("/Users/example/Library/Application Support/Claude/claude-code-sessions/a/o/local_1.json"))
        #expect(paths.isTranscriptSource("/Users/example/.codex/sessions/2026/10/14/rollout-x.jsonl"))
        #expect(paths.isTranscriptSource("/Users/example/.codex/state_5.sqlite-wal"))
        #expect(paths.isTranscriptSource("/Users/example/.claude/sessions/10743.json"))
        #expect(!paths.isTranscriptSource("/Users/example/Library/Application Support/Claude/config.json"))
        #expect(!paths.isTranscriptSource("/Users/example/.codex/auth.json"))
        #expect(!paths.isTranscriptSource("/Users/example/Library/Keychains/login.keychain-db"))
    }
}
