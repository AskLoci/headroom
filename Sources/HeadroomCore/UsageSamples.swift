import Foundation

public struct UsageSample: Sendable, Equatable {
    public var takenAt: Date
    public var orgUuid: String
    public var weekly: Double
    public var fiveHour: Double?
}

/// The Claude desktop app's own usage samples (plan-usage-history.json), recorded for its signed-in org.
public enum UsageSamples {
    /// Session activity intervals per account.
    public typealias Activity = [String: [ClosedRange<Date>]]

    static let maxGap: TimeInterval = 30 * 60

    struct File: Decodable {
        struct Sample: Decodable {
            struct Usage: Decodable {
                let fh: Double?
                let sd: Double?
            }
            let t: Double?
            let org: String?
            let u: Usage?
        }
        let samples: [Sample]?
    }

    public static func parse(_ data: Data) throws -> [UsageSample] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return (file.samples ?? []).compactMap { sample in
            guard let t = sample.t, let org = sample.org, let weekly = sample.u?.sd else { return nil }
            return UsageSample(takenAt: Date(timeIntervalSince1970: t / 1000), orgUuid: org, weekly: weekly, fiveHour: sample.u?.fh)
        }
    }

    /// The account behind a sample. An org used by several accounts resolves to the account whose
    /// session activity is nearest the sample, within 30 minutes.
    public static func account(for sample: UsageSample, accountOrgs: [String: Set<String>], activity: Activity) -> String? {
        let candidates = accountOrgs.filter { $0.value.contains(sample.orgUuid) }.map(\.key)
        if candidates.count == 1 { return candidates[0] }
        let scored = candidates.compactMap { account -> (account: String, gap: TimeInterval)? in
            guard let gap = (activity[account] ?? []).map({ distance(sample.takenAt, $0) }).min(), gap <= maxGap else { return nil }
            return (account, gap)
        }
        return scored.min { $0.gap < $1.gap }?.account
    }

    static func distance(_ date: Date, _ range: ClosedRange<Date>) -> TimeInterval {
        if range.contains(date) { return 0 }
        return date < range.lowerBound ? range.lowerBound.timeIntervalSince(date) : date.timeIntervalSince(range.upperBound)
    }

    /// The newest sample per account, as readings without reset times.
    public static func latestReadings(_ samples: [UsageSample], accountOrgs: [String: Set<String>], activity: Activity) -> [String: Reading] {
        var readings: [String: Reading] = [:]
        for sample in samples.sorted(by: { $0.takenAt < $1.takenAt }) {
            guard let account = account(for: sample, accountOrgs: accountOrgs, activity: activity) else { continue }
            readings[account] = Reading(takenAt: sample.takenAt, weekly: UsageWindow(percent: sample.weekly, resetsAt: nil),
                                        session: sample.fiveHour.map { UsageWindow(percent: $0, resetsAt: nil) },
                                        source: .desktopSample)
        }
        return readings
    }
}
