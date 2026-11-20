import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    private let database: LocationDatabase

    var activityTypes: [ActivityType] = []
    var savedPlaces: [SavedPlace] = []
    var googlePlacesAPIKey: String = ""
    var savedFolderName: String?

    init(database: LocationDatabase = .shared) {
        self.database = database
        reload()
    }

    func reload() {
        activityTypes = database.fetchActivityTypes()
        savedPlaces = database.fetchSavedPlaces()
        googlePlacesAPIKey = KeychainStore.loadGooglePlacesAPIKey()
        savedFolderName = ExportFolderBookmark.savedFolderName
    }

    func saveAPIKey() {
        KeychainStore.saveGooglePlacesAPIKey(googlePlacesAPIKey)
    }

    func addOrUpdateActivityType(_ item: ActivityType) {
        database.upsertActivityType(item)
        activityTypes = database.fetchActivityTypes()
    }

    func deleteActivityType(id: String) {
        guard activityTypes.count > 1 else { return }
        database.deleteActivityType(id: id)
        activityTypes = database.fetchActivityTypes()
    }

    func renameSavedPlace(_ place: SavedPlace, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = place
        updated.name = trimmed
        database.upsertSavedPlace(updated)
        savedPlaces = database.fetchSavedPlaces()
    }

    func deleteSavedPlace(id: String) {
        database.deleteSavedPlace(id: id)
        savedPlaces = database.fetchSavedPlaces()
    }

    func setExportFolder(_ url: URL) throws {
        try ExportFolderBookmark.save(folderURL: url)
        savedFolderName = ExportFolderBookmark.savedFolderName
    }

    func clearExportFolder() {
        ExportFolderBookmark.clear()
        savedFolderName = nil
    }
}
