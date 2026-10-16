import Foundation

public struct DesktopToken: Sendable, Equatable {
    public var accountUuid: String
    public var token: String
    public var expiresAt: Date?
    public var plan: String?
}

public struct DesktopSignIn: Sendable, Equatable {
    public var accountUuid: String?
    /// Unexpired tokens for `accountUuid`, latest expiry first.
    public var tokens: [DesktopToken]

    public init(accountUuid: String?, tokens: [DesktopToken]) {
        self.accountUuid = accountUuid
        self.tokens = tokens
    }
}

/// Reads the Claude desktop app's current account and tokens from its config.json.
public enum DesktopTokenCache {
    struct Config: Decodable {
        let lastKnownAccountUuid: String?
        let tokenCacheV2: String?

        enum CodingKeys: String, CodingKey {
            case lastKnownAccountUuid
            case tokenCacheV2 = "oauth:tokenCacheV2"
        }
    }

    struct Entry: Decodable {
        let token: String?
        let expiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    public static func lastKnownAccount(_ config: Data) -> String? {
        (try? JSONDecoder().decode(Config.self, from: config))?.lastKnownAccountUuid
    }

    /// Decrypts `oauth:tokenCacheV2`. Entries are keyed `acct:<accountUuid>|<clientId>|…`.
    public static func signIn(config: Data, key: [UInt8], now: Date) throws -> DesktopSignIn {
        let parsed = try JSONDecoder().decode(Config.self, from: config)
        guard let encoded = parsed.tokenCacheV2, let blob = Data(base64Encoded: encoded) else {
            return DesktopSignIn(accountUuid: parsed.lastKnownAccountUuid, tokens: [])
        }
        let entries = try JSONDecoder().decode([String: Entry].self, from: SafeStorage.decrypt(blob, key: key))
        let tokens = entries.compactMap { name, entry -> DesktopToken? in
            guard name.hasPrefix("acct:"), let token = entry.token, !token.isEmpty else { return nil }
            let expires = entry.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            if let expires, expires <= now { return nil }
            return DesktopToken(accountUuid: String(name.dropFirst(5).prefix { $0 != "|" }), token: token, expiresAt: expires,
                                plan: ClaudeAPI.planName(type: entry.subscriptionType, tier: entry.rateLimitTier))
        }
        let latestFirst = tokens.sorted { ($0.expiresAt ?? .distantFuture) > ($1.expiresAt ?? .distantFuture) }
        let account = parsed.lastKnownAccountUuid ?? latestFirst.first?.accountUuid
        return DesktopSignIn(accountUuid: account, tokens: latestFirst.filter { $0.accountUuid == account })
    }
}
