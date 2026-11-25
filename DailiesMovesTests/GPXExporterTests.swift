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

    func testImportGPXOverridesMismatchedDatesToTargetDay() throws {
        let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
        // GPX generated for local 2026-11-20 (Escent 00:00-14:00, Walking 14:00-14:05, Central 14:05-14:20)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DailiesMoves" xmlns="http://www.topografix.com/GPX/1/1" xmlns:dm="https://dailiesmoves.app/gpx/1">
          <metadata><name>2026-11-20</name></metadata>
          <wpt lat="18.805682" lon="99.020049">
            <time>2026-11-19T17:00:00Z</time>
            <name>Escent Condo</name>
            <extensions>
              <dm:startTime>2026-11-19T17:00:00Z</dm:startTime>
              <dm:endTime>2026-11-20T07:00:00Z</dm:endTime>
            </extensions>
          </wpt>
          <trk>
            <name>Scooter</name>
            <type>scooter</type>
            <extensions>
              <dm:startTime>2026-11-20T07:00:00Z</dm:startTime>
              <dm:endTime>2026-11-20T07:05:00Z</dm:endTime>
            </extensions>
            <trkseg>
              <trkpt lat="18.805682" lon="99.020049"><time>2026-11-20T07:00:00Z</time></trkpt>
              <trkpt lat="18.806569" lon="99.017970"><time>2026-11-20T07:05:00Z</time></trkpt>
            </trkseg>
          </trk>
          <wpt lat="18.806569" lon="99.017970">
            <time>2026-11-20T07:05:00Z</time>
            <name>Central Festival</name>
            <extensions>
              <dm:startTime>2026-11-20T07:05:00Z</dm:startTime>
              <dm:endTime>2026-11-20T07:20:00Z</dm:endTime>
            </extensions>
          </wpt>
        </gpx>
        """

        // Import onto a DIFFERENT target day: 2026-11-25!
        let result = try GPXImporter.parse(
            data: Data(xml.utf8),
            targetLocalDayKey: "2026-11-25",
            existingActivityTypes: ActivityType.defaults,
            existingSavedPlaces: [],
            timeZone: bangkok
        )

        XCTAssertTrue(result.didOverrideDates)
        XCTAssertEqual(result.sourceDayKey, "2026-11-20")
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.newActivityTypes.first?.name, "Scooter")

        // Verify exact local times were preserved on 2026-11-25:
        // 00:00 +07 on Nov 25 == 2026-11-24T17:00:00Z
        // 14:00 +07 on Nov 25 == 2026-11-25T07:00:00Z
        XCTAssertEqual(DateFormatting.iso8601UTC(result.segments[0].startDate), "2026-11-24T17:00:00Z")
        XCTAssertEqual(DateFormatting.iso8601UTC(result.segments[0].endDate), "2026-11-25T07:00:00Z")
        XCTAssertEqual(DateFormatting.iso8601UTC(result.segments[1].startDate), "2026-11-25T07:00:00Z")
        XCTAssertEqual(DateFormatting.iso8601UTC(result.segments[1].endDate), "2026-11-25T07:05:00Z")
        XCTAssertEqual(DateFormatting.iso8601UTC(result.segments[2].endDate), "2026-11-25T07:20:00Z")

        // Verify trackpoints were also rebased to 2026-11-25!
        let activeSamples = result.samples.filter { $0.source == .activeGPS }
        XCTAssertEqual(activeSamples.count, 2)
        XCTAssertEqual(DateFormatting.iso8601UTC(activeSamples[0].timestamp), "2026-11-25T07:00:00Z")
        XCTAssertEqual(DateFormatting.iso8601UTC(activeSamples[1].timestamp), "2026-11-25T07:05:00Z")
    }
}
