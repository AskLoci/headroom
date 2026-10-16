import Foundation

public struct CLIToken: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var plan: String?

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// The Claude Code CLI's sign-in, stored in the Keychain item "Claude Code-credentials" (or ~/.claude/.credentials.json).
public enum CLICredentials {
    struct Value: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
        }
        let claudeAiOauth: OAuth?
    }

    /// Parses the stored value, which is JSON or hex-encoded JSON.
    public static func parse(_ raw: String) -> CLIToken? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var data = Data(trimmed.utf8)
        if !trimmed.hasPrefix("{"), let decoded = hexDecode(trimmed) { data = decoded }
        guard let value = try? JSONDecoder().decode(Value.self, from: data),
              let oauth = value.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty
        else { return nil }
        return CLIToken(accessToken: token, expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                        plan: ClaudeAPI.planName(type: oauth.subscriptionType, tier: oauth.rateLimitTier))
    }

    static func hexDecode(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let byte = UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        return data
    }
}

public struct KeychainItemDates: Sendable, Equatable {
    public var created: Date?
    public var modified: Date?

    public init(created: Date?, modified: Date?) {
        self.created = created
        self.modified = modified
    }
}

/// Reads item dates from `security find-generic-password` attribute output (no secret involved).
public enum KeychainAttributes {
    public static func parse(_ output: String) -> KeychainItemDates {
        KeychainItemDates(created: date(named: "cdat", in: output), modified: date(named: "mdat", in: output))
    }

    static func date(named name: String, in output: String) -> Date? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("\"\(name)\"<timedate>") }),
              let match = line.firstMatch(of: /"(\d{14})Z/)
        else { return nil }
        let s = Array(match.1)
        let iso = "\(String(s[0..<4]))-\(String(s[4..<6]))-\(String(s[6..<8]))T\(String(s[8..<10])):\(String(s[10..<12])):\(String(s[12..<14]))Z"
        return ISODate.parse(iso)
    }
}

/// ~/.claude.json records the account and email Claude Code last used together.
public enum ClaudeAccountFile {
    struct File: Decodable {
        struct OAuthAccount: Decodable {
            let accountUuid: String?
            let emailAddress: String?
        }
        let oauthAccount: OAuthAccount?
    }

    public static func oauthAccount(_ data: Data) -> (accountUuid: String, email: String)? {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              let uuid = file.oauthAccount?.accountUuid, let email = file.oauthAccount?.emailAddress,
              !uuid.isEmpty, !email.isEmpty
        else { return nil }
        return (uuid, email.lowercased())
    }
}
