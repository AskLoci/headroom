import Foundation

public enum TextCleaning {
    /// Removes `<system-reminder>…</system-reminder>` blocks that tools inject into user turns.
    public static func stripSystemReminders(_ text: String) -> String {
        text.replacing(/<system-reminder>[\s\S]*?<\/system-reminder>/, with: "")
    }

    /// True for tool-generated wrapper text such as `<command-name>` or `<local-command-stdout>`.
    public static func isWrapperMarkup(_ text: String) -> Bool {
        text.firstMatch(of: /^<[a-z]+(-[a-z]+)+[ >]/) != nil
    }

    /// Collapses whitespace runs onto one line and truncates to `max` characters with an ellipsis.
    public static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
