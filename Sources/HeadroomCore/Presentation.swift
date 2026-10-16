import Foundation

public enum Level: Sendable, Equatable {
    case normal, warning, critical

    public init(percent: Double) {
        self = percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }
}

public enum ResetState: Sendable, Equatable {
    case resets(Date)
    case restarted(Date)
    case unknown
}

public struct MenuBarSegment: Sendable, Equatable {
    public var provider: Provider
    public var glyph: String
    public var percentText: String
    /// The effective weekly percent, or nil when there is no reading.
    public var percent: Double?
    public var level: Level
}

/// Display rules evaluated against one `now`, time zone and locale.
public struct Presentation: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale

    public init(now: Date, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
    }

    public func resetState(_ window: UsageWindow?) -> ResetState {
        guard let reset = window?.resetsAt else { return .unknown }
        return reset > now ? .resets(reset) : .restarted(reset)
    }

    /// The percent to show: 0 once the window's recorded reset has passed.
    public func effectivePercent(_ window: UsageWindow?) -> Double? {
        guard let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return 0 }
        return window.percent
    }

    /// The 5-hour window, unless it comes from a reading over five hours old with no reset time,
    /// which says nothing about now.
    public func currentSession(_ reading: Reading?) -> UsageWindow? {
        guard let reading, let session = reading.session else { return nil }
        if session.resetsAt == nil, now.timeIntervalSince(reading.takenAt) >= 5 * 3600 { return nil }
        return session
    }

    public func resetText(_ window: UsageWindow?, restartedLabel: String = "Week restarted") -> String {
        switch resetState(window) {
        case .resets(let date): "Resets \(dayTime(date)) (\(timeLeft(until: date)))"
        case .restarted(let date): "\(restartedLabel) \(dayTime(date))"
        case .unknown: "Reset time not known yet"
        }
    }

    public func staleText(_ reading: Reading) -> String? {
        now.timeIntervalSince(reading.takenAt) > 600 ? "as of \(timeText(reading.takenAt))" : nil
    }

    /// "01:26" today, "Tues 10:11" within six days, otherwise "Oct 3".
    public func timeText(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        if abs(now.timeIntervalSince(date)) < 6 * 86_400 { return dayTime(date) }
        return format(date, template: "MMMd")
    }

    /// "Thurs 02:40": a short weekday and a 24-hour clock.
    public func dayTime(_ date: Date) -> String {
        "\(Self.weekdays[calendar.component(.weekday, from: nearestMinute(date)) - 1]) \(clock(date))"
    }

    static let weekdays = ["Sun", "Mon", "Tues", "Wed", "Thurs", "Fri", "Sat"]

    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: nearestMinute(date))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "6d 15h", "2h 10m", "45m" or "<1m", counted to the minute the reset is shown at.
    func timeLeft(until date: Date) -> String {
        let minutes = Int(nearestMinute(date).timeIntervalSince(now) / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return minutes > 0 ? "\(rest)m" : "<1m"
    }

    /// Reset times arrive a fraction of a second early (21:59:59.856 for 22:00), so times show the nearest minute.
    func nearestMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    public func relative(_ date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// Model-scoped limits at or above 80 %.
    public func modelChips(_ reading: Reading?) -> [ScopedLimit] {
        (reading?.scoped ?? []).filter { limit in
            (effectivePercent(UsageWindow(percent: limit.percent, resetsAt: limit.resetsAt)) ?? 0) >= 80
        }
    }

    /// Most room left first; accounts at their limit by soonest reset; accounts with no reading last.
    public func sortedAccounts(_ accounts: [Account]) -> [Account] {
        accounts.sorted { lhs, rhs in
            let l = sortKey(lhs), r = sortKey(rhs)
            if l.group != r.group { return l.group < r.group }
            if l.value != r.value { return l.value < r.value }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func sortKey(_ account: Account) -> (group: Int, value: Double) {
        guard let percent = effectivePercent(account.lastReading?.weekly) else { return (2, 0) }
        if percent >= 100 {
            return (1, account.lastReading?.weekly?.resetsAt?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)
        }
        return (0, percent)
    }

    /// Claude: the desktop app's account, else the CLI's. Codex: the signed-in account.
    public func menuBar(_ accounts: [Account]) -> [MenuBarSegment] {
        let claude = accounts.first { $0.provider == .claude && $0.signedInOn.contains(.desktop) }
            ?? accounts.first { $0.provider == .claude && $0.signedInOn.contains(.cli) }
        let codex = accounts.first { $0.provider == .codex && $0.signedInOn.contains(.codex) }
        return [segment(.claude, "✳", claude), segment(.codex, ">_", codex)]
    }

    func segment(_ provider: Provider, _ glyph: String, _ account: Account?) -> MenuBarSegment {
        guard let percent = effectivePercent(account?.lastReading?.weekly) else {
            return MenuBarSegment(provider: provider, glyph: glyph, percentText: "–", percent: nil, level: .normal)
        }
        return MenuBarSegment(provider: provider, glyph: glyph, percentText: "\(Int(percent.rounded()))%", percent: percent,
                              level: Level(percent: percent))
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: nearestMinute(date))
    }
}
