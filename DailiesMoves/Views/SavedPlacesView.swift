import SwiftUI

/// Manage remembered visited places (rename or remove).
struct SavedPlacesView: View {
    @Bindable var settingsVM: SettingsViewModel

    @State private var renamingPlace: SavedPlace?
    @State private var renameText: String = ""

    var body: some View {
        List {
            if settingsVM.savedPlaces.isEmpty {
                ContentUnavailableView(
                    "No Saved Places Yet",
                    systemImage: "mappin.slash",
                    description: Text("Places you name or pick from Google Places during Review are remembered automatically.")
                )
            } else {
                ForEach(settingsVM.savedPlaces) { place in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name)
                                .font(.body)
                            if let addr = place.address, !addr.isEmpty {
                                Text(addr)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(String(format: "%.5f, %.5f · %d visits", place.latitude, place.longitude, place.visitCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Rename") {
                            renamingPlace = place
                            renameText = place.name
                        }
                        .font(.caption)
                    }
                }
                .onDelete { offsets in
                    for idx in offsets {
                        settingsVM.deleteSavedPlace(id: settingsVM.savedPlaces[idx].id)
                    }
                }
            }
        }
        .navigationTitle("Saved Places")
        .alert("Rename Place", isPresented: Binding(
            get: { renamingPlace != nil },
            set: { if !$0 { renamingPlace = nil } }
        )) {
            TextField("Place name", text: $renameText)
            Button("Save") {
                if let place = renamingPlace {
                    settingsVM.renameSavedPlace(place, newName: renameText)
                }
                renamingPlace = nil
            }
            Button("Cancel", role: .cancel) {
                renamingPlace = nil
            }
        }
    }
}
