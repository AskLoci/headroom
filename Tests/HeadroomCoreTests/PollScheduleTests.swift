import Foundation
import Testing
@testable import HeadroomCore

struct PollScheduleTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func dueUntilSuccessThenEveryTwoMinutes() {
        var schedule = PollSchedule()
        #expect(schedule.isDue("cli", now: t0))
        schedule.succeeded("cli", now: t0)
        #expect(!schedule.isDue("cli", now: t0 + 119))
        #expect(schedule.isDue("cli", now: t0 + 120))
    }

    @Test func transientFailuresBackOff() {
        var schedule = PollSchedule()
        var now = t0
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            schedule.failedTransiently("codex", now: now)
            var next = now
            while !schedule.isDue("codex", now: next) { next += 60 }
            waits.append(next.timeIntervalSince(now))
            now = next
        }
        #expect(waits == [120, 240, 480, 900, 900])
    }

    @Test func authFailureWaitsForSignInChange() {
        var schedule = PollSchedule()
        schedule.failedAuth("desktop")
        #expect(schedule.isSetAside("desktop"))
        #expect(!schedule.isDue("desktop", now: t0 + 86_400))
        schedule.pollNow()
        #expect(!schedule.isDue("desktop", now: t0))
        schedule.signInChanged("desktop")
        #expect(schedule.isDue("desktop", now: t0))
    }

    @Test func pollNowMakesEverythingDue() {
        var schedule = PollSchedule()
        schedule.succeeded("cli", now: t0)
        schedule.pollNow()
        #expect(schedule.isDue("cli", now: t0))
    }
}

struct TranscriptRefreshPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func dueAtFirstRefresh() {
        #expect(TranscriptRefreshPolicy().isDue(visible: false, now: t0))
    }

    @Test func changesWaitWhileHidden() {
        var policy = TranscriptRefreshPolicy()
        policy.refreshed(at: t0)
        policy.filesChanged()
        #expect(!policy.isDue(visible: false, now: t0 + 29))
        #expect(policy.isDue(visible: false, now: t0 + 30))
    }

    @Test func changesApplyAtOnceWhileVisible() {
        var policy = TranscriptRefreshPolicy()
        policy.refreshed(at: t0)
        #expect(!policy.isDue(visible: true, now: t0 + 1))
        policy.filesChanged()
        #expect(policy.isDue(visible: true, now: t0 + 1))
    }

    @Test func rescansEveryFiveMinutesWithoutEvents() {
        var policy = TranscriptRefreshPolicy()
        policy.refreshed(at: t0)
        #expect(!policy.isDue(visible: false, now: t0 + 299))
        #expect(policy.isDue(visible: false, now: t0 + 300))
    }
}
