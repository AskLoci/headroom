import Foundation
import Testing
@testable import HeadroomCore

struct TranscriptViewerTests {
    func pairs(_ entries: [ViewerEntry]) -> [String] {
        entries.map { "\($0.role.rawValue): \($0.text)" }
    }

    @Test func claudeConversationWithCollapsedTools() throws {
        let entries = try TranscriptViewer.claudeEntries(url: Fixture.url("claude-desktop-transcript.jsonl"))
        #expect(pairs(entries) == [
            "user: Add a dark mode toggle",
            "assistant: I'll add the toggle to Settings.",
            "tool: Bash: Build the app",
            "tool: mcp__docs__search: NSAppearance",
            "assistant: Done. The toggle is in Settings → Appearance.",
        ])
        #expect(entries.map(\.id) == Array(0..<5))
    }

    @Test func codexConversationFromCompletedItems() throws {
        let entries = try TranscriptViewer.codexEntries(url: Fixture.url("codex-rollout.jsonl"))
        #expect(pairs(entries) == [
            "user: Find the failing test",
            "tool: Shell: swift test --filter Parser",
            "tool: github.search_issues: flaky parser",
            "tool: Edited: Parser.swift",
            "assistant: Fixed the parser test.",
        ])
    }

    @Test func hidesWrapperMarkupAndKeepsFullText() throws {
        let dir = try TempDir()
        let long = String(repeating: "y", count: 13_000)
        let url = try dir.write("t.jsonl", """
            {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-10-14T00:00:00Z"}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(long)"}]},"timestamp":"2026-10-14T00:00:01Z"}

            """)
        let entries = try TranscriptViewer.claudeEntries(url: url)
        #expect(entries.count == 1)
        #expect(entries[0].role == .assistant)
        #expect(entries[0].text.count == 13_000)
    }
}
