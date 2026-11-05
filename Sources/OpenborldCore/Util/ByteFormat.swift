import Foundation

public enum ByteFormat {
    /// Finder-style sizes: decimal units, one decimal place once past KB.
    public static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        if count < 1000 { return "\(count) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(count) / 1000
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[index])
    }

    /// Transfer rate, e.g. `12.4 MB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return "—" }
        return bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// Remaining time, rounded to units a person can read at a glance.
    public static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "less than a second" }
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            let remainder = Int(seconds) % 60
            return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
        }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
        return "\(hours / 24) days"
    }

    /// Relative dates for recent items, absolute beyond a week — the same
    /// convention Finder uses, and it's what makes a listing scannable.
    public static func modified(_ date: Date?) -> String {
        guard let date else { return "—" }
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return absoluteFormatter.string(from: date) }
        if interval < 60 { return "Just now" }
        if Calendar.current.isDateInToday(date) {
            return "Today " + timeFormatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday " + timeFormatter.string(from: date)
        }
        if interval < 7 * 86400 {
            return weekdayFormatter.string(from: date) + " " + timeFormatter.string(from: date)
        }
        return absoluteFormatter.string(from: date)
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
