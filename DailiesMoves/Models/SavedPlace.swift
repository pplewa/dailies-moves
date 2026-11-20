import Foundation
import CoreLocation

/// Previously visited place remembered locally so future stationary segments auto-suggest it.
struct SavedPlace: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var googlePlaceID: String?
    var address: String?
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var visitCount: Int
    var lastVisitedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
