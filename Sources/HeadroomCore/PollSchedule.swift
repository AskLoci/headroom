import Foundation

/// When each surface is next polled. Transient failures back off 2, 4, 8, then 15 minutes; an
/// authorization failure sets the surface aside until its sign-in changes.
public struct PollSchedule: Sendable {
    public static let interval: TimeInterval = 120
    public static let backoff: [TimeInterval] = [120, 240, 480, 900]

    private var nextDue: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var setAside: Set<String> = []

    public init() {}

    public func isDue(_ key: String, now: Date) -> Bool {
        !setAside.contains(key) && (nextDue[key].map { $0 <= now } ?? true)
    }

    public func isSetAside(_ key: String) -> Bool {
        setAside.contains(key)
    }

    public mutating func succeeded(_ key: String, now: Date) {
        failures[key] = 0
        setAside.remove(key)
        nextDue[key] = now.addingTimeInterval(Self.interval)
    }

    public mutating func failedTransiently(_ key: String, now: Date) {
        let count = failures[key, default: 0]
        failures[key] = count + 1
        nextDue[key] = now.addingTimeInterval(Self.backoff[min(count, Self.backoff.count - 1)])
    }

    public mutating func failedAuth(_ key: String) {
        setAside.insert(key)
    }

    public mutating func signInChanged(_ key: String) {
        setAside.remove(key)
        failures[key] = 0
        nextDue[key] = nil
    }

    /// Makes every surface that is not set aside due now (wake from sleep, Refresh).
    public mutating func pollNow() {
        nextDue.removeAll()
    }
}

/// When transcript lists are rebuilt: at once after a change while the popover is open, otherwise
/// at most every 30 seconds, and every 5 minutes even without file events.
public struct TranscriptRefreshPolicy: Sendable {
    public static let hiddenInterval: TimeInterval = 30
    public static let rescanInterval: TimeInterval = 300

    private var dirty = true
    private var lastRefresh = Date.distantPast

    public init() {}

    public func isDue(visible: Bool, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(lastRefresh)
        if elapsed >= Self.rescanInterval { return true }
        return dirty && (visible || elapsed >= Self.hiddenInterval)
    }

    public mutating func filesChanged() {
        dirty = true
    }

    public mutating func refreshed(at now: Date) {
        dirty = false
        lastRefresh = now
    }
}
