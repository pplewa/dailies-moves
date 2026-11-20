import XCTest
@testable import DailiesMoves

final class LocationDatabaseTests: XCTestCase {
    func testAppendAndQueryRawSamplesAndSegments() {
        let db = LocationDatabase(path: ":memory:")
        let t0 = ISO8601DateFormatter().date(from: "2026-11-19T08:00:00Z")!
        let t1 = t0.addingTimeInterval(600)

        db.appendSample(
            timestamp: t0,
            latitude: 13.7563,
            longitude: 100.5018,
            horizontalAccuracy: 10,
            altitude: 5,
            speed: 1.4,
            course: 90,
            source: .activeGPS
        )
        db.appendSample(
            timestamp: t1,
            latitude: 13.7570,
            longitude: 100.5025,
            horizontalAccuracy: 12,
            altitude: 5,
            speed: 1.5,
            course: 90,
            source: .activeGPS
        )

        let fetched = db.fetchSamples(from: t0.addingTimeInterval(-60), to: t1.addingTimeInterval(60))
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched.first?.latitude ?? 0, 13.7563, accuracy: 0.0001)

        // Default activity types seeded automatically
        let types = db.fetchActivityTypes()
        XCTAssertGreaterThanOrEqual(types.count, 5)

        // Custom activity type upsert & delete
        let custom = ActivityType(id: "scooter", name: "Scooter", sfSymbol: "scooter", colorHex: "#FF2D55", sortOrder: 10)
        db.upsertActivityType(custom)
        XCTAssertTrue(db.fetchActivityTypes().contains(where: { $0.id == "scooter" }))
        db.deleteActivityType(id: "scooter")
        XCTAssertFalse(db.fetchActivityTypes().contains(where: { $0.id == "scooter" }))

        // Saved place persistence
        let place = SavedPlace(
            id: "place-home",
            name: "Home",
            googlePlaceID: nil,
            address: "123 Main St",
            latitude: 13.7563,
            longitude: 100.5018,
            radiusMeters: 80,
            visitCount: 3,
            lastVisitedAt: t1
        )
        db.upsertSavedPlace(place)
        XCTAssertEqual(db.fetchSavedPlaces().first?.name, "Home")

        // Timeline segments replace & fetch
        let seg = TimelineSegment(
            id: "seg-1",
            localDayKey: "2026-11-19",
            kind: .stationary,
            startDate: t0,
            endDate: t1,
            activityTypeID: nil,
            placeID: "place-home",
            placeName: "Home",
            latitude: 13.7563,
            longitude: 100.5018,
            isConfirmed: true,
            sortOrder: 0
        )
        db.replaceSegments([seg], forLocalDayKey: "2026-11-19")
        let loadedSegs = db.fetchSegments(forLocalDayKey: "2026-11-19")
        XCTAssertEqual(loadedSegs.count, 1)
        XCTAssertEqual(loadedSegs.first?.placeName, "Home")
    }
}
