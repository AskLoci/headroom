import Foundation

/// Removes recognizable credentials from exports, including their headers and command summaries.
/// This is a best-effort filter, not a guarantee that arbitrary confidential text is safe to share.
public enum SecretRedactor {
    public static let replacement = "[REDACTED]"

    private static let rules: [(pattern: String, template: String)] = [
        (#"(?s)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----.*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)"#, "[REDACTED PRIVATE KEY]"),
        (#"\b(?:sk-(?:ant-[A-Za-z0-9_-]+|proj-[A-Za-z0-9_-]+|[A-Za-z0-9_-]{16,})|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{12,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b"#, replacement),
        (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, replacement),
        (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9_./+=-]+"#, "$1 [REDACTED]"),
        (#"(?i)(\b(?:Cookie|Set-Cookie):\s*)(?!\[REDACTED\])[^\r\n\"'`]+"#, "$1[REDACTED]"),
        (#"(?i)((?:[\"']?\b(?:[a-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|client[_-]?secret|secret(?:[_-]?access[_-]?key)?|authorization|cookie|set-cookie)\b[\"']?)\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,;&}\[\]`]+)"#, "$1[REDACTED]"),
        (#"(?i)(--(?:api-key|access-token|refresh-token|token|password|client-secret)\s+)(?:\"[^\"]*\"|'[^']*'|[^\s]+)"#, "$1[REDACTED]"),
        (#"(?i)(https?://)[^\s/@:]+:[^\s/@]+@"#, "$1[REDACTED]@"),
    ]

    public static func redact(_ text: String) -> String {
        rules.reduce(text) { result, rule in
            result.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
    }
}

#if DEBUG && canImport(Testing)
import Testing

struct SecretRedactorTests {
    @Test(arguments: [
        "sk-ant-oat01-audit-placeholder", "sk-proj-audit-placeholder", "ghp_abcdefghijklmnop",
        "github_pat_abcdefghijklmnop", "AKIAABCDEFGHIJKLMNOP", "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhdWRpdCJ9.signature",
    ])
    func removesKnownTokens(_ token: String) {
        #expect(SecretRedactor.redact("Use \(token) here") == "Use [REDACTED] here")
    }

    @Test(arguments: [
        "API_KEY=hidden-value", "export OPENAI_API_KEY='hidden-value'", "{\"access_token\":\"hidden-value\"}",
        "password: \"hidden-value with spaces\"", "--password 'hidden-value with spaces'", "Bearer hidden-value",
        "Authorization: Basic hidden-value", "https://user:hidden-value@example.com", "?token=hidden-value&x=1",
        "AWS_SECRET_ACCESS_KEY=hidden-value", "clientSecret=hidden-value", "refreshToken=hidden-value",
        "curl -H 'Cookie: session=hidden-value; other=hidden-value' example.com",
    ])
    func removesNamedSecrets(_ text: String) {
        #expect(!SecretRedactor.redact(text).contains("hidden-value"))
        #expect(SecretRedactor.redact(text).contains("[REDACTED]"))
    }

    @Test func removesMultilineAndIncompletePrivateKeys() {
        let key = "-----BEGIN RSA PRIVATE KEY-----\nprivate-material\n-----END RSA PRIVATE KEY-----"
        #expect(SecretRedactor.redact("before\n\(key)\nafter") == "before\n[REDACTED PRIVATE KEY]\nafter")
        #expect(SecretRedactor.redact("-----BEGIN PRIVATE KEY-----\nprivate-material") == "[REDACTED PRIVATE KEY]")
    }

    @Test func repeatedRedactionIsStable() {
        let text = "API_KEY=hidden-value; Authorization: Bearer hidden-value"
        let redacted = SecretRedactor.redact(text)
        #expect(SecretRedactor.redact(redacted) == redacted)
    }

    @Test func preservesOrdinaryConversation() {
        let text = "Add dark mode. The token count is 42. Email alex@example.com. Run swift test."
        #expect(SecretRedactor.redact(text) == text)
    }
}
#endif
