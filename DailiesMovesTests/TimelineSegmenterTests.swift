import XCTest
@testable import DailiesMoves

final class TimelineSegmenterTests: XCTestCase {
    func testDetectsSleepGapStationaryMoveAndSavedPlaceMatch() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let dayStart = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
        let dayInterval = DateInterval(start: dayStart, duration: 86400)

        // Scenario:
        // 08:00 -> 10:00: Geofence sleep at Home (only start & exit points, 2h gap, 20m apart!)
        // 10:00 -> 10:15: Drive to Office (~10 m/s -> inferred "car")
        // 10:15 -> 12:00: Stationary at Office
        let tHomeStart = dayStart.addingTimeInterval(8 * 3600)
        let tHomeExit = dayStart.addingTimeInterval(10 * 3600)
        let tOfficeArrive = dayStart.addingTimeInterval(10 * 3600 + 15 * 60)
        let tOfficeEnd = dayStart.addingTimeInterval(12 * 3600)

        var samples: [RawLocationSample] = [
            makeSample(id: 1, ts: tHomeStart, lat: 13.75000, lon: 100.50000),
            makeSample(id: 2, ts: tHomeExit, lat: 13.75015, lon: 100.50010)
        ]

        // Drive ~9km north in 15 minutes (~10 m/s)
        for step in 1...14 {
            let frac = Double(step) / 15.0
            let ts = tHomeExit.addingTimeInterval(Double(step) * 60)
            let lat = 13.75015 + frac * 0.08
            samples.append(makeSample(id: Int64(10 + step), ts: ts, lat: lat, lon: 100.50010))
        }

        // Arrive at office and stay for 1h45m (geofence sleep)
        samples.append(makeSample(id: 30, ts: tOfficeArrive, lat: 13.83015, lon: 100.50010))
        samples.append(makeSample(id: 31, ts: tOfficeEnd, lat: 13.83020, lon: 100.50012))

        let homePlace = SavedPlace(
            id: "home-id",
            name: "Home",
            googlePlaceID: nil,
            address: nil,
            latitude: 13.75005,
            longitude: 100.50005,
            radiusMeters: 80,
            visitCount: 20,
            lastVisitedAt: dayStart
        )

        let segments = TimelineSegmenter.segment(
            localDayKey: DateFormatting.localDayKey(for: dayStart, timeZone: utc),
            dayInterval: dayInterval,
            samples: samples,
            visits: [],
            savedPlaces: [homePlace],
            activityTypes: ActivityType.defaults
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].kind, .stationary)
        XCTAssertEqual(segments[0].placeName, "Home")
        XCTAssertEqual(segments[0].placeID, "home-id")

        XCTAssertEqual(segments[1].kind, .move)
        XCTAssertEqual(segments[1].activityTypeID, "car")

        XCTAssertEqual(segments[2].kind, .stationary)
        XCTAssertNil(segments[2].placeName)
    }

    /// Regression test modeled directly on real device data from 2026-11-20:
    /// An open-ended CLVisit (departureDate == nil) earlier in the day must NEVER overwrite
    /// subsequent visits and moves later in the day.
    func testOpenEndedEarlyVisitDoesNotEraseSubsequentVisitsAndMoves() {
        let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
        let dayInterval = DateFormatting.localDayInterval(forDayKey: "2026-11-20", timeZone: bangkok)!
        let iso = ISO8601DateFormatter()

        // Local +07:00 timestamps expressed in UTC:
        let t0453 = iso.date(from: "2026-11-19T21:53:01Z")! // 04:53 Escent
        let t1327 = iso.date(from: "2026-11-20T06:27:05Z")! // 13:27 Escent open-ended visit
        let t1332 = iso.date(from: "2026-11-20T06:32:20Z")! // 13:32 Escent last sample
        let t1409 = iso.date(from: "2026-11-20T07:09:48Z")! // 14:09 Central Chiangmai arrive
        let t1700 = iso.date(from: "2026-11-20T10:00:18Z")! // 17:00 Central Chiangmai depart
        let t1707 = iso.date(from: "2026-11-20T10:07:30Z")! // 17:07 Scooter ride #1
        let t1717 = iso.date(from: "2026-11-20T10:17:18Z")! // 17:17 Pizza arrive
        let t1741 = iso.date(from: "2026-11-20T10:41:07Z")! // 17:41 Pizza depart
        let t1752 = iso.date(from: "2026-11-20T10:52:30Z")! // 17:52 Scooter ride #2
        let t1759 = iso.date(from: "2026-11-20T10:59:32Z")! // 17:59 Escent arrive (open-ended final visit)
        let t1925 = iso.date(from: "2026-11-20T12:25:00Z")! // 19:25 now

        let visits: [RawVisitEvent] = [
            // Open-ended early visit at Escent (the exact bug trigger!)
            RawVisitEvent(id: 2, arrivalDate: t1327, departureDate: nil, latitude: 18.805678, longitude: 99.020100, horizontalAccuracy: 5, recordedAt: t1332),
            // Duplicate arrival + completed visit at Central Chiangmai
            RawVisitEvent(id: 3, arrivalDate: t1409, departureDate: nil, latitude: 18.806794, longitude: 99.017817, horizontalAccuracy: 130, recordedAt: t1409),
            RawVisitEvent(id: 5, arrivalDate: t1409, departureDate: t1700, latitude: 18.806569, longitude: 99.017970, horizontalAccuracy: 31, recordedAt: t1700),
            // Duplicate arrival + completed visit at Alphabet City Pizza
            RawVisitEvent(id: 6, arrivalDate: t1717, departureDate: nil, latitude: 18.796115, longitude: 98.993231, horizontalAccuracy: 10, recordedAt: t1717),
            RawVisitEvent(id: 7, arrivalDate: t1717, departureDate: t1741, latitude: 18.795985, longitude: 98.993190, horizontalAccuracy: 49, recordedAt: t1741),
            // Open-ended final visit back at Escent
            RawVisitEvent(id: 8, arrivalDate: t1759, departureDate: nil, latitude: 18.805574, longitude: 99.020040, horizontalAccuracy: 50, recordedAt: t1759)
        ]

        let samples: [RawLocationSample] = [
            makeSample(id: 1, ts: t0453, lat: 18.805813, lon: 99.020289),
            // Indoor spike (should be filtered)
            makeSample(id: 2, ts: t1332.addingTimeInterval(-1), lat: 18.807028, lon: 99.021137),
            makeSample(id: 3, ts: t1332, lat: 18.805633, lon: 99.020190),
            makeSample(id: 4, ts: t1409.addingTimeInterval(300), lat: 18.806871, lon: 99.017823),
            RawLocationSample(id: 5, timestamp: t1707, latitude: 18.802489, longitude: 99.016365, horizontalAccuracy: 3, altitude: 300, speed: 8.6, course: 0, source: .activeGPS),
            makeSample(id: 6, ts: t1717.addingTimeInterval(300), lat: 18.796069, lon: 98.993240),
            RawLocationSample(id: 7, timestamp: t1752, latitude: 18.801243, longitude: 99.014483, horizontalAccuracy: 3, altitude: 300, speed: 9.5, course: 0, source: .activeGPS),
            makeSample(id: 8, ts: t1925, lat: 18.805957, lon: 99.020091)
        ]

        let escent = SavedPlace(
            id: "escent",
            name: "Escent Condo",
            googlePlaceID: nil,
            address: nil,
            latitude: 18.8057,
            longitude: 99.0201,
            radiusMeters: 80,
            visitCount: 10,
            lastVisitedAt: t0453
        )

        let segments = TimelineSegmenter.segment(
            localDayKey: "2026-11-20",
            dayInterval: dayInterval,
            samples: samples,
            visits: visits,
            savedPlaces: [escent],
            activityTypes: ActivityType.defaults,
            now: t1925
        )

        // Expect 7 alternating segments:
        // Escent -> Move -> Central -> Move (car) -> Pizza -> Move (car) -> Escent
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.map(\.kind), [.stationary, .move, .stationary, .move, .stationary, .move, .stationary])
        XCTAssertEqual(segments[0].placeName, "Escent Condo")
        XCTAssertEqual(segments[3].activityTypeID, "car")
        XCTAssertEqual(segments[5].activityTypeID, "car")
        XCTAssertEqual(segments[6].placeName, "Escent Condo")
    }

    func testAutoSplitsVehicleToWalkingTransition() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let dayStart = ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z")!
        let dayInterval = DateInterval(start: dayStart, duration: 86400)
        let tStart = dayStart.addingTimeInterval(2 * 3600)

        var samples: [RawLocationSample] = []
        var lat = 18.8000
        var id: Int64 = 1

        // 6 minutes riding a scooter/car at ~9 m/s (~3.2 km)
        for step in 0..<36 {
            let ts = tStart.addingTimeInterval(Double(step) * 10)
            lat += 0.00081 // ~90m per 10s
            samples.append(RawLocationSample(
                id: id, timestamp: ts, latitude: lat, longitude: 99.0000,
                horizontalAccuracy: 5, altitude: 310, speed: 9.0, course: 0, source: .activeGPS
            ))
            id += 1
        }

        // Immediately transition (no stationary dwell!) to 4 minutes of walking at ~1.3 m/s (~310 m)
        let tWalkStart = tStart.addingTimeInterval(360)
        for step in 1...24 {
            let ts = tWalkStart.addingTimeInterval(Double(step) * 10)
            lat += 0.00012 // ~13m per 10s
            samples.append(RawLocationSample(
                id: id, timestamp: ts, latitude: lat, longitude: 99.0000,
                horizontalAccuracy: 5, altitude: 310, speed: 1.3, course: 0, source: .activeGPS
            ))
            id += 1
        }

        let segments = TimelineSegmenter.segment(
            localDayKey: DateFormatting.localDayKey(for: dayStart, timeZone: utc),
            dayInterval: dayInterval,
            samples: samples,
            visits: [],
            savedPlaces: [],
            activityTypes: ActivityType.defaults
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].kind, .move)
        XCTAssertEqual(segments[0].activityTypeID, "car")
        XCTAssertEqual(segments[1].kind, .move)
        XCTAssertEqual(segments[1].activityTypeID, "walking")
    }

    private func makeSample(id: Int64, ts: Date, lat: Double, lon: Double) -> RawLocationSample {
        RawLocationSample(
            id: id,
            timestamp: ts,
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: 10,
            altitude: 5,
            speed: 0,
            course: 0,
            source: .activeGPS
        )
    }
}
