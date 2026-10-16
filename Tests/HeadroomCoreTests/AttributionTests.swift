import Foundation
import Testing
@testable import HeadroomCore

struct AttributionTests {
    let a = "aaaaaaaa-0000-4000-8000-000000000000"
    let b = "bbbbbbbb-0000-4000-8000-000000000000"

    var timeline: [CLISignIn] {
        [CLISignIn(accountUuid: a, from: date("2026-10-01T00:00:00Z")), CLISignIn(accountUuid: b, from: date("2026-10-10T00:00:00Z"))]
    }

    func scan(entrypoint: String? = "sdk-py", at iso: String = "2026-10-12T15:00:00Z", bridge: String? = nil, email: String? = nil) -> TranscriptScan {
        var scan = TranscriptScan()
        scan.entrypoint = entrypoint
        scan.firstTimestamp = date(iso)
        scan.bridgeOwner = bridge
        scan.injectedEmail = email
        return scan
    }

    @Test func desktopMetadataWinsOverEverything() {
        #expect(Attribution.owner(desktopAccount: a, scan: scan(bridge: b), emailToAccount: [:], timeline: timeline)
                == TranscriptOwner(accountUuid: a, source: .desktopMetadata))
    }

    @Test func bridgeBeatsEmail() {
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(bridge: b, email: "x@example.com"), emailToAccount: ["x@example.com": a], timeline: [])
                == TranscriptOwner(accountUuid: b, source: .bridge))
    }

    @Test func emailMapsThroughKnownAccounts() {
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(entrypoint: "claude-desktop", email: "x@example.com"), emailToAccount: ["x@example.com": a], timeline: [])
                == TranscriptOwner(accountUuid: a, source: .injectedEmail))
    }

    @Test func cliAndSdkUseTheSignInTimeline() {
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(at: "2026-10-12T15:00:00Z"), emailToAccount: [:], timeline: timeline)?.accountUuid == b)
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(at: "2026-10-05T00:00:00Z"), emailToAccount: [:], timeline: timeline)?.accountUuid == a)
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(at: "2026-09-01T00:00:00Z"), emailToAccount: [:], timeline: timeline) == nil)
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(entrypoint: "cli"), emailToAccount: [:], timeline: timeline)
                == TranscriptOwner(accountUuid: b, source: .cliTimeline))
    }

    @Test func desktopTranscriptWithoutHintsStaysUnassigned() {
        #expect(Attribution.owner(desktopAccount: nil, scan: scan(entrypoint: "claude-desktop"), emailToAccount: [:], timeline: timeline) == nil)
        #expect(Attribution.owner(desktopAccount: nil, scan: nil, emailToAccount: [:], timeline: timeline) == nil)
    }

    @Test func majorityEmailWithAlphabeticalTieBreak() {
        let votes: [(account: String, email: String)] = [(a, "x@e.com"), (a, "x@e.com"), (a, "y@e.com"), (b, "q@e.com"), (b, "p@e.com")]
        #expect(Attribution.majorityEmails(votes) == [a: "x@e.com", b: "p@e.com"])
    }

    @Test func recordsTimelineOnlyOnChange() {
        var timeline: [CLISignIn] = []
        let first = Attribution.recordCLISignIn(a, at: date("2026-10-01T00:00:00Z"), timeline: &timeline)
        let same = Attribution.recordCLISignIn(a, at: date("2026-10-02T00:00:00Z"), timeline: &timeline)
        let changed = Attribution.recordCLISignIn(b, at: date("2026-10-03T00:00:00Z"), timeline: &timeline)
        #expect(first)
        #expect(!same)
        #expect(changed)
        #expect(timeline.map(\.accountUuid) == [a, b])
    }
}
