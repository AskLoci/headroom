import Foundation

public struct CodexAuth: Sendable, Equatable {
    public var accessToken: String
    public var accountId: String
    public var email: String?
    public var plan: String?
}

public struct CodexUsage: Sendable, Equatable {
    public var reading: Reading
    public var email: String?
    public var plan: String?
    public var accountId: String?
}

public struct RolloutSnapshot: Sendable, Equatable {
    public var reading: Reading
    /// The thread's `creator_account_id`, when the rollout records one.
    public var accountId: String?
}

public enum CodexAPI {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func headers(auth: CodexAuth, version: String) -> [String: String] {
        [
            "Authorization": "Bearer \(auth.accessToken)",
            "ChatGPT-Account-Id": auth.accountId,
            "User-Agent": "Headroom/\(version)",
        ]
    }

    struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let id_token: String?
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    /// The ChatGPT sign-in in ~/.codex/auth.json, or nil when Codex is signed out or uses an API key.
    public static func decodeAuth(_ data: Data) -> CodexAuth? {
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let tokens = file.tokens, let access = tokens.access_token, let account = tokens.account_id,
              !access.isEmpty, !account.isEmpty
        else { return nil }
        let claims = tokens.id_token.flatMap(claims(fromJWT:)) ?? [:]
        let openAI = claims["https://api.openai.com/auth"] as? [String: Any]
        return CodexAuth(accessToken: access, accountId: account, email: claims["email"] as? String,
                         plan: (openAI?["chatgpt_plan_type"] as? String).map(planName))
    }

    public static func claims(fromJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func planName(_ raw: String) -> String {
        raw.prefix(1).uppercased() + raw.dropFirst()
    }

    struct WindowBody: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Double?
        let reset_at: Double?
    }

    struct UsageBody: Decodable {
        struct RateLimit: Decodable {
            let primary_window: WindowBody?
            let secondary_window: WindowBody?
        }
        let email: String?
        let plan_type: String?
        let account_id: String?
        let rate_limit: RateLimit?
    }

    public static func decodeUsage(_ data: Data, takenAt: Date) throws -> CodexUsage {
        let body = try JSONDecoder().decode(UsageBody.self, from: data)
        let windows = [body.rate_limit?.primary_window, body.rate_limit?.secondary_window].compactMap { w -> (Double, UsageWindow)? in
            guard let w, let percent = w.used_percent, let seconds = w.limit_window_seconds else { return nil }
            return (seconds, UsageWindow(percent: percent, resetsAt: w.reset_at.map { Date(timeIntervalSince1970: $0) }))
        }
        let (weekly, session) = classify(windows)
        return CodexUsage(reading: Reading(takenAt: takenAt, weekly: weekly, session: session, source: .live),
                          email: body.email, plan: body.plan_type.map(planName), accountId: body.account_id)
    }

    /// Weekly: the longest window of at least five days. Session: the shortest window under five days.
    static func classify(_ windows: [(seconds: Double, window: UsageWindow)]) -> (weekly: UsageWindow?, session: UsageWindow?) {
        let fiveDays = 5.0 * 86_400
        let weekly = windows.filter { $0.seconds >= fiveDays }.max { $0.seconds < $1.seconds }?.window
        let session = windows.filter { $0.seconds < fiveDays }.min { $0.seconds < $1.seconds }?.window
        return (weekly, session)
    }

    struct RolloutLine: Decodable {
        struct Payload: Decodable {
            struct RateLimits: Decodable {
                struct Window: Decodable {
                    let used_percent: Double?
                    let window_minutes: Double?
                    let resets_at: Double?
                }
                let limit_id: String?
                let primary: Window?
                let secondary: Window?
            }
            let type: String?
            let rate_limits: RateLimits?
        }
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    /// The rate-limit snapshot in one rollout line of type event_msg/token_count.
    public static func snapshot(fromLine line: Data) -> Reading? {
        guard let parsed = try? JSONDecoder().decode(RolloutLine.self, from: line),
              parsed.type == "event_msg", parsed.payload?.type == "token_count",
              let limits = parsed.payload?.rate_limits, (limits.limit_id ?? "codex") == "codex",
              let takenAt = parsed.timestamp.flatMap(ISODate.parse)
        else { return nil }
        let windows = [limits.primary, limits.secondary].compactMap { w -> (Double, UsageWindow)? in
            guard let w, let percent = w.used_percent, let minutes = w.window_minutes else { return nil }
            return (minutes * 60, UsageWindow(percent: percent, resetsAt: w.resets_at.map { Date(timeIntervalSince1970: $0) }))
        }
        guard !windows.isEmpty else { return nil }
        let (weekly, session) = classify(windows)
        return Reading(takenAt: takenAt, weekly: weekly, session: session, source: .codexLog)
    }

    /// The newest snapshot in a rollout and the account that created its thread.
    public static func latestSnapshot(rollout url: URL) -> RolloutSnapshot? {
        let account = (try? LineReader.firstLine(url: url)).flatMap(creatorAccount)
        var reading: Reading?
        for line in (try? LineReader.tailLines(url: url, maxBytes: 512 * 1024)) ?? [] where line.containsBytes("\"token_count\"") {
            if let found = snapshot(fromLine: line) {
                reading = found
                break
            }
        }
        if reading == nil {
            _ = try? LineReader.forEachLine(url: url, from: 0) { line, _ in
                if line.containsBytes("\"token_count\""), let found = snapshot(fromLine: Data(line)) { reading = found }
                return true
            }
        }
        return reading.map { RolloutSnapshot(reading: $0, accountId: account) }
    }

    struct SessionMeta: Decodable {
        struct Payload: Decodable { let creator_account_id: String? }
        let type: String?
        let payload: Payload?
    }

    static func creatorAccount(_ line: Data) -> String? {
        guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: line), meta.type == "session_meta" else { return nil }
        return meta.payload?.creator_account_id
    }
}

public enum CodexRollouts {
    /// The most recently modified rollout in the day folders for `now` and the two days before it.
    /// Codex names day folders by local date.
    public static func newest(sessionsRoot: URL, now: Date, calendar: Calendar = .current) -> URL? {
        var best: (url: URL, modified: Date)?
        for daysBack in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let folder = sessionsRoot.appending(path: String(format: "%04d/%02d/%02d", year, month, dayOfMonth), directoryHint: .isDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                if best == nil || modified > best!.modified { best = (url, modified) }
            }
        }
        return best?.url
    }
}
