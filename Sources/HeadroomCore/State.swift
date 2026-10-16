import Foundation

/// Everything Headroom remembers between launches. Holds no tokens, keys or transcript text.
public struct HeadroomState: Codable, Sendable, Equatable {
    public var version = 1
    public var accounts: [Account] = []
    public var cliTimeline: [CLISignIn] = []
    /// Claude account UUID → email, from the profile endpoint, ~/.claude.json and the transcript backfill.
    public var claudeEmails: [String: String] = [:]
    public var emailBackfillDone = false

    public init() {}

    public func account(_ provider: Provider, _ id: String) -> Account? {
        accounts.first { $0.provider == provider && $0.id == id }
    }

    @discardableResult
    public mutating func upsert(_ provider: Provider, _ id: String, now: Date) -> Int {
        if let index = accounts.firstIndex(where: { $0.provider == provider && $0.id == id }) { return index }
        accounts.append(Account(provider: provider, id: id, email: provider == .claude ? claudeEmails[id] : nil,
                                firstSeen: now, lastSeen: now))
        return accounts.count - 1
    }

    public mutating func setEmail(_ email: String, for provider: Provider, _ id: String, now: Date) {
        let normalized = email.lowercased()
        let index = upsert(provider, id, now: now)
        accounts[index].email = normalized
        if provider == .claude { claudeEmails[id] = normalized }
    }

    public mutating func setPlan(_ plan: String?, for provider: Provider, _ id: String, now: Date) {
        guard let plan else { return }
        let index = upsert(provider, id, now: now)
        accounts[index].plan = plan
    }

    /// Marks `id` as the account signed into `surface` and clears that surface from every other
    /// account of the provider. A nil id signs the surface out.
    public mutating func setSignedIn(_ surface: Surface, provider: Provider, id: String?, now: Date) {
        for index in accounts.indices where accounts[index].provider == provider {
            accounts[index].signedInOn.remove(surface)
        }
        guard let id else { return }
        let index = upsert(provider, id, now: now)
        accounts[index].signedInOn.insert(surface)
        accounts[index].lastSeen = now
    }

    /// Signs `surface` out when its source is gone, including a sign-in restored from the saved state.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func signOutIfMissing(_ surface: Surface, provider: Provider, sourcePresent: Bool, now: Date) -> Bool {
        guard !sourcePresent, accounts.contains(where: { $0.provider == provider && $0.signedInOn.contains(surface) }) else { return false }
        setSignedIn(surface, provider: provider, id: nil, now: now)
        return true
    }

    /// Keeps the newer reading. A desktop sample, which has no reset time, keeps the previous
    /// reading's reset time while that time is still ahead of the sample.
    @discardableResult
    public mutating func apply(_ reading: Reading, to provider: Provider, _ id: String, now: Date) -> Bool {
        let index = upsert(provider, id, now: now)
        let current = accounts[index].lastReading
        if let current, current.takenAt >= reading.takenAt { return false }
        var next = reading
        if next.source == .desktopSample, let current {
            if next.weekly?.resetsAt == nil, let reset = current.weekly?.resetsAt, reset > next.takenAt {
                next.weekly?.resetsAt = reset
            }
            if next.session?.resetsAt == nil, let reset = current.session?.resetsAt, reset > next.takenAt {
                next.session?.resetsAt = reset
            }
        }
        accounts[index].lastReading = next
        accounts[index].lastSeen = max(accounts[index].lastSeen, next.takenAt)
        return true
    }
}

public enum StateStore {
    /// A missing file gives an empty state. An unreadable one is moved aside, not overwritten.
    public static func load(from url: URL, now: Date) -> HeadroomState {
        guard let data = try? Data(contentsOf: url) else { return HeadroomState() }
        do {
            return try decoder.decode(HeadroomState.self, from: data)
        } catch {
            let aside = url.deletingLastPathComponent().appending(path: "state.unreadable-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return HeadroomState()
        }
    }

    public static func save(_ state: HeadroomState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.fsPath)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
