import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class DayTimelineViewModel {
    private let database: LocationDatabase

    var selectedDayKey: String
    var rawSampleCount: Int = 0
    var rawSamples: [RawLocationSample] = []
    var segments: [TimelineSegment] = []
    var reviewRecord: DayReviewRecord?
    var activityTypes: [ActivityType] = []
    var savedPlaces: [SavedPlace] = []
    var trackedDays: [TrackedDaySummary] = []

    var isProcessingReview: Bool = false
    var hasUnsavedChanges: Bool = false
    var hasNewerRawDataThanSavedReview: Bool = false
    var statusBanner: String?
    var errorMessage: String?

    init(database: LocationDatabase = .shared) {
        self.database = database
        self.selectedDayKey = DateFormatting.localDayKey(for: Date())
        reloadReferenceData()
        loadSelectedDayLight()
    }

    var isSelectedDayToday: Bool {
        selectedDayKey == DateFormatting.localDayKey(for: Date())
    }

    var displayDateTitle: String {
        DateFormatting.localDisplayDate(forDayKey: selectedDayKey)
    }

    var previewUTCExportDateKey: String {
        let dates = segments.isEmpty
            ? rawSamples.map(\.timestamp)
            : segments.flatMap { [$0.startDate, $0.endDate] }
        return DateFormatting.resolvedUTCExportDayKey(
            forLocalDayKey: selectedDayKey,
            eventDates: dates
        )
    }

    var previewExportFilename: String {
        "\(previewUTCExportDateKey).gpx"
    }

    func reloadReferenceData() {
        activityTypes = database.fetchActivityTypes()
        savedPlaces = database.fetchSavedPlaces()
        trackedDays = database.fetchTrackedDaySummaries()
    }

    /// Lightweight load for the main screen: reads saved segments & sample count ONLY.
    /// Does NOT run segmentation, motion queries, or any heavy processing!
    func loadSelectedDayLight() {
        hasUnsavedChanges = false
        statusBanner = nil
        rawSamples = []
        segments = database.fetchSegments(forLocalDayKey: selectedDayKey)
        reviewRecord = database.fetchDayReview(forLocalDayKey: selectedDayKey)
        if let interval = DateFormatting.localDayInterval(forDayKey: selectedDayKey) {
            rawSampleCount = database.sampleCount(from: interval.start, to: interval.end)
        } else {
            rawSampleCount = 0
        }
    }

    func selectDay(_ dayKey: String) {
        selectedDayKey = dayKey
        loadSelectedDayLight()
    }

    func goToPreviousDay() {
        guard let current = DateFormatting.date(fromDayKey: selectedDayKey),
              let prev = DateFormatting.localCalendar().date(byAdding: .day, value: -1, to: current) else { return }
        selectDay(DateFormatting.localDayKey(for: prev))
    }

    func goToNextDay() {
        guard !isSelectedDayToday,
              let current = DateFormatting.date(fromDayKey: selectedDayKey),
              let next = DateFormatting.localCalendar().date(byAdding: .day, value: 1, to: current) else { return }
        selectDay(DateFormatting.localDayKey(for: next))
    }

    // MARK: - Manual Review Trigger (On-Demand Processing)

    /// Called ONLY when the user manually enters Review mode.
    func enterReviewMode() async {
        isProcessingReview = true
        errorMessage = nil
        reloadReferenceData()

        guard let interval = DateFormatting.localDayInterval(forDayKey: selectedDayKey) else {
            isProcessingReview = false
            return
        }

        let loadedSamples = database.fetchSamples(from: interval.start, to: interval.end)
        rawSamples = loadedSamples
        rawSampleCount = loadedSamples.count

        let existing = database.fetchSegments(forLocalDayKey: selectedDayKey)
        if !existing.isEmpty {
            segments = existing
            hasUnsavedChanges = false
            if let lastRaw = loadedSamples.last?.timestamp,
               let reviewedAt = reviewRecord?.reviewedAt {
                hasNewerRawDataThanSavedReview = lastRaw > reviewedAt.addingTimeInterval(120)
            } else {
                hasNewerRawDataThanSavedReview = false
            }
            isProcessingReview = false
            return
        }

        hasNewerRawDataThanSavedReview = false
        await runAutoSegmentation(interval: interval, samples: loadedSamples)
        isProcessingReview = false
    }

    /// Re-runs auto-detection from raw samples & visits (replaces unsaved draft or reviewed timeline).
    func redetectFromRawData() async {
        isProcessingReview = true
        errorMessage = nil
        reloadReferenceData()

        guard let interval = DateFormatting.localDayInterval(forDayKey: selectedDayKey) else {
            isProcessingReview = false
            return
        }
        let loadedSamples = database.fetchSamples(from: interval.start, to: interval.end)
        rawSamples = loadedSamples
        rawSampleCount = loadedSamples.count

        await runAutoSegmentation(interval: interval, samples: loadedSamples)
        isProcessingReview = false
    }

    private func runAutoSegmentation(interval: DateInterval, samples: [RawLocationSample]) async {
        let visits = database.fetchVisits(overlapping: interval)
        let motionHints = await MotionActivityHintService.shared.queryHints(from: interval.start, to: interval.end)
        let detected = TimelineSegmenter.segment(
            localDayKey: selectedDayKey,
            dayInterval: interval,
            samples: samples,
            visits: visits,
            savedPlaces: savedPlaces,
            activityTypes: activityTypes,
            motionHints: motionHints
        )
        segments = detected
        hasUnsavedChanges = !detected.isEmpty
        hasNewerRawDataThanSavedReview = false
    }

    // MARK: - Editing Operations

    func activityType(for id: String?) -> ActivityType {
        if let id, let found = activityTypes.first(where: { $0.id == id }) {
            return found
        }
        return activityTypes.first ?? ActivityType.defaults[0]
    }

    func samples(for segment: TimelineSegment) -> [RawLocationSample] {
        rawSamples.filter { $0.timestamp >= segment.startDate && $0.timestamp <= segment.endDate }
    }

    func distanceMeters(for segment: TimelineSegment) -> Double {
        TimelineSegmenter.totalDistance(samples: rawSamples, from: segment.startDate, to: segment.endDate)
    }

    func updateSegment(_ updated: TimelineSegment, snapAdjacent: Bool = true) {
        guard let idx = segments.firstIndex(where: { $0.id == updated.id }) else { return }
        var item = updated
        if item.endDate < item.startDate {
            item.endDate = item.startDate.addingTimeInterval(60)
        }
        if item.kind == .stationary {
            item.activityTypeID = nil
            if item.latitude == nil || item.longitude == nil {
                if let centroid = centroidForWindow(start: item.startDate, end: item.endDate) {
                    item.latitude = centroid.latitude
                    item.longitude = centroid.longitude
                }
            }
        } else {
            item.placeID = nil
            item.placeName = nil
            if item.activityTypeID == nil {
                item.activityTypeID = activityTypes.first?.id ?? "walking"
            }
        }
        item.isConfirmed = true
        segments[idx] = item

        if snapAdjacent {
            if idx > 0 {
                let prev = segments[idx - 1]
                if item.startDate > prev.startDate {
                    segments[idx - 1].endDate = item.startDate
                }
            }
            if idx + 1 < segments.count {
                let next = segments[idx + 1]
                if item.endDate < next.endDate {
                    segments[idx + 1].startDate = item.endDate
                }
            }
        }

        segments.sort { $0.startDate < $1.startDate }
        reindexSortOrders()
        hasUnsavedChanges = true
    }

    func mergeWithPrevious(segmentID: String) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }), idx > 0 else { return }
        mergePair(firstIndex: idx - 1, secondIndex: idx, keepStyleOf: idx)
    }

    func mergeWithNext(segmentID: String) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }), idx + 1 < segments.count else { return }
        mergePair(firstIndex: idx, secondIndex: idx + 1, keepStyleOf: idx)
    }

    private func mergePair(firstIndex: Int, secondIndex: Int, keepStyleOf keeperIndex: Int) {
        let first = segments[firstIndex]
        let second = segments[secondIndex]
        var merged = segments[keeperIndex]
        merged.startDate = min(first.startDate, second.startDate)
        merged.endDate = max(first.endDate, second.endDate)
        merged.isConfirmed = true

        if merged.kind == .stationary {
            if let centroid = centroidForWindow(start: merged.startDate, end: merged.endDate) {
                merged.latitude = centroid.latitude
                merged.longitude = centroid.longitude
            } else if merged.latitude == nil {
                merged.latitude = first.latitude ?? second.latitude
                merged.longitude = first.longitude ?? second.longitude
            }
        }

        segments[firstIndex] = merged
        segments.remove(at: secondIndex)
        reindexSortOrders()
        hasUnsavedChanges = true
    }

    func splitSegment(segmentID: String, at splitDate: Date) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let original = segments[idx]
        guard splitDate > original.startDate.addingTimeInterval(15),
              splitDate < original.endDate.addingTimeInterval(-15) else { return }

        var firstHalf = original
        firstHalf.endDate = splitDate

        var secondHalf = TimelineSegment(
            id: UUID().uuidString,
            localDayKey: selectedDayKey,
            kind: original.kind,
            startDate: splitDate,
            endDate: original.endDate,
            activityTypeID: original.activityTypeID,
            placeID: original.placeID,
            placeName: original.placeName,
            latitude: original.latitude,
            longitude: original.longitude,
            isConfirmed: false,
            sortOrder: idx + 1
        )

        if original.kind == .stationary {
            if let c1 = centroidForWindow(start: firstHalf.startDate, end: firstHalf.endDate) {
                firstHalf.latitude = c1.latitude
                firstHalf.longitude = c1.longitude
            }
            if let c2 = centroidForWindow(start: secondHalf.startDate, end: secondHalf.endDate) {
                secondHalf.latitude = c2.latitude
                secondHalf.longitude = c2.longitude
            }
        }

        segments[idx] = firstHalf
        segments.insert(secondHalf, at: idx + 1)
        reindexSortOrders()
        hasUnsavedChanges = true
    }

    func deleteSegment(segmentID: String) {
        segments.removeAll { $0.id == segmentID }
        reindexSortOrders()
        hasUnsavedChanges = true
    }

    func addManualSegment(kind: TimelineSegment.Kind) {
        let dayInterval = DateFormatting.localDayInterval(forDayKey: selectedDayKey)
        let start: Date
        let end: Date
        if let last = segments.last {
            start = last.endDate
            end = min(dayInterval?.end ?? start.addingTimeInterval(1800), start.addingTimeInterval(1800))
        } else if let interval = dayInterval {
            start = interval.start.addingTimeInterval(9 * 3600)
            end = start.addingTimeInterval(1800)
        } else {
            start = Date().addingTimeInterval(-1800)
            end = Date()
        }

        let fallbackCoord = rawSamples.last?.coordinate ?? segments.last?.coordinate
        let newSeg = TimelineSegment(
            id: UUID().uuidString,
            localDayKey: selectedDayKey,
            kind: kind,
            startDate: start,
            endDate: max(end, start.addingTimeInterval(300)),
            activityTypeID: kind == .move ? (activityTypes.first?.id ?? "walking") : nil,
            placeID: nil,
            placeName: kind == .stationary ? nil : nil,
            latitude: fallbackCoord?.latitude,
            longitude: fallbackCoord?.longitude,
            isConfirmed: true,
            sortOrder: segments.count
        )
        segments.append(newSeg)
        segments.sort { $0.startDate < $1.startDate }
        reindexSortOrders()
        hasUnsavedChanges = true
    }

    /// Assigns a place (from Saved Places, Google Places, or custom name) to a stationary segment
    /// and remembers it in `saved_places` so future visits auto-suggest it.
    func assignPlace(
        toSegmentID segmentID: String,
        name: String,
        googlePlaceID: String? = nil,
        address: String? = nil,
        coordinate: CLLocationCoordinate2D? = nil,
        existingPlaceID: String? = nil
    ) {
        guard let idx = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetCoord = coordinate
            ?? segments[idx].coordinate
            ?? centroidForWindow(start: segments[idx].startDate, end: segments[idx].endDate)

        var resolvedPlaceID = existingPlaceID

        if let coord = targetCoord {
            if let existingID = existingPlaceID,
               var existing = savedPlaces.first(where: { $0.id == existingID }) {
                existing.name = trimmed
                existing.lastVisitedAt = segments[idx].endDate
                database.upsertSavedPlace(existing)
                resolvedPlaceID = existing.id
            } else if let gID = googlePlaceID,
                      var matchByGoogle = savedPlaces.first(where: { $0.googlePlaceID == gID }) {
                matchByGoogle.name = trimmed
                matchByGoogle.lastVisitedAt = segments[idx].endDate
                database.upsertSavedPlace(matchByGoogle)
                resolvedPlaceID = matchByGoogle.id
            } else if var nearbySameName = savedPlaces.first(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame && $0.distance(to: coord) <= 120
            }) {
                nearbySameName.lastVisitedAt = segments[idx].endDate
                database.upsertSavedPlace(nearbySameName)
                resolvedPlaceID = nearbySameName.id
            } else {
                let newPlace = SavedPlace(
                    id: UUID().uuidString,
                    name: trimmed,
                    googlePlaceID: googlePlaceID,
                    address: address,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    radiusMeters: 80,
                    visitCount: 1,
                    lastVisitedAt: segments[idx].endDate
                )
                database.upsertSavedPlace(newPlace)
                resolvedPlaceID = newPlace.id
            }
            savedPlaces = database.fetchSavedPlaces()
        }

        segments[idx].kind = .stationary
        segments[idx].activityTypeID = nil
        segments[idx].placeID = resolvedPlaceID
        segments[idx].placeName = trimmed
        if let coord = targetCoord {
            segments[idx].latitude = coord.latitude
            segments[idx].longitude = coord.longitude
        }
        segments[idx].isConfirmed = true
        hasUnsavedChanges = true
    }

    // MARK: - Save & Export

    func saveReviewedDay() {
        let now = Date()
        // Persist any unnamed/newly confirmed places & bump visit counts for known places
        var updatedPlaces = Dictionary(uniqueKeysWithValues: savedPlaces.map { ($0.id, $0) })
        for idx in segments.indices {
            segments[idx].isConfirmed = true
            if segments[idx].kind == .stationary,
               let placeID = segments[idx].placeID,
               var place = updatedPlaces[placeID] {
                place.visitCount += 1
                place.lastVisitedAt = max(place.lastVisitedAt, segments[idx].endDate)
                database.upsertSavedPlace(place)
                updatedPlaces[placeID] = place
            }
        }

        database.replaceSegments(segments, forLocalDayKey: selectedDayKey)

        let utcKey = previewUTCExportDateKey
        var record = reviewRecord ?? DayReviewRecord(localDayKey: selectedDayKey)
        record.utcExportDateKey = utcKey
        record.reviewedAt = now
        database.upsertDayReview(record)
        reviewRecord = record

        hasUnsavedChanges = false
        reloadReferenceData()
        statusBanner = "Saved (\(utcKey) UTC)"
    }

    func buildGPXExportPackage() -> GPXExporter.ExportPackage {
        // Ensure raw samples are loaded if exporting directly from main screen.
        if rawSamples.isEmpty, let interval = DateFormatting.localDayInterval(forDayKey: selectedDayKey) {
            rawSamples = database.fetchSamples(from: interval.start, to: interval.end)
        }
        return GPXExporter.generate(
            localDayKey: selectedDayKey,
            segments: segments,
            rawSamples: rawSamples,
            activityTypes: activityTypes
        )
    }

    func markExported(package: GPXExporter.ExportPackage) {
        var record = reviewRecord ?? DayReviewRecord(localDayKey: selectedDayKey)
        record.utcExportDateKey = package.utcDateKey
        record.exportedAt = Date()
        record.lastExportFilename = package.filename
        database.upsertDayReview(record)
        reviewRecord = record
        reloadReferenceData()
    }

    func exportToSavedFolder() -> String? {
        if hasUnsavedChanges {
            saveReviewedDay()
        }
        let package = buildGPXExportPackage()
        do {
            _ = try ExportFolderBookmark.writeToSavedFolder(filename: package.filename, content: package.data)
            markExported(package: package)
            statusBanner = "Saved \(package.filename) to \(ExportFolderBookmark.savedFolderName ?? "folder")"
            return package.filename
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func writeTemporaryShareFile() -> URL? {
        if hasUnsavedChanges {
            saveReviewedDay()
        }
        let package = buildGPXExportPackage()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(package.filename)
        do {
            try package.data.write(to: tempURL, options: [.atomic])
            markExported(package: package)
            return tempURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    private func reindexSortOrders() {
        for idx in segments.indices {
            segments[idx].sortOrder = idx
        }
    }

    private func centroidForWindow(start: Date, end: Date) -> CLLocationCoordinate2D? {
        let windowSamples = rawSamples.filter { $0.timestamp >= start && $0.timestamp <= end }
        guard !windowSamples.isEmpty else { return nil }
        let lat = windowSamples.map(\.latitude).reduce(0, +) / Double(windowSamples.count)
        let lon = windowSamples.map(\.longitude).reduce(0, +) / Double(windowSamples.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
