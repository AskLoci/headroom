import Foundation
import Testing
@testable import HeadroomCore

struct ClaudeAPITests {
    let taken = Date(timeIntervalSince1970: 1_792_020_000)

    @Test func decodesWeeklySessionAndScopedLimits() throws {
        let reading = try ClaudeAPI.decodeUsage(Fixture.data("claude-usage.json"), takenAt: taken)
        #expect(reading.takenAt == taken)
        #expect(reading.source == .live)
        #expect(reading.weekly?.percent == 76)
        #expect(abs(reading.weekly!.resetsAt!.timeIntervalSince1970 - 1_792_188_000.399846) < 0.0001)
        #expect(reading.session?.percent == 29)
        #expect(abs(reading.session!.resetsAt!.timeIntervalSince1970 - 1_792_030_200.123456) < 0.0001)
        #expect(reading.scoped.map(\.name) == ["Fable"])
        #expect(reading.scoped.first?.percent == 98)
    }

    @Test func nullWindowsDecodeAsUnknown() throws {
        let reading = try ClaudeAPI.decodeUsage(Data(#"{"five_hour": null, "seven_day": null, "limits": null}"#.utf8), takenAt: taken)
        #expect(reading.weekly == nil)
        #expect(reading.session == nil)
        #expect(reading.scoped.isEmpty)
    }

    @Test func limitsFillInWhenSevenDayIsMissing() throws {
        let json = #"{"limits": [{"kind": "weekly_all", "percent": 40, "resets_at": "2026-10-18T21:00:00Z", "scope": null}]}"#
        let reading = try ClaudeAPI.decodeUsage(Data(json.utf8), takenAt: taken)
        #expect(reading.weekly == UsageWindow(percent: 40, resetsAt: Date(timeIntervalSince1970: 1_792_357_200)))
    }

    @Test func decodesProfile() throws {
        let profile = try ClaudeAPI.decodeProfile(Fixture.data("claude-profile.json"))
        #expect(profile.accountUuid == "11111111-2222-4333-8444-555555555555")
        #expect(profile.email == "Person@Example.com")
        #expect(profile.organizationUuid == "66666666-7777-4888-9999-000000000000")
        #expect(profile.plan == "Max 20x")
    }

    @Test func planNames() {
        #expect(ClaudeAPI.planName(type: "max", tier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeAPI.planName(type: "claude_pro", tier: nil) == "Pro")
        #expect(ClaudeAPI.planName(type: "claude_team", tier: "team_standard") == "Team")
        #expect(ClaudeAPI.planName(type: nil, tier: nil) == nil)
    }

    @Test func headersNameHeadroom() {
        let headers = ClaudeAPI.headers(token: "tok", version: "1.2")
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(headers["User-Agent"] == "Headroom/1.2")
    }
}
