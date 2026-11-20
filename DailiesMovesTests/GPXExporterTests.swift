import XCTest
@testable import DailiesMoves

final class GPXExporterTests: XCTestCase {
    func testGeneratesValidGPX11WithUTCFilenameAndUTCTimestamps() {
        let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
        // Local time is 2026-11-20 01:30 +07:00 -> actual UTC date is 2026-11-19!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T18:30:00Z")!
        let t0 = ISO8601DateFormatter().date(from: "2026-11-19T17:10:00Z")!
        let t1 = ISO8601DateFormatter().date(from: "2026-11-19T17:40:00Z")!
        let t2 = ISO8601DateFormatter().date(from: "2026-11-19T18:00:00Z")!

        let stationary = TimelineSegment(
            id: "s1",
            localDayKey: "2026-11-20",
            kind: .stationary,
            startDate: t0,
            endDate: t1,
            activityTypeID: nil,
            placeID: "p1",
            placeName: "Night Cafe & Bar",
            latitude: 13.7563,
            longitude: 100.5018,
            isConfirmed: true,
            sortOrder: 0
        )

        let move = TimelineSegment(
            id: "m1",
            localDayKey: "2026-11-20",
            kind: .move,
            startDate: t1,
            endDate: t2,
            activityTypeID: "walking",
            placeID: nil,
            placeName: nil,
            latitude: nil,
            longitude: nil,
            isConfirmed: true,
            sortOrder: 1
        )

        let samples = [
            RawLocationSample(id: 1, timestamp: t1, latitude: 13.7563, longitude: 100.5018, horizontalAccuracy: 8, altitude: 4.5, speed: 1.2, course: 0, source: .activeGPS),
            RawLocationSample(id: 2, timestamp: t2, latitude: 13.7580, longitude: 100.5030, horizontalAccuracy: 8, altitude: 4.8, speed: 1.3, course: 0, source: .activeGPS)
        ]

        let pkg = GPXExporter.generate(
            localDayKey: "2026-11-20",
            segments: [stationary, move],
            rawSamples: samples,
            activityTypes: ActivityType.defaults,
            now: now,
            timeZone: bangkok
        )

        XCTAssertEqual(pkg.utcDateKey, "2026-11-19")
        XCTAssertEqual(pkg.filename, "2026-11-19.gpx")
        XCTAssertTrue(pkg.xmlString.contains("<name>Night Cafe &amp; Bar</name>"))
        XCTAssertTrue(pkg.xmlString.contains("<type>walking</type>"))
        XCTAssertTrue(pkg.xmlString.contains("<time>2026-11-19T17:10:00Z</time>"))
        XCTAssertTrue(pkg.xmlString.contains("<dm:endTime>2026-11-19T17:40:00Z</dm:endTime>"))
        XCTAssertTrue(pkg.xmlString.contains("<trkpt lat=\"13.758000\" lon=\"100.503000\">"))
    }
}
