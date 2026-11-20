import Foundation
import CoreLocation

/// Immutable raw GPS sample appended during active movement.
/// Stored with UTC Unix timestamp (`timestamp`).
struct RawLocationSample: Identifiable, Hashable, Sendable {
    let id: Int64
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double
    let speed: Double
    let course: Double
    let source: SampleSource

    enum SampleSource: Int, Sendable {
        case activeGPS = 0
        case significantChange = 1
        case geofenceExit = 2
        case singleFix = 3
        case visitAnchor = 4
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to other: RawLocationSample) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
