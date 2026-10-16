import Foundation
import Testing
@testable import HeadroomCore

struct CodexAPITests {
    let taken = Date(timeIntervalSince1970: 1_792_025_000)
    let account = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    static func jwt(_ claims: String) -> String {
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }

    @Test func decodesWeeklyOnlyUsage() throws {
        let usage = try CodexAPI.decodeUsage(Fixture.data("codex-usage.json"), takenAt: taken)
        #expect(usage.reading.weekly == UsageWindow(percent: 70, resetsAt: Date(timeIntervalSince1970: 1_792_474_215)))
        #expect(usage.reading.session == nil)
        #expect(usage.reading.source == .live)
        #expect(usage.email == "coder@example.com")
        #expect(usage.plan == "Pro")
        #expect(usage.accountId == account)
    }

    @Test func classifiesWindowsByLength() throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1792040000},
                        "secondary_window": {"used_percent": 55, "limit_window_seconds": 604800, "reset_at": 1792474215}}}
        """
        let usage = try CodexAPI.decodeUsage(Data(json.utf8), takenAt: taken)
        #expect(usage.reading.weekly?.percent == 55)
        #expect(usage.reading.session == UsageWindow(percent: 12, resetsAt: Date(timeIntervalSince1970: 1_792_040_000)))
    }

    @Test func decodesChatGPTSignIn() {
        let idToken = Self.jwt(#"{"email":"Coder@Example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro","chatgpt_account_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}"#)
        let json = #"{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"\#(idToken)","access_token":"access-example","refresh_token":"refresh-example","account_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"},"last_refresh":"2026-10-12T23:13:07Z"}"#
        #expect(CodexAPI.decodeAuth(Data(json.utf8)) == CodexAuth(accessToken: "access-example", accountId: account, email: "Coder@Example.com", plan: "Pro"))
    }

    @Test(arguments: [#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-example","tokens":null}"#, "{}", ""])
    func apiKeyModeIsNotASignIn(_ json: String) {
        #expect(CodexAPI.decodeAuth(Data(json.utf8)) == nil)
    }

    @Test func snapshotFromTokenCountLine() {
        let line = #"{"timestamp":"2026-10-15T00:04:21.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":65.0,"window_minutes":10080,"resets_at":1792474215},"secondary":null}}}"#
        #expect(CodexAPI.snapshot(fromLine: Data(line.utf8)) == Reading(
            takenAt: Date(timeIntervalSince1970: 1_792_022_661),
            weekly: UsageWindow(percent: 65, resetsAt: Date(timeIntervalSince1970: 1_792_474_215)),
            session: nil, source: .codexLog))
        #expect(CodexAPI.snapshot(fromLine: Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#.utf8)) == nil)
        #expect(CodexAPI.snapshot(fromLine: Data(#"{"type":"response_item","payload":{"type":"message"}}"#.utf8)) == nil)
    }

    @Test func latestSnapshotInRollout() {
        let snapshot = CodexAPI.latestSnapshot(rollout: Fixture.url("codex-rollout.jsonl"))
        #expect(snapshot?.accountId == account)
        #expect(snapshot?.reading.takenAt == Date(timeIntervalSince1970: 1_792_022_701))
        #expect(snapshot?.reading.weekly?.percent == 66)
        #expect(snapshot?.reading.session == UsageWindow(percent: 20, resetsAt: Date(timeIntervalSince1970: 1_792_040_000)))
    }

    @Test func newestRolloutAcrossRecentDayFolders() throws {
        let dir = try TempDir()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = date("2026-10-15T03:00:00Z") // 11 PM on Oct 14 in New York
        let older = try dir.write("2026/10/13/rollout-a.jsonl", "{}\n")
        let newer = try dir.write("2026/10/14/rollout-b.jsonl", "{}\n")
        try dir.write("2026/10/14/notes.txt", "x")
        try FileManager.default.setAttributes([.modificationDate: now - 7200], ofItemAtPath: older.fsPath)
        try FileManager.default.setAttributes([.modificationDate: now - 60], ofItemAtPath: newer.fsPath)
        #expect(CodexRollouts.newest(sessionsRoot: dir.url, now: now, calendar: calendar)?.fsPath == newer.fsPath)
    }
}
