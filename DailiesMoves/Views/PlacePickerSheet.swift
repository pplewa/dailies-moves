import SwiftUI
import CoreLocation

/// Place selector for Stationary segments:
/// 1. Previously visited places (instant offline proximity match)
/// 2. Google Places API (New) nearby & text search (on-demand only)
/// 3. Custom place name (remembered locally for future visits)
struct PlacePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let coordinate: CLLocationCoordinate2D?
    let currentName: String?
    let savedPlaces: [SavedPlace]
    let onSelect: (_ name: String, _ googlePlaceID: String?, _ address: String?, _ coordinate: CLLocationCoordinate2D?, _ existingPlaceID: String?) -> Void

    @State private var customName: String = ""
    @State private var searchQuery: String = ""
    @State private var googleResults: [PlaceMatchingService.GooglePlaceCandidate] = []
    @State private var isLoadingGoogle: Bool = false
    @State private var googleError: String?

    private var apiKey: String {
        KeychainStore.loadGooglePlacesAPIKey()
    }

    private var nearbySavedPlaces: [PlaceMatchingService.SavedPlaceSuggestion] {
        guard let coordinate else {
            return savedPlaces.prefix(10).map {
                PlaceMatchingService.SavedPlaceSuggestion(place: $0, distanceMeters: 0)
            }
        }
        return PlaceMatchingService.suggestSavedPlaces(near: coordinate, from: savedPlaces, maxDistanceMeters: 1000)
    }

    private var otherSavedPlaces: [SavedPlace] {
        let nearbyIDs = Set(nearbySavedPlaces.map(\.id))
        let filtered = savedPlaces.filter { !nearbyIDs.contains($0.id) }
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array(filtered.prefix(8))
        }
        return filtered.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Custom Name Section
                Section("Custom Place Name") {
                    HStack {
                        TextField("e.g. Home, Office, Gym...", text: $customName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit(confirmCustomName)

                        Button("Save") {
                            confirmCustomName()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // Previously Visited Nearby
                if !nearbySavedPlaces.isEmpty {
                    Section("Previously Visited Nearby") {
                        ForEach(nearbySavedPlaces) { suggestion in
                            Button {
                                onSelect(
                                    suggestion.place.name,
                                    suggestion.place.googlePlaceID,
                                    suggestion.place.address,
                                    suggestion.place.coordinate,
                                    suggestion.place.id
                                )
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.place.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if let addr = suggestion.place.address, !addr.isEmpty {
                                            Text(addr)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if coordinate != nil {
                                            Text(DateFormatting.distance(suggestion.distanceMeters))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("\(suggestion.place.visitCount)×")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                // Google Places API (New)
                Section {
                    if apiKey.isEmpty {
                        Label(
                            "Add your Google Places API key in Settings to search Google Places.",
                            systemImage: "key.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("Search Google Places...", text: $searchQuery)
                                .submitLabel(.search)
                                .onSubmit {
                                    Task { await performGoogleSearch() }
                                }
                            Button {
                                Task { await performGoogleSearch() }
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .disabled(isLoadingGoogle)
                        }

                        if isLoadingGoogle {
                            HStack {
                                ProgressView()
                                Text("Searching Google Places...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let googleError {
                            Text(googleError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        ForEach(googleResults) { candidate in
                            Button {
                                onSelect(
                                    candidate.name,
                                    candidate.id,
                                    candidate.address,
                                    CLLocationCoordinate2D(latitude: candidate.latitude, longitude: candidate.longitude),
                                    nil
                                )
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .foregroundStyle(.primary)
                                        if let subtitle = candidate.address ?? candidate.category {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(DateFormatting.distance(candidate.distanceMeters))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !isLoadingGoogle && googleResults.isEmpty && googleError == nil && coordinate != nil {
                            Button("Load Nearby Google Places") {
                                Task { await loadNearbyGooglePlaces() }
                            }
                        }
                    }
                } header: {
                    Text("Google Places")
                }

                // Other Remembered Places
                if !otherSavedPlaces.isEmpty {
                    Section("Other Saved Places") {
                        ForEach(otherSavedPlaces) { place in
                            Button {
                                onSelect(place.name, place.googlePlaceID, place.address, coordinate ?? place.coordinate, place.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(place.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(place.visitCount) visits")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                customName = currentName ?? ""
            }
            .task {
                if !apiKey.isEmpty && coordinate != nil {
                    await loadNearbyGooglePlaces()
                }
            }
        }
    }

    private func confirmCustomName() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSelect(trimmed, nil, nil, coordinate, nil)
        dismiss()
    }

    private func loadNearbyGooglePlaces() async {
        guard let coordinate else { return }
        isLoadingGoogle = true
        googleError = nil
        do {
            googleResults = try await PlaceMatchingService.searchNearby(
                coordinate: coordinate,
                radiusMeters: 150,
                apiKey: apiKey
            )
        } catch {
            googleError = error.localizedDescription
        }
        isLoadingGoogle = false
    }

    private func performGoogleSearch() async {
        guard let coordinate else { return }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            await loadNearbyGooglePlaces()
            return
        }
        isLoadingGoogle = true
        googleError = nil
        do {
            googleResults = try await PlaceMatchingService.searchText(
                query: q,
                near: coordinate,
                apiKey: apiKey
            )
        } catch {
            googleError = error.localizedDescription
        }
        isLoadingGoogle = false
    }
}
