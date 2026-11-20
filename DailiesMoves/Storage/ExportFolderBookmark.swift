import Foundation

/// Persists a security-scoped bookmark for a user-selected iCloud Drive / Files folder,
/// enabling 1-tap GPX export without paid iCloud container entitlements.
enum ExportFolderBookmark {
    private static let bookmarkKey = "dailies.exportFolder.bookmark"
    private static let folderNameKey = "dailies.exportFolder.name"

    static var savedFolderName: String? {
        UserDefaults.standard.string(forKey: folderNameKey)
    }

    static var hasSavedFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func save(folderURL: URL) throws {
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { folderURL.stopAccessingSecurityScopedResource() }
        }
        let data = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(folderURL.lastPathComponent, forKey: folderNameKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
    }

    /// Writes `content` to `filename` inside the remembered iCloud Drive / Files folder.
    static func writeToSavedFolder(filename: String, content: Data) throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw ExportError.noSavedFolder
        }
        var isStale = false
        let folderURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { folderURL.stopAccessingSecurityScopedResource() }
        }
        if isStale {
            let refreshed = try folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
        }
        let destinationURL = folderURL.appendingPathComponent(filename)
        try content.write(to: destinationURL, options: [.atomic])
        return destinationURL
    }

    enum ExportError: LocalizedError {
        case noSavedFolder

        var errorDescription: String? {
            switch self {
            case .noSavedFolder:
                return "No default export folder selected yet."
            }
        }
    }
}
