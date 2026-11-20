import Foundation
import CoreLocation

/// Place suggestions & on-demand Google Places API (New) lookup.
/// NEVER called in the background — only triggered interactively when editing a stationary place.
enum PlaceMatchingService {
    struct GooglePlaceCandidate: Identifiable, Hashable, Sendable {
        let id: String              // Google Place ID
        let name: String
        let address: String?
        let category: String?
        let latitude: Double
        let longitude: Double
        let distanceMeters: Double
    }

    struct SavedPlaceSuggestion: Identifiable, Hashable, Sendable {
        var id: String { place.id }
        let place: SavedPlace
        let distanceMeters: Double
    }

    enum PlacesError: LocalizedError {
        case missingAPIKey
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Google Places API key in Settings to search Google Places."
            case .httpError(let code, let message):
                return "Google Places error (\(code)): \(message)"
            case .invalidResponse:
                return "Unexpected response from Google Places API."
            }
        }
    }

    /// Returns previously visited places sorted by distance from `coordinate` (within `maxDistanceMeters`).
    static func suggestSavedPlaces(
        near coordinate: CLLocationCoordinate2D,
        from savedPlaces: [SavedPlace],
        maxDistanceMeters: Double = 500
    ) -> [SavedPlaceSuggestion] {
        savedPlaces
            .map { SavedPlaceSuggestion(place: $0, distanceMeters: $0.distance(to: coordinate)) }
            .filter { $0.distanceMeters <= maxDistanceMeters }
            .sorted { lhs, rhs in
                if abs(lhs.distanceMeters - rhs.distanceMeters) < 25 {
                    return lhs.place.visitCount > rhs.place.visitCount
                }
                return lhs.distanceMeters < rhs.distanceMeters
            }
    }

    /// Google Places API (New): `places:searchNearby` with minimal Essentials field mask.
    static func searchNearby(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = 150,
        apiKey: String
    ) async throws -> [GooglePlaceCandidate] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PlacesError.missingAPIKey }

        let url = URL(string: "https://places.googleapis.com/v1/places:searchNearby")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.id,places.displayName,places.formattedAddress,places.location,places.primaryTypeDisplayName",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        let body: [String: Any] = [
            "maxResultCount": 12,
            "rankPreference": "DISTANCE",
            "locationRestriction": [
                "circle": [
                    "center": [
                        "latitude": coordinate.latitude,
                        "longitude": coordinate.longitude
                    ],
                    "radius": radiusMeters
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await executeGooglePlacesRequest(request, reference: coordinate)
    }

    /// Google Places API (New): `places:searchText` biased around the stationary coordinate.
    static func searchText(
        query: String,
        near coordinate: CLLocationCoordinate2D,
        apiKey: String
    ) async throws -> [GooglePlaceCandidate] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PlacesError.missingAPIKey }

        let url = URL(string: "https://places.googleapis.com/v1/places:searchText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.id,places.displayName,places.formattedAddress,places.location,places.primaryTypeDisplayName",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        let body: [String: Any] = [
            "textQuery": query,
            "maxResultCount": 12,
            "locationBias": [
                "circle": [
                    "center": [
                        "latitude": coordinate.latitude,
                        "longitude": coordinate.longitude
                    ],
                    "radius": 2000.0
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await executeGooglePlacesRequest(request, reference: coordinate)
    }

    private static func executeGooglePlacesRequest(
        _ request: URLRequest,
        reference: CLLocationCoordinate2D
    ) async throws -> [GooglePlaceCandidate] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlacesError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = parseGoogleErrorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw PlacesError.httpError(http.statusCode, msg)
        }

        let decoded = try JSONDecoder().decode(GooglePlacesResponse.self, from: data)
        let refLoc = CLLocation(latitude: reference.latitude, longitude: reference.longitude)

        return (decoded.places ?? []).compactMap { item in
            guard let name = item.displayName?.text,
                  let lat = item.location?.latitude,
                  let lon = item.location?.longitude else {
                return nil
            }
            let dist = refLoc.distance(from: CLLocation(latitude: lat, longitude: lon))
            return GooglePlaceCandidate(
                id: item.id ?? UUID().uuidString,
                name: name,
                address: item.formattedAddress,
                category: item.primaryTypeDisplayName?.text,
                latitude: lat,
                longitude: lon,
                distanceMeters: dist
            )
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private static func parseGoogleErrorMessage(_ data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error?.message
    }

    private struct GooglePlacesResponse: Decodable {
        struct PlaceItem: Decodable {
            struct LocalizedText: Decodable { let text: String? }
            struct LatLng: Decodable { let latitude: Double?; let longitude: Double? }

            let id: String?
            let displayName: LocalizedText?
            let formattedAddress: String?
            let primaryTypeDisplayName: LocalizedText?
            let location: LatLng?
        }

        let places: [PlaceItem]?
    }
}
