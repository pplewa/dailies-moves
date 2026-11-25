import Foundation
import CoreLocation

/// Parses DailiesMoves, Dailies GPX Studio, and Arc Timeline GPX 1.1 files into
/// `TimelineSegment`s, `RawLocationSample`s, and `RawVisitEvent`s — overriding dates
/// to match `targetLocalDayKey` whenever the GPX comes from a different day.
enum GPXImporter {
    struct ImportResult: Sendable {
        let segments: [TimelineSegment]
        let samples: [RawLocationSample]
        let visits: [RawVisitEvent]
        let newActivityTypes: [ActivityType]
        let newSavedPlaces: [SavedPlace]
        let sourceDayKey: String?
        let didOverrideDates: Bool
    }

    enum ImportError: LocalizedError {
        case invalidXML
        case emptyTimeline

        var errorDescription: String? {
            switch self {
            case .invalidXML:
                return "Could not parse the selected GPX file."
            case .emptyTimeline:
                return "No waypoints or tracks were found in this GPX file."
            }
        }
    }

    private struct ParsedWaypoint {
        var lat: Double
        var lon: Double
        var name: String
        var time: Date?
        var dmStart: Date?
        var dmEnd: Date?
    }

    private struct ParsedTrackPoint {
        var lat: Double
        var lon: Double
        var ele: Double
        var time: Date?
    }

    private struct ParsedTrack {
        var name: String
        var type: String
        var dmStart: Date?
        var dmEnd: Date?
        var points: [ParsedTrackPoint]
    }

    static func parse(
        data: Data,
        targetLocalDayKey: String,
        existingActivityTypes: [ActivityType],
        existingSavedPlaces: [SavedPlace],
        timeZone: TimeZone = .current
    ) throws -> ImportResult {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.invalidXML
        }
        guard !delegate.waypoints.isEmpty || !delegate.tracks.isEmpty else {
            throw ImportError.emptyTimeline
        }
        guard let targetInterval = DateFormatting.localDayInterval(forDayKey: targetLocalDayKey, timeZone: timeZone) else {
            throw ImportError.invalidXML
        }

        // 1. Determine the dominant local day in the source GPX so we know whether dates must be overridden.
        var candidateDates: [Date] = []
        for w in delegate.waypoints {
            if let d = w.dmEnd ?? w.dmStart ?? w.time { candidateDates.append(d) }
        }
        for t in delegate.tracks {
            if let d = t.dmStart ?? t.points.first?.time { candidateDates.append(d) }
            if let d = t.dmEnd ?? t.points.last?.time { candidateDates.append(d) }
        }

        let dayHistogram = candidateDates.reduce(into: [String: Int]()) { acc, dt in
            let key = DateFormatting.localDayKey(for: dt, timeZone: timeZone)
            acc[key, default: 0] += 1
        }
        let sourceDayKey = dayHistogram.max(by: { $0.value < $1.value })?.key
            ?? delegate.metadataName.flatMap { DateFormatting.date(fromDayKey: $0, timeZone: timeZone) != nil ? $0 : nil }

        let cal = DateFormatting.localCalendar(timeZone: timeZone)
        let dayDelta: Int
        if let srcKey = sourceDayKey,
           srcKey != targetLocalDayKey,
           let srcStart = DateFormatting.date(fromDayKey: srcKey, timeZone: timeZone) {
            dayDelta = cal.dateComponents([.day], from: srcStart, to: targetInterval.start).day ?? 0
        } else {
            dayDelta = 0
        }
        let didOverrideDates = (dayDelta != 0)

        func rebase(_ date: Date?) -> Date? {
            guard let date else { return nil }
            guard dayDelta != 0 else { return date }
            return cal.date(byAdding: .day, value: dayDelta, to: date) ?? date.addingTimeInterval(Double(dayDelta) * 86400)
        }

        // 2. Build intermediate timeline items (rebased onto targetLocalDayKey).
        enum RawEntry {
            case stationary(name: String, lat: Double, lon: Double, start: Date?, end: Date?)
            case move(name: String, type: String, start: Date?, end: Date?, points: [ParsedTrackPoint])

            var sortDate: Date {
                switch self {
                case .stationary(_, _, _, let s, let e): return s ?? e ?? .distantPast
                case .move(_, _, let s, let e, let pts): return s ?? pts.first?.time ?? e ?? .distantPast
                }
            }
        }

        var entries: [RawEntry] = []

        for w in delegate.waypoints {
            let start = rebase(w.dmStart ?? w.time)
            let end = rebase(w.dmEnd)
            entries.append(.stationary(name: w.name, lat: w.lat, lon: w.lon, start: start, end: end))
        }

        for t in delegate.tracks {
            let rebasedPoints = t.points.map { pt in
                ParsedTrackPoint(lat: pt.lat, lon: pt.lon, ele: pt.ele, time: rebase(pt.time))
            }
            let start = rebase(t.dmStart) ?? rebasedPoints.first?.time
            let end = rebase(t.dmEnd) ?? rebasedPoints.last?.time
            entries.append(.move(name: t.name, type: t.type, start: start, end: end, points: rebasedPoints))
        }

        entries.sort { $0.sortDate < $1.sortDate }

        // 3. Resolve missing start/end dates (e.g., Arc GPX <wpt> only specifies arrival time),
        //    and clamp any pre-midnight overnight start cleanly into targetInterval.
        var activityTypes = existingActivityTypes
        var newActivityTypes: [ActivityType] = []
        var savedPlaces = existingSavedPlaces
        var newSavedPlaces: [SavedPlace] = []

        var segments: [TimelineSegment] = []
        var samples: [RawLocationSample] = []
        var visits: [RawVisitEvent] = []
        var nextSampleID: Int64 = 1
        var nextVisitID: Int64 = 1

        let dayEndMinusMinute = targetInterval.end.addingTimeInterval(-60)

        for idx in entries.indices {
            let nextStart: Date? = {
                guard idx + 1 < entries.count else { return nil }
                switch entries[idx + 1] {
                case .stationary(_, _, _, let s, _): return s
                case .move(_, _, let s, _, let pts): return s ?? pts.first?.time
                }
            }()

            switch entries[idx] {
            case .stationary(let rawName, let lat, let lon, let rawStart, let rawEnd):
                var start = rawStart ?? (segments.last?.endDate ?? targetInterval.start)
                // If an overnight arrival (e.g. Arc's evening-before <wpt>) falls before target day, clamp to 00:00.
                if start < targetInterval.start {
                    start = targetInterval.start
                }
                if start >= targetInterval.end {
                    start = targetInterval.start.addingTimeInterval(Double(idx) * 1800)
                }

                var end = rawEnd ?? nextStart ?? dayEndMinusMinute
                if end > targetInterval.end {
                    end = dayEndMinusMinute
                }
                if end <= start {
                    end = min(targetInterval.end, start.addingTimeInterval(300))
                }

                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let placeName = trimmedName.isEmpty ? "Place" : trimmedName
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                let placeID: String
                if let match = savedPlaces.first(where: {
                    $0.name.caseInsensitiveCompare(placeName) == .orderedSame && $0.distance(to: coord) <= 150
                }) {
                    placeID = match.id
                } else {
                    let created = SavedPlace(
                        id: UUID().uuidString,
                        name: placeName,
                        googlePlaceID: nil,
                        address: nil,
                        latitude: lat,
                        longitude: lon,
                        radiusMeters: 80,
                        visitCount: 1,
                        lastVisitedAt: end
                    )
                    savedPlaces.append(created)
                    newSavedPlaces.append(created)
                    placeID = created.id
                }

                segments.append(TimelineSegment(
                    id: UUID().uuidString,
                    localDayKey: targetLocalDayKey,
                    kind: .stationary,
                    startDate: start,
                    endDate: end,
                    activityTypeID: nil,
                    placeID: placeID,
                    placeName: placeName,
                    latitude: lat,
                    longitude: lon,
                    isConfirmed: true,
                    sortOrder: segments.count
                ))

                visits.append(RawVisitEvent(
                    id: nextVisitID,
                    arrivalDate: start,
                    departureDate: end,
                    latitude: lat,
                    longitude: lon,
                    horizontalAccuracy: 10,
                    recordedAt: end
                ))
                nextVisitID += 1

                // Anchor samples at start and end of stationary dwell
                samples.append(RawLocationSample(
                    id: nextSampleID,
                    timestamp: start,
                    latitude: lat,
                    longitude: lon,
                    horizontalAccuracy: 8,
                    altitude: 0,
                    speed: 0,
                    course: 0,
                    source: .singleFix
                ))
                nextSampleID += 1

                if end.timeIntervalSince(start) > 10 {
                    samples.append(RawLocationSample(
                        id: nextSampleID,
                        timestamp: end.addingTimeInterval(-1),
                        latitude: lat,
                        longitude: lon,
                        horizontalAccuracy: 8,
                        altitude: 0,
                        speed: 0,
                        course: 0,
                        source: .singleFix
                    ))
                    nextSampleID += 1
                }

            case .move(let rawName, let rawType, let rawStart, let rawEnd, let pts):
                var start = rawStart ?? (segments.last?.endDate ?? targetInterval.start.addingTimeInterval(9 * 3600))
                if start < targetInterval.start { start = targetInterval.start }
                var end = rawEnd ?? nextStart ?? start.addingTimeInterval(600)
                if end > targetInterval.end { end = dayEndMinusMinute }
                if end <= start { end = min(targetInterval.end, start.addingTimeInterval(60)) }

                let activityID = resolveActivityTypeID(
                    rawName: rawName,
                    rawType: rawType,
                    existing: &activityTypes,
                    created: &newActivityTypes
                )

                segments.append(TimelineSegment(
                    id: UUID().uuidString,
                    localDayKey: targetLocalDayKey,
                    kind: .move,
                    startDate: start,
                    endDate: end,
                    activityTypeID: activityID,
                    placeID: nil,
                    placeName: nil,
                    latitude: pts.first?.lat,
                    longitude: pts.first?.lon,
                    isConfirmed: true,
                    sortOrder: segments.count
                ))

                // Convert trackpoints into RawLocationSamples with valid timestamps and speeds
                let duration = max(1, end.timeIntervalSince(start))
                var prevSample: RawLocationSample?
                for (pIdx, pt) in pts.enumerated() {
                    let frac = pts.count > 1 ? Double(pIdx) / Double(pts.count - 1) : 0
                    var ptDate = pt.time ?? start.addingTimeInterval(frac * duration)
                    if ptDate < start { ptDate = start }
                    if ptDate > end { ptDate = end }

                    var speed = 0.0
                    if let prev = prevSample {
                        let dt = ptDate.timeIntervalSince(prev.timestamp)
                        if dt > 0.5 {
                            let d = CLLocation(latitude: pt.lat, longitude: pt.lon)
                                .distance(from: CLLocation(latitude: prev.latitude, longitude: prev.longitude))
                            speed = min(80, d / dt)
                        }
                    }

                    let sample = RawLocationSample(
                        id: nextSampleID,
                        timestamp: ptDate,
                        latitude: pt.lat,
                        longitude: pt.lon,
                        horizontalAccuracy: 5,
                        altitude: pt.ele,
                        speed: speed,
                        course: 0,
                        source: .activeGPS
                    )
                    samples.append(sample)
                    prevSample = sample
                    nextSampleID += 1
                }
            }
        }

        samples.sort { $0.timestamp < $1.timestamp }

        return ImportResult(
            segments: segments,
            samples: samples,
            visits: visits,
            newActivityTypes: newActivityTypes,
            newSavedPlaces: newSavedPlaces,
            sourceDayKey: sourceDayKey,
            didOverrideDates: didOverrideDates
        )
    }

    private static func resolveActivityTypeID(
        rawName: String,
        rawType: String,
        existing: inout [ActivityType],
        created: inout [ActivityType]
    ) -> String {
        let candidates = [rawType, rawName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for candidate in candidates {
            let lower = candidate.lowercased()
            if let match = existing.first(where: {
                $0.id.lowercased() == lower
                    || $0.name.lowercased() == lower
                    || $0.gpxType == lower
            }) {
                return match.id
            }
        }

        // Common synonyms
        let slug = (candidates.first ?? "move").lowercased()
        if slug.contains("walk") || slug == "foot", let w = existing.first(where: { $0.id == "walking" }) {
            return w.id
        }
        if slug.contains("cycl") || slug.contains("bike"), let b = existing.first(where: { $0.id == "biking" }) {
            return b.id
        }
        if slug.contains("driv") || slug.contains("auto") || slug == "car", let c = existing.first(where: { $0.id == "car" }) {
            return c.id
        }

        // Create a new custom ActivityType for unrecognized GPX activity names (e.g. Scooter, Ferry)
        let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawType.capitalized
            : rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        let symbol: String
        let lowerName = displayName.lowercased()
        if lowerName.contains("scooter") { symbol = "scooter" }
        else if lowerName.contains("ferry") || lowerName.contains("boat") { symbol = "ferry.fill" }
        else if lowerName.contains("flight") || lowerName.contains("plane") { symbol = "airplane" }
        else if lowerName.contains("bus") { symbol = "bus.fill" }
        else if lowerName.contains("train") || lowerName.contains("subway") { symbol = "tram.fill" }
        else { symbol = "arrow.triangle.turn.up.right.diamond.fill" }

        let colorHex = ActivityType.paletteHexes[existing.count % ActivityType.paletteHexes.count]
        let newType = ActivityType(
            id: UUID().uuidString,
            name: displayName.isEmpty ? "Move" : displayName,
            sfSymbol: symbol,
            colorHex: colorHex,
            sortOrder: existing.count
        )
        existing.append(newType)
        created.append(newType)
        return newType.id
    }

    // MARK: - XMLParser Delegate

    private final class GPXParserDelegate: NSObject, XMLParserDelegate {
        var metadataName: String?
        var waypoints: [ParsedWaypoint] = []
        var tracks: [ParsedTrack] = []

        private var inMetadata = false
        private var currentWpt: ParsedWaypoint?
        private var currentTrk: ParsedTrack?
        private var currentTrkpt: ParsedTrackPoint?
        private var currentText = ""

        private let isoWithFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        private let isoBasic: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        private func parseISO(_ raw: String) -> Date? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return isoWithFrac.date(from: s) ?? isoBasic.date(from: s)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch elementName {
            case "metadata":
                inMetadata = true
            case "wpt":
                if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
                   let lat = Double(latStr), let lon = Double(lonStr) {
                    currentWpt = ParsedWaypoint(lat: lat, lon: lon, name: "", time: nil, dmStart: nil, dmEnd: nil)
                }
            case "trk":
                currentTrk = ParsedTrack(name: "", type: "", dmStart: nil, dmEnd: nil, points: [])
            case "trkpt":
                if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
                   let lat = Double(latStr), let lon = Double(lonStr) {
                    currentTrkpt = ParsedTrackPoint(lat: lat, lon: lon, ele: 0, time: nil)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            if currentTrkpt != nil {
                switch elementName {
                case "ele":
                    currentTrkpt?.ele = Double(trimmed) ?? 0
                case "time":
                    currentTrkpt?.time = parseISO(trimmed)
                case "trkpt":
                    if let pt = currentTrkpt {
                        currentTrk?.points.append(pt)
                    }
                    currentTrkpt = nil
                default:
                    break
                }
            } else if currentWpt != nil {
                switch elementName {
                case "name":
                    currentWpt?.name = trimmed
                case "time":
                    currentWpt?.time = parseISO(trimmed)
                case "dm:startTime", "startTime":
                    currentWpt?.dmStart = parseISO(trimmed)
                case "dm:endTime", "endTime":
                    currentWpt?.dmEnd = parseISO(trimmed)
                case "wpt":
                    if let w = currentWpt {
                        waypoints.append(w)
                    }
                    currentWpt = nil
                default:
                    break
                }
            } else if currentTrk != nil {
                switch elementName {
                case "name":
                    currentTrk?.name = trimmed
                case "type":
                    currentTrk?.type = trimmed
                case "dm:startTime", "startTime":
                    currentTrk?.dmStart = parseISO(trimmed)
                case "dm:endTime", "endTime":
                    currentTrk?.dmEnd = parseISO(trimmed)
                case "trk":
                    if let t = currentTrk {
                        tracks.append(t)
                    }
                    currentTrk = nil
                default:
                    break
                }
            } else if inMetadata {
                if elementName == "name" {
                    metadataName = trimmed
                } else if elementName == "metadata" {
                    inMetadata = false
                }
            }

            currentText = ""
        }
    }
}
