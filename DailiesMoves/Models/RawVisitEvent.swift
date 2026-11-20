import Foundation
import CoreLocation

/// Raw CoreLocation CLVisit record captured passively by the hardware coprocessor.
struct RawVisitEvent: Identifiable, Hashable, Sendable {
    let id: Int64
    let arrivalDate: Date?
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let recordedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
