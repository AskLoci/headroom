import Foundation
import Testing
@testable import HeadroomCore

struct HandoffTests {
    func item(_ provider: Provider = .claude) -> TranscriptItem {
        TranscriptItem(id: "sess-1", provider: provider, accountId: "a", title: "Dark mode toggle", cwd: "/Users/example/Code/app",
                       lastActivity: date("2026-10-14T20:40:00Z"), archived: false, fileURL: URL(filePath: "/p/sess-1.jsonl"))
    }

    @Test func fullExportHasHeaderAndEveryEntry() {
        let entries = [ViewerEntry(id: 0, role: .user, text: "Add a dark mode toggle"),
                       ViewerEntry(id: 1, role: .tool, text: "Bash: Build the app"),
                       ViewerEntry(id: 2, role: .assistant, text: "Done.")]
        #expect(Handoff.markdown(item: item(), entries: entries, lastActive: "4:40 PM") == """
            # Conversation handoff: Dark mode toggle

            Project folder: /Users/example/Code/app
            From: Claude Code session sess-1, last active 4:40 PM

            The conversation so far is below. Continue from its last message.

            ---

            **User:**
            Add a dark mode toggle

            `Bash: Build the app`

            **Assistant:**
            Done.

            """)
    }

    @Test func copyKeepsOpeningAndLatestWithinLimit() {
        let entries = [ViewerEntry(id: 0, role: .user, text: "The original task")]
            + (1...50).map { ViewerEntry(id: $0, role: .assistant, text: "Step \($0) " + String(repeating: "x", count: 200)) }
        let text = Handoff.markdown(item: item(.codex), entries: entries, lastActive: "4:40 PM", limit: 3_000)
        #expect(text.count <= 3_000)
        #expect(text.contains("From: Codex thread sess-1"))
        #expect(text.contains("**User:**\nThe original task"))
        #expect(text.contains("Step 50 "))
        #expect(!text.contains("Step 1 "))
        #expect(text.contains(" earlier messages omitted]*"))
    }

    @Test func unfinishedConversationOpensWithTheContinueLine() {
        var stopped = item()
        stopped.unfinished = .usageLimit("You've hit your session limit · resets 3:10pm (America/New_York)")
        let entries = [ViewerEntry(id: 0, role: .user, text: "Add a dark mode toggle"),
                       ViewerEntry(id: 1, role: .tool, text: "Bash: Build the app")]
        #expect(Handoff.markdown(item: stopped, entries: entries, lastActive: "4:40 PM") == """
            Continue the work from this unfinished conversation.

            # Conversation handoff: Dark mode toggle

            Project folder: /Users/example/Code/app
            From: Claude Code session sess-1, last active 4:40 PM
            Stopped: You've hit your session limit · resets 3:10pm (America/New_York)

            The conversation so far is below. Continue from its last message.

            ---

            **User:**
            Add a dark mode toggle

            `Bash: Build the app`

            """)
    }

    @Test func unfinishedCopyStaysWithinLimit() {
        var stopped = item()
        stopped.unfinished = .midTask
        let entries = [ViewerEntry(id: 0, role: .user, text: "The original task")]
            + (1...50).map { ViewerEntry(id: $0, role: .assistant, text: "Step \($0) " + String(repeating: "x", count: 200)) }
        let text = Handoff.markdown(item: stopped, entries: entries, lastActive: "4:40 PM", limit: 3_000)
        #expect(text.count <= 3_000)
        #expect(text.hasPrefix("Continue the work from this unfinished conversation.\n\n# Conversation handoff: Dark mode toggle\n"))
        #expect(text.contains("\nStopped: The session ended before its last turn finished\n"))
        #expect(text.contains("Step 50 "))
    }

    @Test func fileNameDropsPathSeparators() {
        var named = item()
        named.title = "Fix a/b: the 'login' flow"
        #expect(Handoff.fileName(for: named) == "Fix a-b- the 'login' flow.md")
    }

    @Test func savedExportKeepsLongMessages() throws {
        let dir = try TempDir()
        let long = String(repeating: "z", count: 13_000)
        var exported = item()
        exported.fileURL = try dir.write("t.jsonl", #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(long)"}]},"timestamp":"2026-10-14T00:00:01Z"}"# + "\n")
        #expect(try Handoff.export(item: exported, lastActive: "4:40 PM").contains(long))
    }

    @Test func copyClipsLongMessages() {
        let long = String(repeating: "z", count: 13_000)
        let text = Handoff.markdown(item: item(), entries: [ViewerEntry(id: 0, role: .assistant, text: long)], lastActive: "4:40 PM",
                                    limit: Handoff.copyLimit)
        #expect(!text.contains(long))
        #expect(text.contains(String(repeating: "z", count: TranscriptViewer.maxEntryLength) + "…"))
    }

    @Test func exportReadsTheLatestTurns() throws {
        let dir = try TempDir()
        var exported = item()
        exported.fileURL = try dir.write("t.jsonl", #"{"type":"user","message":{"role":"user","content":"First question"},"timestamp":"2026-10-14T00:00:00Z"}"# + "\n")
        #expect(try Handoff.export(item: exported, lastActive: "now").contains("First question"))
        let handle = try FileHandle(forWritingTo: exported.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Latest answer"}]},"timestamp":"2026-10-14T00:01:00Z"}"# + "\n").utf8))
        try handle.close()
        #expect(try Handoff.export(item: exported, lastActive: "now", limit: Handoff.copyLimit).contains("Latest answer"))
    }

    @Test func entriesForItemUseItsProvider() throws {
        var codex = item(.codex)
        codex.fileURL = Fixture.url("codex-rollout.jsonl")
        #expect(try TranscriptViewer.entries(for: codex).first?.text == "Find the failing test")
    }
}
