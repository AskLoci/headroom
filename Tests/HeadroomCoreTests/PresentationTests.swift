import Foundation
import Testing
@testable import HeadroomCore

struct PresentationTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    let english = Locale(identifier: "en_US")

    func at(_ iso: String) -> Presentation {
        Presentation(now: date(iso), timeZone: newYork, locale: english)
    }

    func account(_ id: String, _ provider: Provider = .claude, _ surfaces: Set<Surface> = [], percent: Double?, resets: Date? = nil) -> Account {
        let time = Date(timeIntervalSince1970: 1_792_000_000)
        return Account(provider: provider, id: id, signedInOn: surfaces,
                       lastReading: percent.map { Reading(takenAt: time, weekly: UsageWindow(percent: $0, resetsAt: resets), session: nil, source: .live) },
                       firstSeen: time, lastSeen: time)
    }

    @Test func resetTextBeforeAndAfterReset() {
        let window = UsageWindow(percent: 70, resetsAt: date("2026-10-18T21:00:00Z")) // Sunday 17:00 in New York
        #expect(at("2026-10-15T12:00:00Z").resetText(window) == "Resets Sun 17:00 (3d 9h)")
        #expect(at("2026-10-19T12:00:00Z").resetText(window) == "Week restarted Sun 17:00")
        #expect(at("2026-10-19T12:00:00Z").resetText(window, restartedLabel: "Restarted") == "Restarted Sun 17:00")
        #expect(at("2026-10-15T12:00:00Z").resetText(UsageWindow(percent: 70, resetsAt: nil)) == "Reset time not known yet")
    }

    @Test(arguments: [
        ("2026-10-22T06:40:00Z", "Resets Thurs 02:40 (6d 15h)"),
        ("2026-10-20T06:40:00Z", "Resets Tues 02:40 (4d 15h)"),
        ("2026-10-15T17:10:00Z", "Resets Thurs 13:10 (2h 10m)"),
        ("2026-10-15T15:45:00Z", "Resets Thurs 11:45 (45m)"),
        ("2026-10-15T15:00:20Z", "Resets Thurs 11:00 (<1m)"),
    ])
    func resetTextCountsDown(_ resetsAt: String, _ expected: String) {
        let p = at("2026-10-15T15:00:00Z") // Thursday 11:00 in New York
        #expect(p.resetText(UsageWindow(percent: 5, resetsAt: date(resetsAt))) == expected)
    }

    @Test func timesUseADayAndA24HourClock() {
        let p = at("2026-10-15T15:00:00Z") // Thursday 11:00 in New York
        #expect(p.timeText(date("2026-10-15T05:26:00Z")) == "01:26")
        #expect(p.timeText(date("2026-10-13T14:11:00Z")) == "Tues 10:11")
        #expect(p.timeText(date("2026-10-03T14:11:00Z")) == "Oct 3")
    }

    @Test func effectivePercentDropsToZeroAfterReset() {
        let window = UsageWindow(percent: 70, resetsAt: date("2026-10-18T21:00:00Z"))
        #expect(at("2026-10-15T12:00:00Z").effectivePercent(window) == 70)
        #expect(at("2026-10-19T12:00:00Z").effectivePercent(window) == 0)
        #expect(at("2026-10-15T12:00:00Z").effectivePercent(nil) == nil)
    }

    @Test func unknownWeeklyShowsDash() {
        let p = at("2026-10-15T12:00:00Z")
        let idle = account("idle", .claude, [.desktop], percent: nil)
        #expect(p.menuBar([idle]).first == MenuBarSegment(provider: .claude, glyph: "✳", percentText: "–", percent: nil, level: .normal))
        #expect(p.resetText(idle.lastReading?.weekly) == "Reset time not known yet")
        #expect(p.effectivePercent(idle.lastReading?.weekly) == nil)
    }

    @Test(arguments: [(79.9, Level.normal), (80, .warning), (94.9, .warning), (95, .critical), (120, .critical)])
    func levels(_ percent: Double, _ level: Level) {
        #expect(Level(percent: percent) == level)
    }

    @Test func sortsByRoomThenSoonestResetThenUnknown() {
        let p = at("2026-10-15T12:00:00Z")
        let accounts = [
            account("a", percent: 70), account("b", percent: 20),
            account("c", percent: 100, resets: p.now + 7200), account("d", percent: 100, resets: p.now + 3600),
            account("e", percent: nil),
        ]
        #expect(p.sortedAccounts(accounts).map(\.id) == ["b", "a", "d", "c", "e"])
    }

    @Test func modelChipsAtOrAbove80() {
        let reading = Reading(takenAt: .now, weekly: nil, session: nil,
                              scoped: [ScopedLimit(name: "Fable", percent: 98, resetsAt: nil), ScopedLimit(name: "Sonnet", percent: 50, resetsAt: nil)],
                              source: .live)
        #expect(at("2026-10-15T12:00:00Z").modelChips(reading).map(\.name) == ["Fable"])
    }

    @Test func menuBarPrefersDesktopThenCLI() {
        let p = at("2026-10-15T12:00:00Z")
        let desktop = account("d", .claude, [.desktop], percent: 70)
        let cli = account("c", .claude, [.cli], percent: 85)
        let codex = account("x", .codex, [.codex], percent: 96)
        #expect(p.menuBar([cli, desktop, codex]) == [
            MenuBarSegment(provider: .claude, glyph: "✳", percentText: "70%", percent: 70, level: .normal),
            MenuBarSegment(provider: .codex, glyph: ">_", percentText: "96%", percent: 96, level: .critical),
        ])
        #expect(p.menuBar([cli]) == [
            MenuBarSegment(provider: .claude, glyph: "✳", percentText: "85%", percent: 85, level: .warning),
            MenuBarSegment(provider: .codex, glyph: ">_", percentText: "–", percent: nil, level: .normal),
        ])
    }

    @Test func staleTextAfterTenMinutes() {
        let p = at("2026-10-14T21:00:00Z") // 5:00 PM in New York
        #expect(p.staleText(Reading(takenAt: date("2026-10-14T20:55:00Z"), weekly: nil, session: nil, source: .live)) == nil)
        #expect(p.staleText(Reading(takenAt: date("2026-10-14T20:40:00Z"), weekly: nil, session: nil, source: .live)) == "as of 16:40")
    }

    @Test func relativeTimes() {
        let p = at("2026-10-14T21:00:00Z")
        #expect(p.relative(p.now - 30) == "now")
        #expect(p.relative(p.now - 300) == "5m ago")
        #expect(p.relative(p.now - 3 * 3600) == "3h ago")
        #expect(p.relative(p.now - 2 * 86_400) == "2d ago")
    }
}

struct DisplayFreshnessTests {
    let p = Presentation(now: date("2026-10-15T12:00:00Z"), timeZone: TimeZone(identifier: "America/New_York")!, locale: Locale(identifier: "en_US"))

    @Test func resetTimesRoundToTheNearestMinute() {
        // The usage endpoint reports 21:59:59.856 for an 18:00 reset.
        #expect(p.resetText(UsageWindow(percent: 76, resetsAt: date("2026-10-16T21:59:59.856Z"))) == "Resets Fri 18:00 (1d 10h)")
        #expect(p.resetText(UsageWindow(percent: 76, resetsAt: date("2026-10-16T22:00:29Z"))) == "Resets Fri 18:00 (1d 10h)")
    }

    @Test func staleFiveHourValuesAreDropped() {
        func reading(hoursAgo: Double, resets: Date?) -> Reading {
            Reading(takenAt: p.now - hoursAgo * 3600, weekly: nil, session: UsageWindow(percent: 100, resetsAt: resets), source: .desktopSample)
        }
        #expect(p.currentSession(reading(hoursAgo: 6, resets: nil)) == nil)
        #expect(p.currentSession(reading(hoursAgo: 2, resets: nil))?.percent == 100)
        #expect(p.currentSession(reading(hoursAgo: 6, resets: p.now + 600))?.percent == 100)
        #expect(p.currentSession(nil) == nil)
    }
}
