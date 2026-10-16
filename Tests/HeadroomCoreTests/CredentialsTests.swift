import Foundation
import Testing
@testable import HeadroomCore

struct SafeStorageTests {
    @Test func derivesChromiumKey() throws {
        let key = try SafeStorage.deriveKey(password: "test-password")
        #expect(key.map { String(format: "%02x", $0) }.joined() == "c0ffe4c25f07f62bfc6ab011d9efa54e")
    }

    @Test func decryptsKnownVector() throws {
        // Produced independently with Python hashlib.pbkdf2_hmac and `openssl enc -aes-128-cbc -iv 2020…20`.
        let blob = Data(base64Encoded: "djEwCaVjxnbKT85PvjyV/CnH8ael438pGjUTMqEcUEfpiLI=")!
        let plain = try SafeStorage.decrypt(blob, key: SafeStorage.deriveKey(password: "test-password"))
        #expect(String(decoding: plain, as: UTF8.self) == #"{"hello":"headroom"}"#)
    }

    @Test func roundTrips() throws {
        let key = try SafeStorage.deriveKey(password: "another")
        let plain = Data(String(repeating: "headroom ", count: 40).utf8)
        let blob = try SafeStorage.encrypt(plain, key: key)
        #expect(blob.starts(with: Data("v10".utf8)))
        #expect(try SafeStorage.decrypt(blob, key: key) == plain)
    }

    @Test func rejectsMissingPrefix() throws {
        let key = try SafeStorage.deriveKey(password: "x")
        #expect(throws: SafeStorageError.badPrefix) { try SafeStorage.decrypt(Data("v11abc".utf8), key: key) }
    }
}

struct DesktopTokenCacheTests {
    let a = "11111111-2222-4333-8444-555555555555"
    let b = "99999999-2222-4333-8444-555555555555"
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func config(lastKnown: String?, key: [UInt8]) throws -> Data {
        let cache = """
        {"acct:\(a)|9d1c250a-e61b-44d9|user:inference":{"token":"token-a-long","refreshToken":"r1","expiresAt":1823442421914,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
         "acct:\(a)|a473d7bb-17ac-43a7|user:profile":{"token":"token-a-short","refreshToken":"r2","expiresAt":1794498422564,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
         "acct:\(a)|old|x":{"token":"token-a-expired","refreshToken":"r3","expiresAt":1700000000000,"subscriptionType":"max"},
         "acct:\(b)|9d1c250a|x":{"token":"token-b","refreshToken":"r4","expiresAt":1830000000000,"subscriptionType":"pro"}}
        """
        var object: [String: Any] = ["locale": "en-US", "oauth:tokenCacheV2": try SafeStorage.encrypt(Data(cache.utf8), key: key).base64EncodedString()]
        if let lastKnown { object["lastKnownAccountUuid"] = lastKnown }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func currentAccountTokensNewestExpiryFirst() throws {
        let key = try SafeStorage.deriveKey(password: "pw")
        let signIn = try DesktopTokenCache.signIn(config: config(lastKnown: a, key: key), key: key, now: now)
        #expect(signIn.accountUuid == a)
        #expect(signIn.tokens.map(\.token) == ["token-a-long", "token-a-short"])
        #expect(signIn.tokens.first?.plan == "Max 20x")
    }

    @Test func withoutLastKnownAccountUsesLatestExpiringToken() throws {
        let key = try SafeStorage.deriveKey(password: "pw")
        let signIn = try DesktopTokenCache.signIn(config: config(lastKnown: nil, key: key), key: key, now: now)
        #expect(signIn.accountUuid == b)
        #expect(signIn.tokens.map(\.token) == ["token-b"])
        #expect(signIn.tokens.first?.plan == "Pro")
    }

    @Test func wrongKeyThrows() throws {
        let key = try SafeStorage.deriveKey(password: "pw")
        let data = try config(lastKnown: a, key: key)
        let wrong = try SafeStorage.deriveKey(password: "nope")
        #expect(throws: (any Error).self) { try DesktopTokenCache.signIn(config: data, key: wrong, now: now) }
    }

    @Test func lastKnownAccountWithoutTokenCache() throws {
        let key = try SafeStorage.deriveKey(password: "pw")
        #expect(DesktopTokenCache.lastKnownAccount(try config(lastKnown: a, key: key)) == a)
        let plain = Data(#"{"lastKnownAccountUuid":"x"}"#.utf8)
        #expect(try DesktopTokenCache.signIn(config: plain, key: key, now: now) == DesktopSignIn(accountUuid: "x", tokens: []))
    }
}

struct CLICredentialsTests {
    let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-example","refreshToken":"sk-ant-ort01-example","expiresAt":1792030000000,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#

    @Test func parsesJSONValue() {
        let token = CLICredentials.parse(json + "\n")
        #expect(token == CLIToken(accessToken: "sk-ant-oat01-example", expiresAt: Date(timeIntervalSince1970: 1_792_030_000), plan: "Max 20x"))
        #expect(token?.isExpired(at: Date(timeIntervalSince1970: 1_792_030_001)) == true)
        #expect(token?.isExpired(at: Date(timeIntervalSince1970: 1_792_029_000)) == false)
    }

    @Test func parsesHexEncodedValue() {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(CLICredentials.parse(hex)?.accessToken == "sk-ant-oat01-example")
    }

    @Test func rejectsOtherValues() {
        #expect(CLICredentials.parse("not a credential") == nil)
        #expect(CLICredentials.parse(#"{"mcpOAuth":{}}"#) == nil)
    }

    @Test func parsesKeychainDates() throws {
        let dates = KeychainAttributes.parse(String(decoding: try Fixture.data("keychain-attributes.txt"), as: UTF8.self))
        #expect(dates.created == Date(timeIntervalSince1970: 1_791_664_723))
        #expect(dates.modified == Date(timeIntervalSince1970: 1_792_025_202))
    }

    @Test func readsClaudeJSONAccountPair() {
        let json = #"{"numStartups":3,"oauthAccount":{"accountUuid":"acct-a","emailAddress":"Person@Example.com","organizationUuid":"org"}}"#
        let pair = ClaudeAccountFile.oauthAccount(Data(json.utf8))
        #expect(pair?.accountUuid == "acct-a")
        #expect(pair?.email == "person@example.com")
        #expect(ClaudeAccountFile.oauthAccount(Data("{}".utf8)) == nil)
    }
}
