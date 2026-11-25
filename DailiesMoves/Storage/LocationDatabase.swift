import Foundation
import SQLite3

/// Ultra-lightweight SQLite3 (WAL mode) persistence layer.
/// Designed for near-zero CPU/RAM overhead during background location appends.
final class LocationDatabase: @unchecked Sendable {
    static let shared: LocationDatabase = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DailiesMoves", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("dailies_moves.sqlite3").path
        return LocationDatabase(path: dbPath)
    }()

    private let queue = DispatchQueue(label: "com.dailiesmoves.db", qos: .utility)
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        queue.sync {
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
                assertionFailure("Failed to open SQLite database at \(path): \(msg)")
                return
            }
            executeUnlocked("PRAGMA journal_mode=WAL;")
            executeUnlocked("PRAGMA synchronous=NORMAL;")
            executeUnlocked("PRAGMA temp_store=MEMORY;")
            createSchemaUnlocked()
            seedDefaultActivityTypesIfNeededUnlocked()
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func createSchemaUnlocked() {
        let sql = """
        CREATE TABLE IF NOT EXISTS raw_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            h_acc REAL NOT NULL,
            altitude REAL NOT NULL,
            speed REAL NOT NULL,
            course REAL NOT NULL,
            source INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_raw_samples_ts ON raw_samples(timestamp);

        CREATE TABLE IF NOT EXISTS raw_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            arrival_ts REAL,
            departure_ts REAL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            h_acc REAL NOT NULL,
            recorded_ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_raw_visits_ts ON raw_visits(arrival_ts, departure_ts);

        CREATE TABLE IF NOT EXISTS activity_types (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            sf_symbol TEXT NOT NULL,
            color_hex TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS saved_places (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            google_place_id TEXT,
            address TEXT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            radius_m REAL NOT NULL DEFAULT 80.0,
            visit_count INTEGER NOT NULL DEFAULT 1,
            last_visited_ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_saved_places_coords ON saved_places(latitude, longitude);

        CREATE TABLE IF NOT EXISTS timeline_segments (
            id TEXT PRIMARY KEY,
            local_day_key TEXT NOT NULL,
            kind TEXT NOT NULL,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL,
            activity_type_id TEXT,
            place_id TEXT,
            place_name TEXT,
            latitude REAL,
            longitude REAL,
            is_confirmed INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_timeline_segments_day ON timeline_segments(local_day_key, sort_order);

        CREATE TABLE IF NOT EXISTS day_reviews (
            local_day_key TEXT PRIMARY KEY,
            utc_export_date_key TEXT,
            reviewed_at_ts REAL,
            exported_at_ts REAL,
            last_export_filename TEXT
        );
        """
        executeUnlocked(sql)
    }

    private func seedDefaultActivityTypesIfNeededUnlocked() {
        let count = scalarIntUnlocked("SELECT COUNT(*) FROM activity_types;")
        guard count == 0 else { return }
        for item in ActivityType.defaults {
            upsertActivityTypeUnlocked(item)
        }
    }

    // MARK: - Background Append (Zero-Processing Fast Path)

    func appendSample(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        altitude: Double,
        speed: Double,
        course: Double,
        source: RawLocationSample.SampleSource
    ) {
        queue.sync {
            let sql = """
            INSERT INTO raw_samples (timestamp, latitude, longitude, h_acc, altitude, speed, course, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            guard let stmt = prepareUnlocked(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, latitude)
            sqlite3_bind_double(stmt, 3, longitude)
            sqlite3_bind_double(stmt, 4, horizontalAccuracy)
            sqlite3_bind_double(stmt, 5, altitude)
            sqlite3_bind_double(stmt, 6, speed)
            sqlite3_bind_double(stmt, 7, course)
            sqlite3_bind_int(stmt, 8, Int32(source.rawValue))
            sqlite3_step(stmt)
        }
    }

    func appendVisit(
        arrivalDate: Date?,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        recordedAt: Date = Date()
    ) {
        queue.sync {
            let sql = """
            INSERT INTO raw_visits (arrival_ts, departure_ts, latitude, longitude, h_acc, recorded_ts)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            guard let stmt = prepareUnlocked(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            bindOptionalDouble(stmt, index: 1, value: arrivalDate?.timeIntervalSince1970)
            bindOptionalDouble(stmt, index: 2, value: departureDate?.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, latitude)
            sqlite3_bind_double(stmt, 4, longitude)
            sqlite3_bind_double(stmt, 5, horizontalAccuracy)
            sqlite3_bind_double(stmt, 6, recordedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    /// Atomically replaces raw samples and visits within `interval` (used when importing a GPX onto a day).
    func replaceDayRawData(
        samples: [RawLocationSample],
        visits: [RawVisitEvent],
        in interval: DateInterval
    ) {
        queue.sync {
            executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")

            if let delSamples = prepareUnlocked("DELETE FROM raw_samples WHERE timestamp >= ? AND timestamp < ?;") {
                sqlite3_bind_double(delSamples, 1, interval.start.timeIntervalSince1970)
                sqlite3_bind_double(delSamples, 2, interval.end.timeIntervalSince1970)
                sqlite3_step(delSamples)
                sqlite3_finalize(delSamples)
            }

            if let delVisits = prepareUnlocked("DELETE FROM raw_visits WHERE recorded_ts >= ? AND recorded_ts < ?;") {
                sqlite3_bind_double(delVisits, 1, interval.start.timeIntervalSince1970)
                sqlite3_bind_double(delVisits, 2, interval.end.timeIntervalSince1970)
                sqlite3_step(delVisits)
                sqlite3_finalize(delVisits)
            }

            let sampleSQL = """
            INSERT INTO raw_samples (timestamp, latitude, longitude, h_acc, altitude, speed, course, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            if let stmt = prepareUnlocked(sampleSQL) {
                for s in samples {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_double(stmt, 1, s.timestamp.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 2, s.latitude)
                    sqlite3_bind_double(stmt, 3, s.longitude)
                    sqlite3_bind_double(stmt, 4, s.horizontalAccuracy)
                    sqlite3_bind_double(stmt, 5, s.altitude)
                    sqlite3_bind_double(stmt, 6, s.speed)
                    sqlite3_bind_double(stmt, 7, s.course)
                    sqlite3_bind_int(stmt, 8, Int32(s.source.rawValue))
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }

            let visitSQL = """
            INSERT INTO raw_visits (arrival_ts, departure_ts, latitude, longitude, h_acc, recorded_ts)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            if let stmt = prepareUnlocked(visitSQL) {
                for v in visits {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindOptionalDouble(stmt, index: 1, value: v.arrivalDate?.timeIntervalSince1970)
                    bindOptionalDouble(stmt, index: 2, value: v.departureDate?.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 3, v.latitude)
                    sqlite3_bind_double(stmt, 4, v.longitude)
                    sqlite3_bind_double(stmt, 5, v.horizontalAccuracy)
                    sqlite3_bind_double(stmt, 6, v.recordedAt.timeIntervalSince1970)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }

            executeUnlocked("COMMIT;")
        }
    }

    // MARK: - Raw Queries

    func fetchSamples(from start: Date, to end: Date) -> [RawLocationSample] {
        queue.sync {
            let sql = """
            SELECT id, timestamp, latitude, longitude, h_acc, altitude, speed, course, source
            FROM raw_samples
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC;
            """
            guard let stmt = prepareUnlocked(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)

            var results: [RawLocationSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(RawLocationSample(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    latitude: sqlite3_column_double(stmt, 2),
                    longitude: sqlite3_column_double(stmt, 3),
                    horizontalAccuracy: sqlite3_column_double(stmt, 4),
                    altitude: sqlite3_column_double(stmt, 5),
                    speed: sqlite3_column_double(stmt, 6),
                    course: sqlite3_column_double(stmt, 7),
                    source: RawLocationSample.SampleSource(rawValue: Int(sqlite3_column_int(stmt, 8))) ?? .activeGPS
                ))
            }
            return results
        }
    }

    func sampleCount(from start: Date, to end: Date) -> Int {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM raw_samples WHERE timestamp >= ? AND timestamp < ?;"
            guard let stmt = prepareUnlocked(sql) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func fetchLatestSample() -> RawLocationSample? {
        queue.sync {
            let sql = """
            SELECT id, timestamp, latitude, longitude, h_acc, altitude, speed, course, source
            FROM raw_samples
            ORDER BY timestamp DESC
            LIMIT 1;
            """
            guard let stmt = prepareUnlocked(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return RawLocationSample(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                latitude: sqlite3_column_double(stmt, 2),
                longitude: sqlite3_column_double(stmt, 3),
                horizontalAccuracy: sqlite3_column_double(stmt, 4),
                altitude: sqlite3_column_double(stmt, 5),
                speed: sqlite3_column_double(stmt, 6),
                course: sqlite3_column_double(stmt, 7),
                source: RawLocationSample.SampleSource(rawValue: Int(sqlite3_column_int(stmt, 8))) ?? .activeGPS
            )
        }
    }

    func fetchVisits(overlapping interval: DateInterval) -> [RawVisitEvent] {
        queue.sync {
            let sql = """
            SELECT id, arrival_ts, departure_ts, latitude, longitude, h_acc, recorded_ts
            FROM raw_visits
            WHERE (departure_ts IS NULL OR departure_ts >= ?)
              AND (arrival_ts IS NULL OR arrival_ts <= ?)
            ORDER BY COALESCE(arrival_ts, recorded_ts) ASC;
            """
            guard let stmt = prepareUnlocked(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, interval.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, interval.end.timeIntervalSince1970)

            var results: [RawVisitEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let arrival = optionalDouble(stmt, column: 1).map { Date(timeIntervalSince1970: $0) }
                let departure = optionalDouble(stmt, column: 2).map { Date(timeIntervalSince1970: $0) }
                results.append(RawVisitEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    arrivalDate: arrival,
                    departureDate: departure,
                    latitude: sqlite3_column_double(stmt, 3),
                    longitude: sqlite3_column_double(stmt, 4),
                    horizontalAccuracy: sqlite3_column_double(stmt, 5),
                    recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                ))
            }
            return results
        }
    }

    // MARK: - Timeline Segments

    func fetchSegments(forLocalDayKey dayKey: String) -> [TimelineSegment] {
        queue.sync {
            let sql = """
            SELECT id, local_day_key, kind, start_ts, end_ts, activity_type_id,
                   place_id, place_name, latitude, longitude, is_confirmed, sort_order
            FROM timeline_segments
            WHERE local_day_key = ?
            ORDER BY sort_order ASC, start_ts ASC;
            """
            guard let stmt = prepareUnlocked(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, dayKey, -1, transient)

            var segments: [TimelineSegment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let kindStr = columnString(stmt, column: 2) ?? "move"
                segments.append(TimelineSegment(
                    id: columnString(stmt, column: 0) ?? UUID().uuidString,
                    localDayKey: columnString(stmt, column: 1) ?? dayKey,
                    kind: TimelineSegment.Kind(rawValue: kindStr) ?? .move,
                    startDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    endDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    activityTypeID: columnString(stmt, column: 5),
                    placeID: columnString(stmt, column: 6),
                    placeName: columnString(stmt, column: 7),
                    latitude: optionalDouble(stmt, column: 8),
                    longitude: optionalDouble(stmt, column: 9),
                    isConfirmed: sqlite3_column_int(stmt, 10) != 0,
                    sortOrder: Int(sqlite3_column_int(stmt, 11))
                ))
            }
            return segments
        }
    }

    func replaceSegments(_ segments: [TimelineSegment], forLocalDayKey dayKey: String) {
        queue.sync {
            executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
            if let delStmt = prepareUnlocked("DELETE FROM timeline_segments WHERE local_day_key = ?;") {
                sqlite3_bind_text(delStmt, 1, dayKey, -1, transient)
                sqlite3_step(delStmt)
                sqlite3_finalize(delStmt)
            }

            let insertSQL = """
            INSERT INTO timeline_segments (
                id, local_day_key, kind, start_ts, end_ts, activity_type_id,
                place_id, place_name, latitude, longitude, is_confirmed, sort_order
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            if let stmt = prepareUnlocked(insertSQL) {
                for (idx, seg) in segments.enumerated() {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_text(stmt, 1, seg.id, -1, transient)
                    sqlite3_bind_text(stmt, 2, dayKey, -1, transient)
                    sqlite3_bind_text(stmt, 3, seg.kind.rawValue, -1, transient)
                    sqlite3_bind_double(stmt, 4, seg.startDate.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 5, seg.endDate.timeIntervalSince1970)
                    bindOptionalText(stmt, index: 6, value: seg.activityTypeID)
                    bindOptionalText(stmt, index: 7, value: seg.placeID)
                    bindOptionalText(stmt, index: 8, value: seg.placeName)
                    bindOptionalDouble(stmt, index: 9, value: seg.latitude)
                    bindOptionalDouble(stmt, index: 10, value: seg.longitude)
                    sqlite3_bind_int(stmt, 11, seg.isConfirmed ? 1 : 0)
                    sqlite3_bind_int(stmt, 12, Int32(idx))
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            executeUnlocked("COMMIT;")
        }
    }

    // MARK: - Day Review Metadata & History

    func fetchDayReview(forLocalDayKey dayKey: String) -> DayReviewRecord? {
        queue.sync {
            let sql = """
            SELECT local_day_key, utc_export_date_key, reviewed_at_ts, exported_at_ts, last_export_filename
            FROM day_reviews
            WHERE local_day_key = ?;
            """
            guard let stmt = prepareUnlocked(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, dayKey, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return DayReviewRecord(
                localDayKey: columnString(stmt, column: 0) ?? dayKey,
                utcExportDateKey: columnString(stmt, column: 1),
                reviewedAt: optionalDouble(stmt, column: 2).map { Date(timeIntervalSince1970: $0) },
                exportedAt: optionalDouble(stmt, column: 3).map { Date(timeIntervalSince1970: $0) },
                lastExportFilename: columnString(stmt, column: 4)
            )
        }
    }

    func upsertDayReview(_ record: DayReviewRecord) {
        queue.sync {
            let sql = """
            INSERT INTO day_reviews (local_day_key, utc_export_date_key, reviewed_at_ts, exported_at_ts, last_export_filename)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(local_day_key) DO UPDATE SET
                utc_export_date_key = excluded.utc_export_date_key,
                reviewed_at_ts = excluded.reviewed_at_ts,
                exported_at_ts = excluded.exported_at_ts,
                last_export_filename = excluded.last_export_filename;
            """
            guard let stmt = prepareUnlocked(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, record.localDayKey, -1, transient)
            bindOptionalText(stmt, index: 2, value: record.utcExportDateKey)
            bindOptionalDouble(stmt, index: 3, value: record.reviewedAt?.timeIntervalSince1970)
            bindOptionalDouble(stmt, index: 4, value: record.exportedAt?.timeIntervalSince1970)
            bindOptionalText(stmt, index: 5, value: record.lastExportFilename)
            sqlite3_step(stmt)
        }
    }

    /// Returns all local days that have raw samples, visits, or saved timeline segments, sorted newest first.
    func fetchTrackedDaySummaries(timeZone: TimeZone = .current) -> [TrackedDaySummary] {
        queue.sync {
            var sampleCountsByDay: [String: Int] = [:]

            if let stmt = prepareUnlocked("SELECT timestamp FROM raw_samples;") {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                    let key = DateFormatting.localDayKey(for: ts, timeZone: timeZone)
                    sampleCountsByDay[key, default: 0] += 1
                }
                sqlite3_finalize(stmt)
            }

            if let stmt = prepareUnlocked("SELECT COALESCE(arrival_ts, recorded_ts) FROM raw_visits;") {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                    let key = DateFormatting.localDayKey(for: ts, timeZone: timeZone)
                    sampleCountsByDay[key] = sampleCountsByDay[key] ?? 0
                }
                sqlite3_finalize(stmt)
            }

            var segmentCountsByDay: [String: Int] = [:]
            if let stmt = prepareUnlocked("SELECT local_day_key, COUNT(*) FROM timeline_segments GROUP BY local_day_key;") {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let key = columnString(stmt, column: 0) {
                        segmentCountsByDay[key] = Int(sqlite3_column_int64(stmt, 1))
                    }
                }
                sqlite3_finalize(stmt)
            }

            var reviewsByDay: [String: DayReviewRecord] = [:]
            if let stmt = prepareUnlocked("SELECT local_day_key, utc_export_date_key, reviewed_at_ts, exported_at_ts, last_export_filename FROM day_reviews;") {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let key = columnString(stmt, column: 0) {
                        reviewsByDay[key] = DayReviewRecord(
                            localDayKey: key,
                            utcExportDateKey: columnString(stmt, column: 1),
                            reviewedAt: optionalDouble(stmt, column: 2).map { Date(timeIntervalSince1970: $0) },
                            exportedAt: optionalDouble(stmt, column: 3).map { Date(timeIntervalSince1970: $0) },
                            lastExportFilename: columnString(stmt, column: 4)
                        )
                    }
                }
                sqlite3_finalize(stmt)
            }

            var allKeys = Set(sampleCountsByDay.keys)
            allKeys.formUnion(segmentCountsByDay.keys)
            allKeys.formUnion(reviewsByDay.keys)
            allKeys.insert(DateFormatting.localDayKey(for: Date(), timeZone: timeZone))

            return allKeys.compactMap { key -> TrackedDaySummary? in
                guard let dayStart = DateFormatting.date(fromDayKey: key, timeZone: timeZone) else { return nil }
                return TrackedDaySummary(
                    localDayKey: key,
                    date: dayStart,
                    rawSampleCount: sampleCountsByDay[key] ?? 0,
                    segmentCount: segmentCountsByDay[key] ?? 0,
                    reviewRecord: reviewsByDay[key]
                )
            }
            .sorted { $0.localDayKey > $1.localDayKey }
        }
    }

    // MARK: - Activity Types

    func fetchActivityTypes() -> [ActivityType] {
        queue.sync {
            let sql = "SELECT id, name, sf_symbol, color_hex, sort_order FROM activity_types ORDER BY sort_order ASC, name ASC;"
            guard let stmt = prepareUnlocked(sql) else { return ActivityType.defaults }
            defer { sqlite3_finalize(stmt) }
            var items: [ActivityType] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(ActivityType(
                    id: columnString(stmt, column: 0) ?? UUID().uuidString,
                    name: columnString(stmt, column: 1) ?? "Move",
                    sfSymbol: columnString(stmt, column: 2) ?? "figure.walk",
                    colorHex: columnString(stmt, column: 3) ?? "#007AFF",
                    sortOrder: Int(sqlite3_column_int(stmt, 4))
                ))
            }
            return items.isEmpty ? ActivityType.defaults : items
        }
    }

    func upsertActivityType(_ item: ActivityType) {
        queue.sync {
            upsertActivityTypeUnlocked(item)
        }
    }

    private func upsertActivityTypeUnlocked(_ item: ActivityType) {
        let sql = """
        INSERT INTO activity_types (id, name, sf_symbol, color_hex, sort_order)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            sf_symbol = excluded.sf_symbol,
            color_hex = excluded.color_hex,
            sort_order = excluded.sort_order;
        """
        guard let stmt = prepareUnlocked(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, item.id, -1, transient)
        sqlite3_bind_text(stmt, 2, item.name, -1, transient)
        sqlite3_bind_text(stmt, 3, item.sfSymbol, -1, transient)
        sqlite3_bind_text(stmt, 4, item.colorHex, -1, transient)
        sqlite3_bind_int(stmt, 5, Int32(item.sortOrder))
        sqlite3_step(stmt)
    }

    func deleteActivityType(id: String) {
        queue.sync {
            guard let stmt = prepareUnlocked("DELETE FROM activity_types WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Saved Places

    func fetchSavedPlaces() -> [SavedPlace] {
        queue.sync {
            let sql = """
            SELECT id, name, google_place_id, address, latitude, longitude, radius_m, visit_count, last_visited_ts
            FROM saved_places
            ORDER BY visit_count DESC, last_visited_ts DESC;
            """
            guard let stmt = prepareUnlocked(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var places: [SavedPlace] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                places.append(SavedPlace(
                    id: columnString(stmt, column: 0) ?? UUID().uuidString,
                    name: columnString(stmt, column: 1) ?? "Place",
                    googlePlaceID: columnString(stmt, column: 2),
                    address: columnString(stmt, column: 3),
                    latitude: sqlite3_column_double(stmt, 4),
                    longitude: sqlite3_column_double(stmt, 5),
                    radiusMeters: sqlite3_column_double(stmt, 6),
                    visitCount: Int(sqlite3_column_int(stmt, 7)),
                    lastVisitedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                ))
            }
            return places
        }
    }

    func upsertSavedPlace(_ place: SavedPlace) {
        queue.sync {
            let sql = """
            INSERT INTO saved_places (id, name, google_place_id, address, latitude, longitude, radius_m, visit_count, last_visited_ts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                google_place_id = excluded.google_place_id,
                address = excluded.address,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                radius_m = excluded.radius_m,
                visit_count = excluded.visit_count,
                last_visited_ts = excluded.last_visited_ts;
            """
            guard let stmt = prepareUnlocked(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, place.id, -1, transient)
            sqlite3_bind_text(stmt, 2, place.name, -1, transient)
            bindOptionalText(stmt, index: 3, value: place.googlePlaceID)
            bindOptionalText(stmt, index: 4, value: place.address)
            sqlite3_bind_double(stmt, 5, place.latitude)
            sqlite3_bind_double(stmt, 6, place.longitude)
            sqlite3_bind_double(stmt, 7, place.radiusMeters)
            sqlite3_bind_int(stmt, 8, Int32(place.visitCount))
            sqlite3_bind_double(stmt, 9, place.lastVisitedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func deleteSavedPlace(id: String) {
        queue.sync {
            guard let stmt = prepareUnlocked("DELETE FROM saved_places WHERE id = ?;") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            sqlite3_step(stmt)
        }
    }

    // MARK: - SQLite Helpers

    private func executeUnlocked(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepareUnlocked(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        return stmt
    }

    private func scalarIntUnlocked(_ sql: String) -> Int {
        guard let stmt = prepareUnlocked(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer, index: Int32, value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnString(_ stmt: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, column) else {
            return nil
        }
        return String(cString: ptr)
    }

    private func optionalDouble(_ stmt: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, column)
    }
}
