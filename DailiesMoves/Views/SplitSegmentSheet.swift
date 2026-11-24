import SwiftUI
import MapKit

/// Interactive Visual Map + Speed Profile + Point-by-Point Scrubber for splitting any segment
/// at the exact street corner and GPS timestamp (e.g. Car/Scooter -> Walking -> Stationary).
struct SplitSegmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: DayTimelineViewModel
    let segment: TimelineSegment

    private let trackPoints: [RawLocationSample]
    private let pointSpeeds: [Double]

    @State private var selectedIndex: Int
    @State private var fallbackSplitDate: Date
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followPin: Bool = false

    @State private var firstKind: TimelineSegment.Kind
    @State private var firstActivityID: String
    @State private var secondKind: TimelineSegment.Kind
    @State private var secondActivityID: String

    init(viewModel: DayTimelineViewModel, segment: TimelineSegment) {
        self.viewModel = viewModel
        self.segment = segment

        let pts = viewModel.cleanSamples(for: segment)
        self.trackPoints = pts

        var speeds: [Double] = Array(repeating: 0, count: pts.count)
        for i in pts.indices {
            if pts[i].speed >= 0 && pts[i].speed < 80 {
                speeds[i] = pts[i].speed
            } else if i > 0 {
                let dt = pts[i].timestamp.timeIntervalSince(pts[i - 1].timestamp)
                speeds[i] = dt > 0.5 ? min(80, pts[i].distance(to: pts[i - 1]) / dt) : 0
            }
        }
        self.pointSpeeds = speeds

        // Start cursor at the midpoint (or largest speed drop if detectable)
        let defaultIdx: Int
        if pts.count >= 4 {
            let rawIdx = Self.suggestedSplitIndex(points: pts, speeds: speeds)
            defaultIdx = min(max(rawIdx, 1), pts.count - 2)
        } else {
            defaultIdx = 0
        }
        _selectedIndex = State(initialValue: defaultIdx)
        _fallbackSplitDate = State(initialValue: segment.startDate.addingTimeInterval(segment.duration / 2))

        let defaultAct = segment.activityTypeID ?? viewModel.activityTypes.first?.id ?? "walking"
        _firstKind = State(initialValue: segment.kind)
        _secondKind = State(initialValue: segment.kind)
        _firstActivityID = State(initialValue: defaultAct)
        _secondActivityID = State(initialValue: Self.guessActivityID(
            speeds: Array(speeds.dropFirst(min(defaultIdx, speeds.count))),
            fallback: defaultAct,
            available: viewModel.activityTypes
        ))
    }

    /// Requires at least 4 points so `1...(count - 2)` always has strictly `min < max` for SwiftUI `Slider`.
    private var hasScrubbablePoints: Bool {
        trackPoints.count >= 4
    }

    private var safeFallbackDateRange: ClosedRange<Date> {
        let lo = segment.startDate.addingTimeInterval(1)
        let hi = max(lo.addingTimeInterval(1), segment.endDate.addingTimeInterval(-1))
        return lo...hi
    }

    private var currentSplitDate: Date {
        guard hasScrubbablePoints else { return fallbackSplitDate }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return trackPoints[clamped].timestamp
    }

    private var selectedPoint: RawLocationSample? {
        guard hasScrubbablePoints else { return nil }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return trackPoints[clamped]
    }

    private var selectedSpeed: Double {
        guard hasScrubbablePoints else { return 0 }
        let clamped = min(max(selectedIndex, 1), pointSpeeds.count - 1)
        return pointSpeeds[clamped]
    }

    private var beforeCoords: [CLLocationCoordinate2D] {
        guard hasScrubbablePoints else { return [] }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return trackPoints[0...clamped].map(\.coordinate)
    }

    private var afterCoords: [CLLocationCoordinate2D] {
        guard hasScrubbablePoints else { return [] }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return trackPoints[clamped..<trackPoints.count].map(\.coordinate)
    }

    /// Downsampled speed dots (<= 80 dots) so the map stays silky smooth even on 500-point rides.
    private var sampledSpeedDots: [(id: Int, coord: CLLocationCoordinate2D, color: Color)] {
        guard hasScrubbablePoints else { return [] }
        let step = max(1, trackPoints.count / 80)
        var dots: [(Int, CLLocationCoordinate2D, Color)] = []
        var i = 0
        while i < trackPoints.count {
            dots.append((i, trackPoints[i].coordinate, Self.speedColor(pointSpeeds[i])))
            i += step
        }
        return dots
    }

    private var beforeDistance: Double {
        guard hasScrubbablePoints else { return 0 }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return Self.polylineDistance(Array(trackPoints[0...clamped]))
    }

    private var afterDistance: Double {
        guard hasScrubbablePoints else { return 0 }
        let clamped = min(max(selectedIndex, 1), trackPoints.count - 2)
        return Self.polylineDistance(Array(trackPoints[clamped..<trackPoints.count]))
    }

    private var firstColor: Color {
        firstKind == .stationary ? .orange : viewModel.activityType(for: firstActivityID).swiftUIColor
    }

    private var secondColor: Color {
        secondKind == .stationary ? .orange : viewModel.activityType(for: secondActivityID).swiftUIColor
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. Interactive Split Map
                MapReader { proxy in
                    Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                        if beforeCoords.count >= 2 {
                            MapPolyline(coordinates: beforeCoords)
                                .stroke(firstColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        if afterCoords.count >= 2 {
                            MapPolyline(coordinates: afterCoords)
                                .stroke(secondColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }

                        ForEach(sampledSpeedDots, id: \.id) { dot in
                            Annotation("", coordinate: dot.coord) {
                                Circle()
                                    .fill(dot.color)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(.white, lineWidth: 1))
                            }
                        }

                        if let pt = selectedPoint {
                            Annotation("Split", coordinate: pt.coordinate) {
                                ZStack {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 32, height: 32)
                                        .shadow(radius: 3)
                                    Image(systemName: "scissors.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                }
                            }
                        } else if let coord = segment.coordinate {
                            Marker(segment.placeName ?? "Place", systemImage: "mappin.circle.fill", coordinate: coord)
                                .tint(.orange)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .onTapGesture { screenPoint in
                        guard hasScrubbablePoints,
                              let tappedCoord = proxy.convert(screenPoint, from: .local) else { return }
                        jumpToNearestPoint(to: tappedCoord)
                    }
                }
                .frame(minHeight: 280, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    speedLegendPill
                        .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            followPin.toggle()
                            if followPin { focusOnSelectedPoint() }
                        } label: {
                            Image(systemName: followPin ? "scope" : "location")
                                .font(.subheadline)
                                .padding(8)
                                .background(followPin ? Color.accentColor : Color(.systemBackground).opacity(0.9), in: Circle())
                                .foregroundStyle(followPin ? .white : .primary)
                        }

                        Button {
                            followPin = false
                            withAnimation(.easeInOut(duration: 0.2)) {
                                cameraPosition = .automatic
                            }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline)
                                .padding(8)
                                .background(Color(.systemBackground).opacity(0.9), in: Circle())
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(10)
                }

                // 2. Scrubber + Speed Sparkline + Telemetry + Half Selectors
                VStack(spacing: 12) {
                    if hasScrubbablePoints {
                        // Telemetry Strip
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DateFormatting.localTime(currentSplitDate))
                                    .font(.headline.monospacedDigit())
                                Text("Point \(selectedIndex + 1) of \(trackPoints.count) · Tap map or scrub")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.1f km/h (%.1f m/s)", selectedSpeed * 3.6, selectedSpeed))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Self.speedColor(selectedSpeed))
                                Text(Self.paceLabel(selectedSpeed))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Speed Sparkline (tap/drag directly to spot Scooter -> Walking cliffs!)
                        speedSparkline

                        // Precision Slider + Fine-Step Buttons
                        HStack(spacing: 8) {
                            stepButton(label: "-10", delta: -10)
                            stepButton(label: "-1", delta: -1)
                            Slider(
                                value: Binding(
                                    get: { Double(selectedIndex) },
                                    set: { newVal in
                                        selectedIndex = min(max(Int(newVal.rounded()), 1), trackPoints.count - 2)
                                        if followPin { focusOnSelectedPoint() }
                                    }
                                ),
                                in: 1...Double(trackPoints.count - 2),
                                step: 1
                            )
                            stepButton(label: "+1", delta: 1)
                            stepButton(label: "+10", delta: 10)
                        }
                    } else {
                        DatePicker(
                            "Split Time (Local)",
                            selection: $fallbackSplitDate,
                            in: safeFallbackDateRange,
                            displayedComponents: [.hourAndMinute]
                        )
                        Text("Few GPS points in this segment — choose split time directly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Before & After Split Cards (with 1-tap Kind / Move Type picker)
                    HStack(spacing: 10) {
                        halfConfigCard(
                            title: "Before Split",
                            duration: currentSplitDate.timeIntervalSince(segment.startDate),
                            distance: beforeDistance,
                            kind: $firstKind,
                            activityID: $firstActivityID
                        )
                        halfConfigCard(
                            title: "After Split",
                            duration: segment.endDate.timeIntervalSince(currentSplitDate),
                            distance: afterDistance,
                            kind: $secondKind,
                            activityID: $secondActivityID
                        )
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Split on Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split Here") {
                        viewModel.splitSegment(
                            segmentID: segment.id,
                            at: currentSplitDate,
                            firstKind: firstKind,
                            firstActivityTypeID: firstKind == .move ? firstActivityID : nil,
                            secondKind: secondKind,
                            secondActivityTypeID: secondKind == .move ? secondActivityID : nil
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Subviews

    private var speedLegendPill: some View {
        HStack(spacing: 8) {
            legendDot(.green, "Walk")
            legendDot(.orange, "Slow")
            legendDot(.red, "Fast")
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    private var speedSparkline: some View {
        GeometryReader { geo in
            let maxSpeed = max(pointSpeeds.max() ?? 10.0, 5.0)
            let barCount = min(pointSpeeds.count, 70)
            let fraction = Double(selectedIndex) / Double(max(1, trackPoints.count - 1))

            ZStack(alignment: .leading) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0..<barCount, id: \.self) { bucket in
                        let startIdx = bucket * pointSpeeds.count / barCount
                        let endIdx = max(startIdx + 1, (bucket + 1) * pointSpeeds.count / barCount)
                        let slice = pointSpeeds[startIdx..<min(endIdx, pointSpeeds.count)]
                        let avg = slice.reduce(0, +) / Double(max(1, slice.count))
                        let normalized = min(1.0, avg / maxSpeed)

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Self.speedColor(avg).opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(3, CGFloat(normalized) * (geo.size.height - 4)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Red split cursor line
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2.5, height: geo.size.height)
                    .offset(x: CGFloat(fraction) * max(0, geo.size.width - 2.5))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(value.location.x / max(1, geo.size.width), 0), 1)
                        let idx = Int((ratio * Double(trackPoints.count - 1)).rounded())
                        selectedIndex = min(max(idx, 1), trackPoints.count - 2)
                        if followPin { focusOnSelectedPoint() }
                    }
            )
        }
        .frame(height: 42)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stepButton(label: String, delta: Int) -> some View {
        Button {
            selectedIndex = min(max(selectedIndex + delta, 1), trackPoints.count - 2)
            if followPin { focusOnSelectedPoint() }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func halfConfigCard(
        title: String,
        duration: TimeInterval,
        distance: Double,
        kind: Binding<TimelineSegment.Kind>,
        activityID: Binding<String>
    ) -> some View {
        let isStationary = kind.wrappedValue == .stationary
        let act = viewModel.activityType(for: activityID.wrappedValue)
        let accent: Color = isStationary ? .orange : act.swiftUIColor

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Menu {
                Button {
                    kind.wrappedValue = .stationary
                } label: {
                    Label("Stationary Place", systemImage: "mappin.circle.fill")
                }
                Divider()
                ForEach(viewModel.activityTypes) { option in
                    Button {
                        kind.wrappedValue = .move
                        activityID.wrappedValue = option.id
                    } label: {
                        Label(option.name, systemImage: option.sfSymbol)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isStationary ? "mappin.circle.fill" : act.sfSymbol)
                        .foregroundStyle(accent)
                    Text(isStationary ? "Stationary" : act.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 4) {
                Text(DateFormatting.duration(max(0, duration)))
                if distance >= 10 {
                    Text("·")
                    Text(DateFormatting.distance(distance))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func jumpToNearestPoint(to coordinate: CLLocationCoordinate2D) {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var bestIdx = selectedIndex
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for i in 1..<(trackPoints.count - 1) {
            let d = trackPoints[i].distance(to: target.coordinate)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        selectedIndex = bestIdx
        if followPin { focusOnSelectedPoint() }
    }

    private func focusOnSelectedPoint() {
        guard let pt = selectedPoint else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: pt.coordinate,
                latitudinalMeters: 350,
                longitudinalMeters: 350
            ))
        }
    }

    private static func speedColor(_ speed: Double) -> Color {
        if speed < 0.35 { return .gray }
        if speed < 2.3 { return .green }
        if speed < 6.0 { return .orange }
        return .red
    }

    private static func paceLabel(_ speed: Double) -> String {
        if speed < 0.35 { return "Stopped / Stationary" }
        if speed < 2.3 { return "Walking pace" }
        if speed < 6.0 { return "Biking / Slow vehicle" }
        return "Scooter / Car pace"
    }

    private static func polylineDistance(_ pts: [RawLocationSample]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count {
            total += pts[i].distance(to: pts[i - 1])
        }
        return total
    }

    /// Starts the scrubber right on the biggest speed regime change if one exists, else midpoint.
    private static func suggestedSplitIndex(points: [RawLocationSample], speeds: [Double]) -> Int {
        guard points.count >= 10 else { return points.count / 2 }
        var bestIdx = points.count / 2
        var bestDiff = 0.0
        let win = min(6, points.count / 5)
        for i in win..<(points.count - win) {
            let leftAvg = speeds[(i - win)..<i].reduce(0, +) / Double(win)
            let rightAvg = speeds[i..<(i + win)].reduce(0, +) / Double(win)
            let diff = abs(leftAvg - rightAvg)
            if diff > bestDiff {
                bestDiff = diff
                bestIdx = i
            }
        }
        return bestDiff > 2.0 ? bestIdx : (points.count / 2)
    }

    private static func guessActivityID(
        speeds: [Double],
        fallback: String,
        available: [ActivityType]
    ) -> String {
        let valid = speeds.filter { $0 > 0.3 && $0 < 80 }.sorted()
        guard !valid.isEmpty else { return fallback }
        let med = valid[valid.count / 2]
        let guess = med >= 6.5 ? "car" : (med >= 2.8 ? "biking" : "walking")
        return available.contains(where: { $0.id == guess }) ? guess : fallback
    }
}
