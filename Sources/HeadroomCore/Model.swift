import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

/// A place on this Mac where an account can be signed in.
public enum Surface: String, Codable, Sendable, CaseIterable, Comparable {
    case desktop, cli, codex

    public var label: String {
        switch self {
        case .desktop: "Desktop"
        case .cli: "CLI"
        case .codex: "Codex"
        }
    }

    public static func < (lhs: Surface, rhs: Surface) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct UsageWindow: Codable, Sendable, Equatable {
    public var percent: Double
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct ScopedLimit: Codable, Sendable, Equatable {
    public var name: String
    public var percent: Double
    public var resetsAt: Date?

    public init(name: String, percent: Double, resetsAt: Date?) {
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public enum ReadingSource: String, Codable, Sendable {
    case live, desktopSample, codexLog
}

public struct Reading: Codable, Sendable, Equatable {
    public var takenAt: Date
    public var weekly: UsageWindow?
    public var session: UsageWindow?
    public var scoped: [ScopedLimit]
    public var source: ReadingSource

    public init(takenAt: Date, weekly: UsageWindow?, session: UsageWindow?, scoped: [ScopedLimit] = [], source: ReadingSource) {
        self.takenAt = takenAt
        self.weekly = weekly
        self.session = session
        self.scoped = scoped
        self.source = source
    }
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public var provider: Provider
    /// Claude account UUID or Codex account_id.
    public var id: String
    public var email: String?
    public var plan: String?
    public var signedInOn: Set<Surface>
    public var lastReading: Reading?
    public var firstSeen: Date
    public var lastSeen: Date

    public init(provider: Provider, id: String, email: String? = nil, plan: String? = nil,
                signedInOn: Set<Surface> = [], lastReading: Reading? = nil, firstSeen: Date, lastSeen: Date) {
        self.provider = provider
        self.id = id
        self.email = email
        self.plan = plan
        self.signedInOn = signedInOn
        self.lastReading = lastReading
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    /// Unique across providers.
    public var key: String { Account.key(provider, id) }

    public static func key(_ provider: Provider, _ id: String) -> String { "\(provider.rawValue):\(id)" }

    public var displayName: String {
        if let email { return email }
        let short = id.prefix(8)
        return provider == .claude ? "Claude account \(short)" : "Codex account \(short)"
    }
}
