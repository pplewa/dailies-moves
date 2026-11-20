import Foundation
import CoreLocation

/// A reviewed or auto-detected timeline entry for a day: either Stationary (at a place) or Move.
/// All timestamps are stored as UTC `Date` instances; UI displays them in local timezone.
struct TimelineSegment: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case stationary
        case move
    }

    let id: String
    var localDayKey: String          // Local calendar day key, e.g. "2026-11-19"
    var kind: Kind
    var startDate: Date              // UTC timestamp
    var endDate: Date                // UTC timestamp
    var activityTypeID: String?      // Non-nil when kind == .move
    var placeID: String?             // Optional reference to SavedPlace.id
    var placeName: String?           // User-chosen or matched place name when stationary
    var latitude: Double?            // Centroid latitude for stationary (or start lat)
    var longitude: Double?           // Centroid longitude for stationary (or start lon)
    var isConfirmed: Bool
    var sortOrder: Int

    var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
