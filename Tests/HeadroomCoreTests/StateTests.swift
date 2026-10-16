import Foundation
import Testing
@testable import HeadroomCore

struct StateTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func reading(_ percent: Double, at time: Date, resets: Date? = nil, source: ReadingSource = .live) -> Reading {
        Reading(takenAt: time, weekly: UsageWindow(percent: percent, resetsAt: resets), session: nil, source: source)
    }

    @Test func upsertPrefillsKnownClaudeEmail() {
        var state = HeadroomState()
        state.claudeEmails["acct-a"] = "a@example.com"
        state.upsert(.claude, "acct-a", now: t0)
        state.upsert(.claude, "acct-a", now: t0 + 60)
        #expect(state.accounts.count == 1)
        #expect(state.account(.claude, "acct-a")?.email == "a@example.com")
        #expect(state.account(.claude, "acct-a")?.firstSeen == t0)
    }

    @Test func setEmailNormalizesAndRemembersClaudeEmails() {
        var state = HeadroomState()
        state.setEmail("Person@Example.com", for: .claude, "acct-a", now: t0)
        state.setEmail("Coder@Example.com", for: .codex, "acct-x", now: t0)
        #expect(state.account(.claude, "acct-a")?.email == "person@example.com")
        #expect(state.claudeEmails == ["acct-a": "person@example.com"])
        #expect(state.account(.codex, "acct-x")?.email == "coder@example.com")
    }

    @Test func signInIsExclusivePerSurface() {
        var state = HeadroomState()
        state.setSignedIn(.desktop, provider: .claude, id: "a", now: t0)
        state.setSignedIn(.cli, provider: .claude, id: "a", now: t0)
        state.setSignedIn(.desktop, provider: .claude, id: "b", now: t0)
        #expect(state.account(.claude, "a")?.signedInOn == [.cli])
        #expect(state.account(.claude, "b")?.signedInOn == [.desktop])
        state.setSignedIn(.desktop, provider: .claude, id: nil, now: t0)
        #expect(state.account(.claude, "b")?.signedInOn == [])
    }

    @Test func newSignInFileAddsAccount() throws {
        let dir = try TempDir()
        let paths = HeadroomPaths(home: dir.url)
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        func signIn(_ account: String) throws -> String? {
            try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"t-\#(account)","account_id":"\#(account)"}}"#.utf8).write(to: paths.codexAuth)
            return CodexAPI.decodeAuth(try Data(contentsOf: paths.codexAuth))?.accountId
        }
        var state = HeadroomState()
        let first = try signIn("acct-1")
        state.setSignedIn(.codex, provider: .codex, id: first, now: t0)
        let second = try signIn("acct-2")
        state.setSignedIn(.codex, provider: .codex, id: second, now: t0 + 30)
        #expect(state.accounts.map(\.id) == ["acct-1", "acct-2"])
        #expect(state.account(.codex, "acct-1")?.signedInOn == [])
        #expect(state.account(.codex, "acct-2")?.signedInOn == [.codex])
    }

    @Test func restoredSignInClearsWhenItsSourceIsGone() {
        var state = HeadroomState()
        state.setSignedIn(.codex, provider: .codex, id: "acct-1", now: t0) // as restored from state.json
        let kept = state.signOutIfMissing(.codex, provider: .codex, sourcePresent: true, now: t0)
        let cleared = state.signOutIfMissing(.codex, provider: .codex, sourcePresent: false, now: t0)
        let again = state.signOutIfMissing(.codex, provider: .codex, sourcePresent: false, now: t0)
        #expect(!kept)
        #expect(cleared)
        #expect(!again)
        #expect(state.account(.codex, "acct-1")?.signedInOn == [])
    }

    @Test func newerReadingWinsAndOlderIsIgnored() {
        var state = HeadroomState()
        let first = state.apply(reading(50, at: t0), to: .codex, "x", now: t0)
        let older = state.apply(reading(10, at: t0 - 60, source: .codexLog), to: .codex, "x", now: t0)
        let newer = state.apply(reading(55, at: t0 + 60, source: .codexLog), to: .codex, "x", now: t0)
        #expect(first)
        #expect(!older)
        #expect(newer)
        #expect(state.account(.codex, "x")?.lastReading?.weekly?.percent == 55)
    }

    @Test func desktopSampleKeepsFutureResetFromLiveReading() {
        var state = HeadroomState()
        let reset = t0 + 3 * 86_400
        state.apply(reading(50, at: t0, resets: reset), to: .claude, "a", now: t0)
        state.apply(reading(52, at: t0 + 900, source: .desktopSample), to: .claude, "a", now: t0)
        #expect(state.account(.claude, "a")?.lastReading?.weekly == UsageWindow(percent: 52, resetsAt: reset))
        state.apply(reading(3, at: reset + 60, source: .desktopSample), to: .claude, "a", now: t0)
        #expect(state.account(.claude, "a")?.lastReading?.weekly == UsageWindow(percent: 3, resetsAt: nil))
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try TempDir()
        let file = dir.url.appending(path: "Headroom/state.json")
        var state = HeadroomState()
        state.setEmail("a@example.com", for: .claude, "a", now: t0)
        state.setSignedIn(.desktop, provider: .claude, id: "a", now: t0)
        state.apply(reading(70, at: t0, resets: t0 + 86_400), to: .claude, "a", now: t0)
        state.cliTimeline = [CLISignIn(accountUuid: "a", from: t0)]
        try StateStore.save(state, to: file)
        #expect(StateStore.load(from: file, now: t0) == state)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.fsPath)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func missingStateStartsEmpty() throws {
        let dir = try TempDir()
        #expect(StateStore.load(from: dir.url.appending(path: "state.json"), now: t0) == HeadroomState())
    }

    @Test func unreadableStateIsSetAside() throws {
        let dir = try TempDir()
        let file = try dir.write("state.json", "{ not json")
        #expect(StateStore.load(from: file, now: t0) == HeadroomState())
        #expect(!FileManager.default.fileExists(atPath: file.fsPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.fsPath) == ["state.unreadable-1792000000.json"])
    }
}
