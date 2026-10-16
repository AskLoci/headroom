import Foundation

/// The Claude Code CLI's account from `from` until the next entry.
public struct CLISignIn: Codable, Sendable, Equatable {
    public var accountUuid: String
    public var from: Date
}

public enum OwnerSource: String, Codable, Sendable {
    case desktopMetadata, bridge, injectedEmail, cliTimeline
}

public struct TranscriptOwner: Sendable, Equatable {
    public var accountUuid: String
    public var source: OwnerSource
}

public enum Attribution {
    public static func cliAccount(at date: Date, timeline: [CLISignIn]) -> String? {
        timeline.filter { $0.from <= date }.max { $0.from < $1.from }?.accountUuid
    }

    /// Owner of a Claude transcript: desktop metadata, then the bridge-session owner, then the injected
    /// email, then (for CLI and SDK entry points) the CLI sign-in at the transcript's first timestamp.
    public static func owner(desktopAccount: String?, scan: TranscriptScan?, emailToAccount: [String: String],
                             timeline: [CLISignIn]) -> TranscriptOwner? {
        if let desktopAccount { return TranscriptOwner(accountUuid: desktopAccount, source: .desktopMetadata) }
        guard let scan else { return nil }
        if let bridge = scan.bridgeOwner { return TranscriptOwner(accountUuid: bridge, source: .bridge) }
        if let email = scan.injectedEmail, let account = emailToAccount[email] {
            return TranscriptOwner(accountUuid: account, source: .injectedEmail)
        }
        if let entrypoint = scan.entrypoint, entrypoint != "claude-desktop", let started = scan.firstTimestamp,
           let account = cliAccount(at: started, timeline: timeline) {
            return TranscriptOwner(accountUuid: account, source: .cliTimeline)
        }
        return nil
    }

    /// The most common email per account; ties go to the alphabetically first email.
    public static func majorityEmails(_ votes: [(account: String, email: String)]) -> [String: String] {
        var tallies: [String: [String: Int]] = [:]
        for vote in votes { tallies[vote.account, default: [:]][vote.email, default: 0] += 1 }
        return tallies.compactMapValues { tally in
            tally.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
        }
    }

    /// Appends an entry when the CLI account differs from the latest one. Returns whether it did.
    @discardableResult
    public static func recordCLISignIn(_ account: String, at date: Date, timeline: inout [CLISignIn]) -> Bool {
        if timeline.max(by: { $0.from < $1.from })?.accountUuid == account { return false }
        timeline.append(CLISignIn(accountUuid: account, from: date))
        return true
    }
}
