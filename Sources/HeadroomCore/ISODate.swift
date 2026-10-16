import Foundation

/// Parses ISO-8601 timestamps with any number of fractional digits and a `Z` or `±HH:MM` offset.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        let b = Array(string.utf8)
        guard b.count >= 19, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A,
              let year = digits(b, 0, 4), let month = digits(b, 5, 2), let day = digits(b, 8, 2),
              let hour = digits(b, 11, 2), let minute = digits(b, 14, 2), let second = digits(b, 17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            let start = i
            var scale = 0.1
            while i < b.count, (0x30...0x39).contains(b[i]) {
                fraction += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
            guard i > start else { return nil }
        }

        var offset = 0
        if i < b.count {
            switch b[i] {
            case 0x5A: // Z
                i += 1
            case 0x2B, 0x2D: // + or -
                let sign = b[i] == 0x2B ? 1 : -1
                let rest = b[(i + 1)...].filter { $0 != 0x3A }
                guard rest.count == 4, let hours = digits(rest, 0, 2), let minutes = digits(rest, 2, 2) else { return nil }
                offset = sign * (hours * 3600 + minutes * 60)
                i = b.count
            default:
                return nil
            }
        }
        guard i == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    static func digits(_ b: [UInt8], _ start: Int, _ count: Int) -> Int? {
        var value = 0
        for i in start..<(start + count) {
            guard i < b.count, (0x30...0x39).contains(b[i]) else { return nil }
            value = value * 10 + Int(b[i] - 0x30)
        }
        return value
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
