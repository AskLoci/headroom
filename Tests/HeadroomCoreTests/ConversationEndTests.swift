import Foundation
import Testing
@testable import HeadroomCore

/// Transcript lines shaped like Claude Code 2.1.295's, trimmed to their identifying fields.
enum ClaudeLines {
    static func entry(_ type: String, _ message: String, extra: String = "", sidechain: Bool = false) -> String {
        #"{"parentUuid":"p-1","isSidechain":\#(sidechain),\#(extra)"type":"\#(type)","message":\#(message),"uuid":"u-1","timestamp":"2026-10-15T05:27:42.393Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/example/app","sessionId":"s-1","version":"2.1.295","gitBranch":"main"}"#
    }

    static func prompt(_ text: String, extra: String = "") -> String {
        entry("user", #"{"role":"user","content":"\#(text)"}"#, extra: extra)
    }

    static func reply(_ text: String) -> String {
        entry("assistant", #"{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":9}}"#)
    }

    static func toolCall(_ name: String, input: String = "swift test", sidechain: Bool = false) -> String {
        entry("assistant", #"{"model":"claude-opus-5-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":{"command":"\#(input)"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":9}}"#,
              sidechain: sidechain)
    }

    static func toolResult(_ text: String) -> String {
        entry("user", #"{"role":"user","content":[{"type":"tool_result","content":"\#(text)","is_error":false,"tool_use_id":"toolu_1"}]}"#,
              extra: #""toolUseResult":{"stdout":"\#(text)","stderr":""},"sourceToolAssistantUUID":"u-0","#)
    }

    static func apiError(_ error: String, _ text: String) -> String {
        entry("assistant", #"{"id":"e-1","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"\#(text)"}]}"#,
              extra: #""requestId":"req_1","error":"\#(error)","isApiErrorMessage":true,"#)
    }

    static let refusal = entry("assistant", #"{"model":"claude-opus-5-5","id":"msg_3","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"sig"}],"stop_reason":"refusal","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":0}}"#)
    static let interrupted = entry("user", #"{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#)
    static let shutDown = entry("user", #"{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}"#,
                                extra: #""interruptedByShutdown":true,"#)
    static let slashCommand = prompt(#"<command-name>/usage</command-name>\n<command-message>usage</command-message>\n<command-args></command-args>"#)
    static let commandOutput = prompt("<local-command-stdout>Session: 12% used</local-command-stdout>")
    static let compactBoundary = #"{"parentUuid":null,"logicalParentUuid":"u-1","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"manual","preTokens":180000},"timestamp":"2026-10-15T05:28:00.000Z","uuid":"c-1"}"#
    static let compactSummary = prompt("This session is being continued from a previous conversation that ran out of context.",
                                       extra: #""isVisibleInTranscriptOnly":true,"isCompactSummary":true,"#)
    static let metaNote = prompt("Your response above was stopped by a safety classifier.", extra: #""isMeta":true,"#)
    static let stopHook = #"{"type":"system","subtype":"stop_hook_summary","hookCount":1,"hookInfos":[],"level":"suggestion","timestamp":"2026-10-15T05:27:43.000Z","uuid":"h-1"}"#
    static let lastPrompt = #"{"type":"last-prompt","lastPrompt":"Add a dark mode toggle","sessionId":"s-1"}"#
    static let costState = #"{"type":"cost-state","sessionId":"s-1","totalCostUSD":0.42}"#
}

/// Rollout lines shaped like the Codex app's (0.160), trimmed to their identifying fields.
enum CodexLines {
    static func event(_ payload: String) -> String {
        #"{"timestamp":"2026-10-15T05:36:40.996Z","ordinal":1,"type":"event_msg","payload":\#(payload)}"#
    }

    static let started = event(#"{"type":"task_started","turn_id":"turn-1","root_turn_id":"turn-1","started_at":1792042600,"model_context_window":258400,"collaboration_mode_kind":"default"}"#)
    static let completed = event(#"{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Fixed the parser test.","started_at":1792042600,"completed_at":1792043235,"duration_ms":634976,"time_to_first_token_ms":7295}"#)
    static let usageLimit = event(#"{"type":"task_complete","turn_id":"turn-1","error":{"message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 11th, 2026 7:59 AM.","codex_error_info":"usage_limit_exceeded"},"started_at":1791139367,"completed_at":1791139696,"duration_ms":329141,"time_to_first_token_ms":5143}"#)
    static let connectionFailed = event(#"{"type":"task_complete","turn_id":"turn-1","error":{"message":"unexpected status 401 Unauthorized","codex_error_info":{"http_connection_failed":{"http_status_code":401}}},"started_at":1791139367,"completed_at":1791139696,"duration_ms":329141}"#)
    static let aborted = event(#"{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted","started_at":1791993053,"completed_at":1791993398,"duration_ms":344772}"#)
    static let agentMessage = event(#"{"type":"item_completed","thread_id":"thread-1","turn_id":"turn-1","item":{"type":"AgentMessage","id":"a1","content":[{"type":"Text","text":"Fixed the parser test."}],"phase":"final"}}"#)
    static let tokenCount = event(#"{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":66.0,"window_minutes":10080,"resets_at":1792474215}}}"#)
}

struct EndingCase: Sendable, CustomTestStringConvertible {
    let name: String
    let lines: [String]
    let expected: ConversationEnd
    var testDescription: String { name }
}

struct ConversationEndTests {
    func write(_ lines: [String], in dir: TempDir, _ name: String = "s-1.jsonl") throws -> URL {
        try dir.write(name, lines.joined(separator: "\n") + "\n")
    }

    static let claudeCases: [EndingCase] = {
        typealias L = ClaudeLines
        return [
            EndingCase(name: "reply ended", lines: [L.prompt("Add a dark mode toggle"), L.reply("Done."), L.stopHook, L.lastPrompt, L.costState],
                       expected: .finished),
            EndingCase(name: "usage limit", lines: [L.prompt("Add a dark mode toggle"),
                                                    L.apiError("rate_limit", "You've hit your session limit · resets 3:10pm (America/New_York)"), L.costState],
                       expected: .stopped(.usageLimit("You've hit your session limit · resets 3:10pm (America/New_York)"))),
            EndingCase(name: "API error", lines: [L.toolResult("ok"), L.apiError("server_error", "API Error: Connection dropped (ECONNRESET)")],
                       expected: .stopped(.error("API Error: Connection dropped (ECONNRESET)"))),
            EndingCase(name: "model refusal", lines: [L.prompt("Continue"), L.refusal, L.metaNote, L.costState],
                       expected: .stopped(.error("Stopped by the model's safeguards"))),
            EndingCase(name: "interrupted", lines: [L.prompt("Run the tests"), L.toolCall("Bash"), L.interrupted, L.lastPrompt],
                       expected: .stopped(.interrupted)),
            EndingCase(name: "app shut down during a tool call", lines: [L.toolCall("Bash"), L.shutDown, L.lastPrompt],
                       expected: .stopped(.midTask)),
            EndingCase(name: "tool call never answered", lines: [L.prompt("Run the tests"), L.toolCall("Bash"), L.costState],
                       expected: .unended),
            EndingCase(name: "tool result never continued", lines: [L.toolCall("Bash"), L.toolResult("Exit code 137"), L.costState],
                       expected: .unended),
            EndingCase(name: "structured output ends an SDK run", lines: [L.prompt("Review this"), L.toolCall("StructuredOutput"),
                                                                         L.toolResult("Structured output provided successfully"), L.lastPrompt],
                       expected: .finished),
            EndingCase(name: "prompt never answered", lines: [L.reply("Done."), L.prompt("Now ship it"), L.lastPrompt],
                       expected: .unended),
            EndingCase(name: "slash command after a reply", lines: [L.reply("Done."), L.slashCommand, L.commandOutput, L.costState],
                       expected: .finished),
            EndingCase(name: "manual compaction after a reply", lines: [L.reply("Done."), L.compactBoundary, L.compactSummary, L.commandOutput],
                       expected: .finished),
            EndingCase(name: "meta and sidechain lines after a reply", lines: [L.reply("Done."), L.metaNote, L.toolCall("Bash", sidechain: true)],
                       expected: .finished),
            EndingCase(name: "no conversation yet", lines: [L.lastPrompt, L.costState], expected: .finished),
        ]
    }()

    @Test(arguments: claudeCases)
    func claudeEnding(_ testCase: EndingCase) throws {
        let dir = try TempDir()
        let url = try write(testCase.lines, in: dir)
        #expect(try ConversationEnd.claude(url: url) == testCase.expected)
    }

    @Test func claudeEndingReadsPastALongLastLine() throws {
        let long = String(repeating: "x", count: 5_000)
        let dir = try TempDir()
        let url = try write([ClaudeLines.prompt("Run the tests"), ClaudeLines.toolCall("Bash"), ClaudeLines.toolResult(long), ClaudeLines.costState], in: dir)
        #expect(try ConversationEnd.claude(url: url, window: 1_024) == .unended)
    }

    @Test func claudeEndingFindsTheCallBehindALongResultWindow() throws {
        let long = String(repeating: "x", count: 5_000)
        let dir = try TempDir()
        let url = try write([ClaudeLines.prompt("Review this"), ClaudeLines.toolCall("StructuredOutput", input: long),
                             ClaudeLines.toolResult("Structured output provided successfully"), ClaudeLines.lastPrompt], in: dir)
        #expect(try ConversationEnd.claude(url: url, window: 1_024) == .finished)
    }

    static let codexCases: [EndingCase] = {
        typealias L = CodexLines
        return [
            EndingCase(name: "turn completed", lines: [L.started, L.agentMessage, L.completed, L.tokenCount], expected: .finished),
            EndingCase(name: "usage limit", lines: [L.completed, L.started, L.usageLimit, L.tokenCount],
                       expected: .stopped(.usageLimit("You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Oct 11th, 2026 7:59 AM."))),
            EndingCase(name: "other error", lines: [L.started, L.connectionFailed], expected: .stopped(.error("unexpected status 401 Unauthorized"))),
            EndingCase(name: "interrupted", lines: [L.started, L.aborted, L.tokenCount], expected: .stopped(.interrupted)),
            EndingCase(name: "turn still open", lines: [L.started, L.completed, L.started, L.agentMessage, L.tokenCount], expected: .unended),
        ]
    }()

    @Test(arguments: codexCases)
    func codexEnding(_ testCase: EndingCase) throws {
        let dir = try TempDir()
        let url = try write(testCase.lines, in: dir, "rollout.jsonl")
        #expect(try ConversationEnd.codex(url: url) == testCase.expected)
    }

    @Test func codexRolloutWithoutTurnEventsCountsAsFinished() throws {
        #expect(try ConversationEnd.codex(url: Fixture.url("codex-rollout.jsonl")) == .finished)
    }

    func item(_ provider: Provider, id: String = "s-1") -> TranscriptItem {
        TranscriptItem(id: id, provider: provider, accountId: "a", title: "Dark mode toggle", cwd: nil,
                       lastActivity: date("2026-10-15T05:27:42Z"), archived: false, fileURL: URL(filePath: "/p/\(id).jsonl"))
    }

    @Test func claudeSessionsStillWorkingAreNotMarked() {
        let working: Set<String> = ["s-busy"]
        #expect(item(.claude, id: "s-busy").unfinishedReason(end: .unended, workingClaudeSessions: working) == nil)
        #expect(item(.claude, id: "s-busy").unfinishedReason(end: .stopped(.interrupted), workingClaudeSessions: working) == nil)
        #expect(item(.claude, id: "s-gone").unfinishedReason(end: .unended, workingClaudeSessions: working) == .midTask)
        #expect(item(.claude, id: "s-gone").unfinishedReason(end: .stopped(.interrupted), workingClaudeSessions: working) == .interrupted)
        #expect(item(.claude, id: "s-gone").unfinishedReason(end: .finished, workingClaudeSessions: working) == nil)
    }

    @Test func codexOpenTurnsAreNotMarked() {
        #expect(item(.codex).unfinishedReason(end: .unended, workingClaudeSessions: []) == nil)
        #expect(item(.codex).unfinishedReason(end: .stopped(.usageLimit("You've hit your usage limit.")), workingClaudeSessions: [])
                == .usageLimit("You've hit your usage limit."))
        #expect(item(.codex).unfinishedReason(end: .finished, workingClaudeSessions: []) == nil)
    }
}

struct LiveSessionsTests {
    @Test func workingSessionsAreRunningAndNotIdle() throws {
        let dir = try TempDir()
        func record(_ pid: Int, _ session: String, _ status: String) -> String {
            #"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/Users/example/app","startedAt":1792007598882,"procStart":"Wed Oct 14 19:53:18 2026","version":"2.1.295","kind":"interactive","entrypoint":"claude-desktop","name":"t","status":"\#(status)","updatedAt":1792018627965,"statusUpdatedAt":1792018627965}"#
        }
        try dir.write("101.json", record(101, "s-busy", "busy"))
        try dir.write("102.json", record(102, "s-idle", "idle"))
        try dir.write("103.json", record(103, "s-dead", "busy"))
        try dir.write("104.json", record(104, "s-waiting", "waiting"))
        try dir.write("105.json", "{not json")
        try dir.write("101.0123abcd.key", "secret")
        let running: Set<Int32> = [101, 102, 104]
        #expect(LiveSessions.working(in: dir.url, isRunning: { running.contains($0) }) == ["s-busy", "s-waiting"])
    }

    @Test func missingDirectoryMeansNothingIsWorking() {
        let missing = URL(filePath: "/nonexistent-headroom-test/sessions", directoryHint: .isDirectory)
        #expect(LiveSessions.working(in: missing, isRunning: { _ in true }).isEmpty)
    }
}
