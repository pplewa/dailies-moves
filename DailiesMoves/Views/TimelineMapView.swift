import SwiftUI
import MapKit

/// Read-only static Map preview for Review mode.
/// Intentionally does NOT enable `UserAnnotation` or live location tracking so viewing the map uses zero GPS power.
struct TimelineMapView: View {
    let segments: [TimelineSegment]
    let rawSamples: [RawLocationSample]
    let activityTypes: [ActivityType]
    let selectedSegmentID: String?

    @State private var cameraPosition: MapCameraPosition = .automatic

    private var activityLookup: [String: ActivityType] {
        Dictionary(uniqueKeysWithValues: activityTypes.map { ($0.id, $0) })
    }

    var body: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            ForEach(segments) { segment in
                if segment.kind == .move {
                    let coords = coordinates(for: segment)
                    if coords.count >= 2 {
                        let color = segment.activityTypeID.flatMap { activityLookup[$0]?.swiftUIColor } ?? .blue
                        let isSelected = segment.id == selectedSegmentID
                        MapPolyline(coordinates: coords)
                            .stroke(color, style: StrokeStyle(lineWidth: isSelected ? 6 : 3.5, lineCap: .round, lineJoin: .round))
                    }
                } else if let coord = segment.coordinate {
                    let isSelected = segment.id == selectedSegmentID
                    Marker(
                        segment.placeName ?? "Stationary",
                        systemImage: "mappin.circle.fill",
                        coordinate: coord
                    )
                    .tint(isSelected ? .red : .orange)
                }
            }

            if segments.isEmpty && rawSamples.count >= 2 {
                MapPolyline(coordinates: rawSamples.map(\.coordinate))
                    .stroke(.blue, lineWidth: 3)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: selectedSegmentID) { _, newID in
            focusCamera(on: newID)
        }
    }

    private func coordinates(for segment: TimelineSegment) -> [CLLocationCoordinate2D] {
        let filtered = rawSamples.filter {
            $0.source != .visitAnchor
                && $0.horizontalAccuracy >= 0
                && $0.horizontalAccuracy <= 100
                && $0.timestamp >= segment.startDate
                && $0.timestamp <= segment.endDate
        }
        return TimelineSegmenter.removeTeleportSpikes(filtered).map(\.coordinate)
    }

    private func focusCamera(on segmentID: String?) {
        guard let segmentID, let segment = segments.first(where: { $0.id == segmentID }) else {
            withAnimation(.easeInOut(duration: 0.25)) {
                cameraPosition = .automatic
            }
            return
        }

        if segment.kind == .stationary, let coord = segment.coordinate {
            let region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 450,
                longitudinalMeters: 450
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                cameraPosition = .region(region)
            }
        } else {
            let coords = coordinates(for: segment)
            guard !coords.isEmpty else { return }
            let lats = coords.map(\.latitude)
            let lons = coords.map(\.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                longitudeDelta: max((maxLon - minLon) * 1.4, 0.004)
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
            }
        }
    }
}
