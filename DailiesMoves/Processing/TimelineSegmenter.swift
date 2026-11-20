import Foundation
import CoreLocation

/// On-demand timeline segmentation engine.
/// Runs ONLY when the user manually enters Review mode — never in the background.
enum TimelineSegmenter {
    struct Configuration: Sendable {
        var stationaryRadiusMeters: Double = 38
        var sleepGapMaxDistanceMeters: Double = 110
        var minStationaryDuration: TimeInterval = 180        // 3 min (CLVisit or known saved place)
        var minUnconfirmedSampleDwell: TimeInterval = 420    // 7 min for sample-only dwell (avoids long red-light false stops)
        var mergeGapSeconds: TimeInterval = 120              // Merge same-place stops separated by < 2 min
        var mergeDistanceMeters: Double = 75
        var minMoveDuration: TimeInterval = 30
    }

    private struct RawDwell {
        var start: Date
        var end: Date
        var latitude: Double
        var longitude: Double
        var weight: Int
    }

    /// Segments raw samples and passive CLVisits for a local day into alternating Stationary and Move segments.
    static func segment(
        localDayKey: String,
        dayInterval: DateInterval,
        samples: [RawLocationSample],
        visits: [RawVisitEvent],
        savedPlaces: [SavedPlace],
        activityTypes: [ActivityType],
        motionHints: [MotionActivityHintService.MotionInterval] = [],
        now: Date = Date(),
        config: Configuration = Configuration()
    ) -> [TimelineSegment] {
        // 1. Clean raw samples: drop coarse non-visit points & single-point indoor GPS teleport spikes.
        let cleanedSamples = removeTeleportSpikes(
            samples
                .filter { $0.horizontalAccuracy >= 0 && ($0.source == .visitAnchor ? $0.horizontalAccuracy <= 150 : $0.horizontalAccuracy <= 100) }
                .sorted { $0.timestamp < $1.timestamp }
        )

        // Track samples exclude coarse CLVisit centroid anchors so polylines/speeds stay clean.
        let trackSamples = cleanedSamples.filter { $0.source != .visitAnchor }

        // 2. Collect candidate stationary dwells from both cleaned samples (including sleep gaps) and deduplicated CLVisits.
        var dwells: [RawDwell] = detectSampleDwells(samples: trackSamples, savedPlaces: savedPlaces, config: config)

        let resolvedVisitDwells = resolveVisitsToDwells(
            visits: visits,
            cleanSamples: trackSamples,
            dayInterval: dayInterval,
            now: now,
            config: config
        )
        dwells.append(contentsOf: resolvedVisitDwells)

        // Handle edge case: very few samples all at one place -> single stationary segment.
        if dwells.isEmpty && !trackSamples.isEmpty {
            let first = trackSamples.first!
            let last = trackSamples.last!
            let maxDist = trackSamples.map { $0.distance(to: first) }.max() ?? 0
            if maxDist <= config.stationaryRadiusMeters {
                let end = max(last.timestamp, first.timestamp.addingTimeInterval(60))
                dwells.append(RawDwell(
                    start: first.timestamp,
                    end: end,
                    latitude: average(trackSamples.map(\.latitude)),
                    longitude: average(trackSamples.map(\.longitude)),
                    weight: trackSamples.count
                ))
            }
        }

        // 3. Merge overlapping or nearby stationary dwells.
        let mergedDwells = mergeDwells(dwells, config: config)
            .compactMap { dwell -> RawDwell? in
                let clampedStart = max(dayInterval.start, dwell.start)
                let clampedEnd = min(dayInterval.end, dwell.end)
                guard clampedEnd > clampedStart else { return nil }
                return RawDwell(
                    start: clampedStart,
                    end: clampedEnd,
                    latitude: dwell.latitude,
                    longitude: dwell.longitude,
                    weight: dwell.weight
                )
            }

        // 4. Build alternating Stationary and Move segments.
        var segments: [TimelineSegment] = []

        if mergedDwells.isEmpty {
            if let first = trackSamples.first, let last = trackSamples.last, last.timestamp > first.timestamp {
                segments.append(makeMoveSegment(
                    localDayKey: localDayKey,
                    start: max(dayInterval.start, first.timestamp),
                    end: min(dayInterval.end, last.timestamp),
                    samples: trackSamples,
                    activityTypes: activityTypes,
                    motionHints: motionHints,
                    sortOrder: 0
                ))
            }
            return segments
        }

        // Leading move before first dwell (if meaningful travel occurred).
        if let firstSample = trackSamples.first,
           firstSample.timestamp < mergedDwells[0].start.addingTimeInterval(-config.minMoveDuration) {
            let leadSamples = trackSamples.filter { $0.timestamp <= mergedDwells[0].start }
            if hasMeaningfulMovement(samples: leadSamples, minDistance: config.stationaryRadiusMeters) {
                segments.append(makeMoveSegment(
                    localDayKey: localDayKey,
                    start: max(dayInterval.start, firstSample.timestamp),
                    end: mergedDwells[0].start,
                    samples: leadSamples,
                    activityTypes: activityTypes,
                    motionHints: motionHints,
                    sortOrder: segments.count
                ))
            }
        }

        for idx in mergedDwells.indices {
            let dwell = mergedDwells[idx]
            segments.append(makeStationarySegment(
                localDayKey: localDayKey,
                dwell: dwell,
                savedPlaces: savedPlaces,
                sortOrder: segments.count
            ))

            // Intervening move between dwell[idx] and dwell[idx + 1]
            if idx + 1 < mergedDwells.count {
                let nextDwell = mergedDwells[idx + 1]
                let gap = nextDwell.start.timeIntervalSince(dwell.end)
                if gap >= config.minMoveDuration {
                    let moveSamples = trackSamples.filter {
                        $0.timestamp >= dwell.end && $0.timestamp <= nextDwell.start
                    }
                    segments.append(makeMoveSegment(
                        localDayKey: localDayKey,
                        start: dwell.end,
                        end: nextDwell.start,
                        samples: moveSamples,
                        activityTypes: activityTypes,
                        motionHints: motionHints,
                        sortOrder: segments.count
                    ))
                } else if gap > 0 {
                    segments[segments.count - 1].endDate = nextDwell.start
                }
            }
        }

        // Trailing move after last dwell (if meaningful travel occurred).
        if let lastSample = trackSamples.last,
           let lastDwell = mergedDwells.last,
           lastSample.timestamp > lastDwell.end.addingTimeInterval(config.minMoveDuration) {
            let trailSamples = trackSamples.filter { $0.timestamp >= lastDwell.end }
            if hasMeaningfulMovement(samples: trailSamples, minDistance: config.stationaryRadiusMeters) {
                segments.append(makeMoveSegment(
                    localDayKey: localDayKey,
                    start: lastDwell.end,
                    end: min(dayInterval.end, lastSample.timestamp),
                    samples: trailSamples,
                    activityTypes: activityTypes,
                    motionHints: motionHints,
                    sortOrder: segments.count
                ))
            }
        }

        for i in segments.indices {
            segments[i].sortOrder = i
        }
        return segments
    }

    // MARK: - Spike Filtering

    /// Removes isolated indoor Wi-Fi/cell teleport spikes (A -> far B -> right back to A within 60s).
    static func removeTeleportSpikes(_ samples: [RawLocationSample]) -> [RawLocationSample] {
        guard samples.count >= 3 else { return samples }
        var kept: [RawLocationSample] = [samples[0]]

        for i in 1..<(samples.count - 1) {
            let prev = kept.last!
            let curr = samples[i]
            let next = samples[i + 1]

            let dPrevCurr = curr.distance(to: prev)
            let dCurrNext = curr.distance(to: next)
            let dPrevNext = next.distance(to: prev)
            let dtBack = next.timestamp.timeIntervalSince(curr.timestamp)

            // Classic bounce: jumped > 100m away and snapped back within < 60m of previous point in <= 60s.
            let isBounce = dPrevCurr > 100 && dCurrNext > 100 && dPrevNext < 60 && dtBack <= 60
            // Impossible instantaneous teleport (> 55 m/s ~ 200 km/h with poor accuracy or bounce).
            let dtPrev = max(0.5, curr.timestamp.timeIntervalSince(prev.timestamp))
            let isImpossibleJump = dPrevCurr > 120 && (dPrevCurr / dtPrev) > 55 && dCurrNext > 100

            if isBounce || isImpossibleJump {
                continue
            }
            kept.append(curr)
        }

        kept.append(samples.last!)
        return kept
    }

    // MARK: - CLVisit Deduplication & Safe Open-Ended Resolution

    private static func resolveVisitsToDwells(
        visits: [RawVisitEvent],
        cleanSamples: [RawLocationSample],
        dayInterval: DateInterval,
        now: Date,
        config: Configuration
    ) -> [RawDwell] {
        guard !visits.isEmpty else { return [] }

        // 1. Deduplicate CoreLocation's twin arrival/departure events for the same visit.
        let sorted = visits.sorted {
            ($0.arrivalDate ?? $0.recordedAt) < ($1.arrivalDate ?? $1.recordedAt)
        }
        var deduped: [RawVisitEvent] = []

        for visit in sorted {
            if let existingIdx = deduped.firstIndex(where: { existing in
                let dist = CLLocation(latitude: existing.latitude, longitude: existing.longitude)
                    .distance(from: CLLocation(latitude: visit.latitude, longitude: visit.longitude))
                guard dist <= 180 else { return false }

                if let a1 = existing.arrivalDate, let a2 = visit.arrivalDate {
                    return abs(a1.timeIntervalSince(a2)) <= 120
                }
                if let d1 = existing.departureDate, let d2 = visit.departureDate {
                    return abs(d1.timeIntervalSince(d2)) <= 120
                }
                return false
            }) {
                let existing = deduped[existingIdx]
                // Prefer the record that has both arrival & departure, then better accuracy.
                let existingScore = (existing.arrivalDate != nil ? 1 : 0) + (existing.departureDate != nil ? 2 : 0)
                let newScore = (visit.arrivalDate != nil ? 1 : 0) + (visit.departureDate != nil ? 2 : 0)
                if newScore > existingScore || (newScore == existingScore && visit.horizontalAccuracy < existing.horizontalAccuracy) {
                    deduped[existingIdx] = visit
                }
            } else {
                deduped.append(visit)
            }
        }

        // 2. Convert deduplicated visits to bounded RawDwells.
        // CRITICAL: Never let an open-ended visit (`departureDate == nil`) overwrite subsequent visits or moves!
        var dwells: [RawDwell] = []

        for (idx, visit) in deduped.enumerated() {
            let visitLoc = CLLocation(latitude: visit.latitude, longitude: visit.longitude)

            // Determine start: if arrivalDate is nil (arrived before monitoring began), anchor to earliest nearby sample.
            let vStart: Date
            if let arr = visit.arrivalDate {
                vStart = max(dayInterval.start, arr)
            } else if let dep = visit.departureDate {
                let nearbyBeforeDep = cleanSamples.first {
                    $0.timestamp <= dep && $0.distance(to: visit.coordinate) <= 120
                }
                vStart = max(dayInterval.start, nearbyBeforeDep?.timestamp ?? dayInterval.start)
            } else {
                continue
            }

            // Determine end safely:
            let vEnd: Date
            if let dep = visit.departureDate {
                vEnd = min(dayInterval.end, dep)
            } else {
                // Open-ended visit (departureDate == nil):
                // Check if ANY later visit (> 120m away) or clean sample (> 120m away, hAcc <= 65m) proves we left!
                let nextDifferentVisitStart: Date? = deduped[(idx + 1)...].compactMap { later -> Date? in
                    let laterLoc = CLLocation(latitude: later.latitude, longitude: later.longitude)
                    guard visitLoc.distance(from: laterLoc) > 120 else { return nil }
                    return later.arrivalDate ?? later.recordedAt
                }.min()

                let firstMovedSampleDate: Date? = cleanSamples.first { sample in
                    sample.timestamp > vStart.addingTimeInterval(60)
                        && sample.horizontalAccuracy <= 65
                        && sample.distance(to: visit.coordinate) > 120
                }?.timestamp

                let earliestDepartureProof = [nextDifferentVisitStart, firstMovedSampleDate].compactMap { $0 }.min()

                if let proof = earliestDepartureProof {
                    // We definitely left this visit before `proof`!
                    // Cap end at the last sample still near this place before `proof` (never extend past `proof`).
                    let lastNearbyBeforeProof = cleanSamples.last { sample in
                        sample.timestamp >= vStart
                            && sample.timestamp <= proof
                            && sample.distance(to: visit.coordinate) <= 120
                    }?.timestamp
                    vEnd = min(dayInterval.end, lastNearbyBeforeProof ?? vStart)
                } else {
                    // Truly the ongoing final visit of the day (no later visit or movement away).
                    let latestNearby = cleanSamples.last {
                        $0.timestamp >= vStart && $0.distance(to: visit.coordinate) <= 150
                    }?.timestamp
                    let upperBound = min(now, dayInterval.end)
                    vEnd = min(dayInterval.end, max(latestNearby ?? vStart, upperBound))
                }
            }

            guard vEnd.timeIntervalSince(vStart) >= config.minStationaryDuration else { continue }
            dwells.append(RawDwell(
                start: vStart,
                end: vEnd,
                latitude: visit.latitude,
                longitude: visit.longitude,
                weight: 5
            ))
        }

        return dwells
    }

    // MARK: - Dwell Detection

    private static func detectSampleDwells(
        samples: [RawLocationSample],
        savedPlaces: [SavedPlace],
        config: Configuration
    ) -> [RawDwell] {
        guard samples.count >= 2 else { return [] }

        var dwells: [RawDwell] = []
        var i = 0

        while i < samples.count {
            var j = i + 1
            var sumLat = samples[i].latitude
            var sumLon = samples[i].longitude
            var count = 1

            while j < samples.count {
                let centroid = CLLocationCoordinate2D(latitude: sumLat / Double(count), longitude: sumLon / Double(count))
                let dist = samples[j].distance(to: centroid)
                let timeGap = samples[j].timestamp.timeIntervalSince(samples[j - 1].timestamp)

                // Stop extending a dwell once sustained active travel starts (e.g. walking away > 1.0 m/s).
                let isMovingOut = timeGap < 45
                    && samples[j].speed >= 1.0
                    && samples[j - 1].speed >= 1.0
                    && dist > 18

                let isWithinCluster = dist <= config.stationaryRadiusMeters && !isMovingOut
                let isSleepGap = timeGap >= config.minStationaryDuration && dist <= config.sleepGapMaxDistanceMeters

                if isWithinCluster || isSleepGap {
                    sumLat += samples[j].latitude
                    sumLon += samples[j].longitude
                    count += 1
                    j += 1
                } else {
                    break
                }
            }

            let endIndex = j - 1
            if endIndex > i {
                let duration = samples[endIndex].timestamp.timeIntervalSince(samples[i].timestamp)
                let center = CLLocationCoordinate2D(latitude: sumLat / Double(count), longitude: sumLon / Double(count))
                let matchesKnownPlace = bestMatchingPlace(for: center, from: savedPlaces) != nil
                let requiredDuration = matchesKnownPlace ? config.minStationaryDuration : config.minUnconfirmedSampleDwell

                if duration >= requiredDuration {
                    dwells.append(RawDwell(
                        start: samples[i].timestamp,
                        end: samples[endIndex].timestamp,
                        latitude: center.latitude,
                        longitude: center.longitude,
                        weight: count
                    ))
                    i = endIndex
                    continue
                }
            }
            i += 1
        }

        return dwells
    }

    private static func mergeDwells(_ dwells: [RawDwell], config: Configuration) -> [RawDwell] {
        let sorted = dwells.sorted { $0.start < $1.start }
        var result: [RawDwell] = []

        for dwell in sorted {
            guard var prev = result.last else {
                result.append(dwell)
                continue
            }
            let prevLoc = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let currLoc = CLLocation(latitude: dwell.latitude, longitude: dwell.longitude)
            let dist = prevLoc.distance(from: currLoc)
            let gap = dwell.start.timeIntervalSince(prev.end)

            if (gap <= 0 && dist <= config.sleepGapMaxDistanceMeters) ||
               (gap <= config.mergeGapSeconds && dist <= config.mergeDistanceMeters) {
                let totalWeight = prev.weight + dwell.weight
                prev.latitude = (prev.latitude * Double(prev.weight) + dwell.latitude * Double(dwell.weight)) / Double(totalWeight)
                prev.longitude = (prev.longitude * Double(prev.weight) + dwell.longitude * Double(dwell.weight)) / Double(totalWeight)
                prev.end = max(prev.end, dwell.end)
                prev.weight = totalWeight
                result[result.count - 1] = prev
            } else if gap < 0 {
                // Overlapping dwells at two different locations: split cleanly at the later dwell's start
                // instead of dropping the later dwell!
                if dwell.start > prev.start && dwell.end > prev.end {
                    prev.end = dwell.start
                    if prev.end.timeIntervalSince(prev.start) >= config.minStationaryDuration {
                        result[result.count - 1] = prev
                    } else {
                        result.removeLast()
                    }
                    result.append(dwell)
                }
            } else {
                result.append(dwell)
            }
        }
        return result
    }

    // MARK: - Segment Factories & Activity Inference

    private static func makeStationarySegment(
        localDayKey: String,
        dwell: RawDwell,
        savedPlaces: [SavedPlace],
        sortOrder: Int
    ) -> TimelineSegment {
        let coord = CLLocationCoordinate2D(latitude: dwell.latitude, longitude: dwell.longitude)
        let matchedPlace = bestMatchingPlace(for: coord, from: savedPlaces)

        return TimelineSegment(
            id: UUID().uuidString,
            localDayKey: localDayKey,
            kind: .stationary,
            startDate: dwell.start,
            endDate: dwell.end,
            activityTypeID: nil,
            placeID: matchedPlace?.id,
            placeName: matchedPlace?.name,
            latitude: dwell.latitude,
            longitude: dwell.longitude,
            isConfirmed: false,
            sortOrder: sortOrder
        )
    }

    private static func makeMoveSegment(
        localDayKey: String,
        start: Date,
        end: Date,
        samples: [RawLocationSample],
        activityTypes: [ActivityType],
        motionHints: [MotionActivityHintService.MotionInterval],
        sortOrder: Int
    ) -> TimelineSegment {
        let inferredID = inferActivityTypeID(
            start: start,
            end: end,
            samples: samples,
            activityTypes: activityTypes,
            motionHints: motionHints
        )
        return TimelineSegment(
            id: UUID().uuidString,
            localDayKey: localDayKey,
            kind: .move,
            startDate: start,
            endDate: end,
            activityTypeID: inferredID,
            placeID: nil,
            placeName: nil,
            latitude: samples.first?.latitude,
            longitude: samples.first?.longitude,
            isConfirmed: false,
            sortOrder: sortOrder
        )
    }

    static func bestMatchingPlace(for coordinate: CLLocationCoordinate2D, from savedPlaces: [SavedPlace]) -> SavedPlace? {
        savedPlaces
            .compactMap { place -> (SavedPlace, CLLocationDistance)? in
                let dist = place.distance(to: coordinate)
                let threshold = max(place.radiusMeters, 80)
                guard dist <= threshold else { return nil }
                return (place, dist)
            }
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) < 20 {
                    return lhs.0.visitCount > rhs.0.visitCount
                }
                return lhs.1 < rhs.1
            }
            .first?.0
    }

    private static func inferActivityTypeID(
        start: Date,
        end: Date,
        samples: [RawLocationSample],
        activityTypes: [ActivityType],
        motionHints: [MotionActivityHintService.MotionInterval]
    ) -> String {
        let validIDs = Set(activityTypes.map(\.id))

        var votes: [String: TimeInterval] = [:]
        for hint in motionHints {
            guard let id = hint.suggestedActivityID, validIDs.contains(id) else { continue }
            let overlapStart = max(start, hint.startDate)
            let overlapEnd = min(end, hint.endDate)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            if overlap > 0 {
                votes[id, default: 0] += overlap
            }
        }
        if let best = votes.max(by: { $0.value < $1.value }), best.value >= 15 {
            return best.key
        }

        // Prefer GPS-reported speeds when available, otherwise compute segment speeds.
        // Use median (50th percentile) so a single building-exit GPS jump never turns a walk into a car ride.
        let reportedSpeeds = samples.map(\.speed).filter { $0 > 0.3 && $0 < 100 }
        let speeds = reportedSpeeds.isEmpty ? computeSegmentSpeeds(samples: samples) : reportedSpeeds
        let representativeSpeed: Double
        if !speeds.isEmpty {
            let sorted = speeds.sorted()
            let medianIndex = sorted.count / 2
            representativeSpeed = sorted[medianIndex]
        } else {
            representativeSpeed = 1.2
        }

        let guess: String
        if representativeSpeed >= 6.5 {
            guess = "car"
        } else if representativeSpeed >= 2.8 {
            guess = "biking"
        } else {
            guess = "walking"
        }

        if validIDs.contains(guess) {
            return guess
        }
        return activityTypes.first?.id ?? "walking"
    }

    private static func computeSegmentSpeeds(samples: [RawLocationSample]) -> [Double] {
        var speeds: [Double] = []
        for idx in 1..<samples.count {
            let dt = samples[idx].timestamp.timeIntervalSince(samples[idx - 1].timestamp)
            guard dt > 1 else { continue }
            let dist = samples[idx].distance(to: samples[idx - 1])
            let v = dist / dt
            if v >= 0 && v < 100 {
                speeds.append(v)
            }
        }
        return speeds
    }

    private static func hasMeaningfulMovement(samples: [RawLocationSample], minDistance: Double) -> Bool {
        guard let first = samples.first, samples.count >= 2 else { return false }
        let maxDisp = samples.map { $0.distance(to: first) }.max() ?? 0
        return maxDisp >= minDistance
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Computes total traveled distance (meters) across clean track samples within a time window.
    static func totalDistance(samples: [RawLocationSample], from start: Date, to end: Date) -> Double {
        let filtered = removeTeleportSpikes(
            samples.filter { $0.source != .visitAnchor && $0.timestamp >= start && $0.timestamp <= end }
        )
        guard filtered.count >= 2 else { return 0 }
        var total: Double = 0
        for idx in 1..<filtered.count {
            total += filtered[idx].distance(to: filtered[idx - 1])
        }
        return total
    }
}
