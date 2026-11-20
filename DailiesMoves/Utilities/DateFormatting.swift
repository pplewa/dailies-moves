import Foundation

/// Centralized helpers separating local display dates from UTC storage and GPX export dates.
enum DateFormatting {
    private static let dayKeyLock = NSLock()

    static func localCalendar(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// Formats a `Date` as `"YYYY-MM-DD"` in the given timezone (defaults to device local).
    static func localDayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        let cal = localCalendar(timeZone: timeZone)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Formats a `Date` as `"YYYY-MM-DD"` in UTC.
    static func utcDayKey(for date: Date) -> String {
        localDayKey(for: date, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// Parses `"YYYY-MM-DD"` into the start of that day in the specified timezone.
    static func date(fromDayKey key: String, timeZone: TimeZone = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return localCalendar(timeZone: timeZone).date(from: comps)
    }

    /// Returns `[startOfDay, startOfNextDay)` in the given local timezone.
    static func localDayInterval(forDayKey key: String, timeZone: TimeZone = .current) -> DateInterval? {
        guard let start = date(fromDayKey: key, timeZone: timeZone),
              let end = localCalendar(timeZone: timeZone).date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    /// Determines the actual UTC date string (`YYYY-MM-DD`) to use when saving/exporting a local day.
    ///
    /// - If exporting the current local day while local calendar date is ahead of UTC
    ///   (e.g. local is `2026-11-20 01:30 +07:00`, UTC is `2026-11-19 18:30Z`),
    ///   returns the actual current UTC day (`"2026-11-19"`).
    /// - If all events in the day fall entirely within one UTC date, returns that UTC date.
    /// - Otherwise returns the UTC date of local noon for that day (or `utcDayKey(now)` when today).
    static func resolvedUTCExportDayKey(
        forLocalDayKey localKey: String,
        eventDates: [Date] = [],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let todayLocalKey = localDayKey(for: now, timeZone: timeZone)
        let todayUTCKey = utcDayKey(for: now)

        if localKey == todayLocalKey {
            // If local date is ahead of UTC, save as the actual current UTC day.
            if todayUTCKey < localKey {
                return todayUTCKey
            }
            // If all recorded events on today fall strictly on a single earlier UTC day, honor that too.
            if !eventDates.isEmpty {
                let uniqueUTCDays = Set(eventDates.map { utcDayKey(for: $0) })
                if uniqueUTCDays.count == 1, let onlyDay = uniqueUTCDays.first {
                    return onlyDay
                }
            }
            return todayUTCKey
        }

        // For non-today (past) local days:
        if !eventDates.isEmpty {
            let uniqueUTCDays = Set(eventDates.map { utcDayKey(for: $0) })
            if uniqueUTCDays.count == 1, let onlyDay = uniqueUTCDays.first {
                return onlyDay
            }
        }

        if let start = date(fromDayKey: localKey, timeZone: timeZone) {
            let localNoon = start.addingTimeInterval(12 * 3600)
            return utcDayKey(for: localNoon)
        }
        return localKey
    }

    /// Strictly formatted UTC ISO-8601 timestamp (`2026-11-19T18:22:48Z`) for GPX and saved records.
    static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Local short time string for UI display (e.g. `14:05` or `2:05 PM`).
    static func localTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Friendly local date header (e.g. `Thu, Nov 19, 2026`).
    static func localDisplayDate(forDayKey key: String, timeZone: TimeZone = .current) -> String {
        guard let d = date(fromDayKey: key, timeZone: timeZone) else { return key }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter.string(from: d)
    }

    /// Human-readable duration (e.g. `1h 24m`, `12m`, `< 1m`).
    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60.0).rounded())
        if totalMinutes < 1 {
            return "< 1m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    /// Human-readable distance (e.g. `420 m`, `3.4 km`).
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.1f km", meters / 1000.0)
    }
}
