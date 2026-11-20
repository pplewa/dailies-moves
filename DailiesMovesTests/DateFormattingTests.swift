import XCTest
@testable import DailiesMoves

final class DateFormattingTests: XCTestCase {
    func testCurrentDayAheadOfUTCSavesActualUTCDay() {
        // Local timezone: UTC+7 (Bangkok).
        // Local time: 2026-11-20 01:30:00 +07:00 == 2026-11-19 18:30:00Z.
        let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T18:30:00Z")!

        let localKey = DateFormatting.localDayKey(for: now, timeZone: bangkok)
        XCTAssertEqual(localKey, "2026-11-20")

        let event1 = ISO8601DateFormatter().date(from: "2026-11-19T17:15:00Z")! // 00:15 local Nov 20
        let event2 = ISO8601DateFormatter().date(from: "2026-11-19T18:20:00Z")! // 01:20 local Nov 20

        let utcExportDay = DateFormatting.resolvedUTCExportDayKey(
            forLocalDayKey: localKey,
            eventDates: [event1, event2],
            now: now,
            timeZone: bangkok
        )
        XCTAssertEqual(utcExportDay, "2026-11-19")
    }

    func testCurrentDayAfterUTCCatchesUpSavesMatchingUTCDay() {
        // Local time: 2026-11-20 09:00:00 +07:00 == 2026-11-20 02:00:00Z.
        let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-11-20T02:00:00Z")!

        let localKey = DateFormatting.localDayKey(for: now, timeZone: bangkok)
        XCTAssertEqual(localKey, "2026-11-20")

        let event1 = ISO8601DateFormatter().date(from: "2026-11-19T18:00:00Z")! // 01:00 local
        let event2 = ISO8601DateFormatter().date(from: "2026-11-20T01:30:00Z")! // 08:30 local

        let utcExportDay = DateFormatting.resolvedUTCExportDayKey(
            forLocalDayKey: localKey,
            eventDates: [event1, event2],
            now: now,
            timeZone: bangkok
        )
        XCTAssertEqual(utcExportDay, "2026-11-20")
    }

    func testISO8601UTCFormatAlwaysEndsWithZ() {
        let date = ISO8601DateFormatter().date(from: "2026-11-19T11:22:48Z")!
        XCTAssertEqual(DateFormatting.iso8601UTC(date), "2026-11-19T11:22:48Z")
    }
}
