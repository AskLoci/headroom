import Foundation
import Testing
@testable import HeadroomCore

struct DesktopSessionsTests {
    @Test func parsesMetadataFields() throws {
        let session = try DesktopSessions.parse(Fixture.data("desktop-session.json"), accountUuid: "acct-a", orgUuid: "org-x",
                                                fileStem: "local_cccccccc-0000-4000-8000-000000000000")
        #expect(session.localId == "local_cccccccc-0000-4000-8000-000000000000")
        #expect(session.cliSessionId == "dddddddd-0000-4000-8000-000000000000")
        #expect(session.title == "Fix the login flow")
        #expect(session.cwd == "/Users/example/Code/app")
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_792_011_000.123))
        #expect(session.lastActivityAt == Date(timeIntervalSince1970: 1_792_020_778.048))
        #expect(!session.isArchived)
    }

    @Test func walksAccountOrgLayoutAndArchivedIndex() throws {
        let dir = try TempDir()
        let a = "aaaaaaaa-0000-4000-8000-000000000000", b = "bbbbbbbb-0000-4000-8000-000000000000"
        let x = "11111111-0000-4000-8000-000000000000", y = "22222222-0000-4000-8000-000000000000"
        try dir.write("\(a)/\(x)/local_one.json", #"{"sessionId":"local_one","cliSessionId":"c1","title":"One"}"#)
        try dir.write("\(a)/\(x)/archived-sessions.idx", #"{"v":1,"archived":["local_one"]}"#)
        try dir.write("\(a)/\(x)/deleted_old", "1792017076403")
        try dir.write("\(a)/\(x)/scheduled-tasks.json", "{}")
        try dir.write("\(b)/\(x)/local_two.json", #"{"sessionId":"local_two","cliSessionId":"c2","isArchived":true}"#)
        try FileManager.default.createDirectory(at: dir.url.appending(path: "\(b)/\(y)"), withIntermediateDirectories: true)
        try dir.write("not-a-uuid/whatever.json", "{}")

        #expect(DesktopSessions.accountOrgs(root: dir.url) == [a: [x], b: [x, y]])
        let files = DesktopSessions.metadataFiles(root: dir.url).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        #expect(files.map(\.url.lastPathComponent) == ["local_one.json", "local_two.json"])
        #expect(files.map(\.accountUuid) == [a, b])
        #expect(DesktopSessions.archivedIds(orgDir: dir.url.appending(path: "\(a)/\(x)")) == ["local_one"])
    }
}

struct UsageSamplesTests {
    let orgs: [String: Set<String>] = ["solo-acct": ["org-solo"], "acct-a": ["org-shared"], "acct-b": ["org-shared", "org-b"]]
    let activity: UsageSamples.Activity = [
        "acct-a": [Date(timeIntervalSince1970: 1_792_001_500)...Date(timeIntervalSince1970: 1_792_002_000)],
        "acct-b": [Date(timeIntervalSince1970: 1_791_900_000)...Date(timeIntervalSince1970: 1_791_901_000)],
    ]

    func sample(_ t: Double, _ org: String) -> UsageSample {
        UsageSample(takenAt: Date(timeIntervalSince1970: t), orgUuid: org, weekly: 1, fiveHour: nil)
    }

    @Test func parseSkipsSamplesWithoutWeekly() throws {
        let samples = try UsageSamples.parse(Fixture.data("plan-usage-history.json"))
        #expect(samples.count == 4)
        #expect(samples[0] == UsageSample(takenAt: Date(timeIntervalSince1970: 1_792_000_000), orgUuid: "org-solo", weekly: 40, fiveHour: 10))
    }

    @Test func singleAccountOrgMapsDirectly() {
        #expect(UsageSamples.account(for: sample(1_792_000_000, "org-solo"), accountOrgs: orgs, activity: [:]) == "solo-acct")
    }

    @Test func sharedOrgGoesToNearestActivity() {
        #expect(UsageSamples.account(for: sample(1_792_001_800, "org-shared"), accountOrgs: orgs, activity: activity) == "acct-a")
        #expect(UsageSamples.account(for: sample(1_792_003_500, "org-shared"), accountOrgs: orgs, activity: activity) == "acct-a")
    }

    @Test func sharedOrgWithoutNearbyActivityIsSkipped() {
        #expect(UsageSamples.account(for: sample(1_792_090_000, "org-shared"), accountOrgs: orgs, activity: activity) == nil)
        #expect(UsageSamples.account(for: sample(1_792_000_000, "org-unknown"), accountOrgs: orgs, activity: activity) == nil)
    }

    @Test func latestReadingPerAccount() throws {
        let readings = UsageSamples.latestReadings(try UsageSamples.parse(Fixture.data("plan-usage-history.json")),
                                                   accountOrgs: orgs, activity: activity)
        #expect(readings["solo-acct"]?.weekly == UsageWindow(percent: 41, resetsAt: nil))
        #expect(readings["solo-acct"]?.session == UsageWindow(percent: 12, resetsAt: nil))
        #expect(readings["solo-acct"]?.takenAt == Date(timeIntervalSince1970: 1_792_000_900))
        #expect(readings["acct-a"]?.weekly?.percent == 70)
        #expect(readings["acct-a"]?.source == .desktopSample)
        #expect(readings["acct-b"] == nil)
    }
}
