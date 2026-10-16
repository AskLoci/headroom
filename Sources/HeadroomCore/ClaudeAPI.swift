import Foundation

public struct ClaudeProfile: Sendable, Equatable {
    public var accountUuid: String
    public var email: String
    public var organizationUuid: String?
    public var plan: String?
}

public enum ClaudeAPI {
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func headers(token: String, version: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "Headroom/\(version)",
        ]
    }

    struct ProfileBody: Decodable {
        struct AccountBody: Decodable {
            let uuid: String
            let email: String
        }
        struct OrganizationBody: Decodable {
            let uuid: String?
            let organization_type: String?
            let rate_limit_tier: String?
        }
        let account: AccountBody
        let organization: OrganizationBody?
    }

    public static func decodeProfile(_ data: Data) throws -> ClaudeProfile {
        let body = try JSONDecoder().decode(ProfileBody.self, from: data)
        return ClaudeProfile(
            accountUuid: body.account.uuid,
            email: body.account.email,
            organizationUuid: body.organization?.uuid,
            plan: planName(type: body.organization?.organization_type, tier: body.organization?.rate_limit_tier)
        )
    }

    struct WindowBody: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct LimitBody: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }

    struct UsageBody: Decodable {
        let five_hour: WindowBody?
        let seven_day: WindowBody?
        let limits: [LimitBody]?
    }

    public static func decodeUsage(_ data: Data, takenAt: Date) throws -> Reading {
        let body = try JSONDecoder().decode(UsageBody.self, from: data)
        let limits = body.limits ?? []

        func window(_ primary: WindowBody?, kind: String) -> UsageWindow? {
            if let primary, let utilization = primary.utilization {
                return UsageWindow(percent: utilization, resetsAt: primary.resets_at.flatMap(ISODate.parse))
            }
            if let limit = limits.first(where: { $0.kind == kind }), let percent = limit.percent {
                return UsageWindow(percent: percent, resetsAt: limit.resets_at.flatMap(ISODate.parse))
            }
            return nil
        }

        let scoped = limits.filter { $0.kind == "weekly_scoped" }.compactMap { limit -> ScopedLimit? in
            guard let percent = limit.percent else { return nil }
            return ScopedLimit(name: limit.scope?.model?.display_name ?? "Model", percent: percent,
                               resetsAt: limit.resets_at.flatMap(ISODate.parse))
        }

        return Reading(takenAt: takenAt, weekly: window(body.seven_day, kind: "weekly_all"),
                       session: window(body.five_hour, kind: "session"), scoped: scoped, source: .live)
    }

    /// "Max 20x", "Pro", "Team"… from an organization type or subscription type plus a rate-limit tier.
    public static func planName(type: String?, tier: String?) -> String? {
        let kind = (type ?? "").lowercased()
        let base: String
        if kind.contains("max") { base = "Max" }
        else if kind.contains("pro") { base = "Pro" }
        else if kind.contains("team") { base = "Team" }
        else if kind.contains("enterprise") { base = "Enterprise" }
        else if kind.contains("free") { base = "Free" }
        else { return nil }
        if let tier, let multiple = tier.firstMatch(of: /\d+x/) {
            return "\(base) \(multiple.output)"
        }
        return base
    }
}
