import SwiftUI
import UniformTypeIdentifiers

/// Minimal Settings: Battery profile, Google Places API Key, iCloud Drive / Files export folder,
/// Custom Move Types, and Saved Places.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var tracker: LocationTracker
    @Bindable var settingsVM: SettingsViewModel
    let onDismissChanges: () -> Void

    @State private var showFolderPicker: Bool = false
    @State private var folderError: String?
    @State private var showSavedKeyToast: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // Battery / Tracking Profile
                Section {
                    Picker("Power Profile", selection: $tracker.powerProfile) {
                        ForEach(LocationTracker.PowerProfile.allCases) { profile in
                            VStack(alignment: .leading) {
                                Text(profile.title)
                                Text(profile.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(profile)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Battery & Tracking")
                } footer: {
                    Text("GPS stays completely off while stationary (relying on hardware geofence & Visits). No processing runs until you manually open Review.")
                }

                // Export Destination (iCloud Drive / Files folder bookmark)
                Section {
                    if let folder = settingsVM.savedFolderName {
                        HStack {
                            Label(folder, systemImage: "folder.fill")
                            Spacer()
                            Button("Change") {
                                showFolderPicker = true
                            }
                            .font(.subheadline)
                        }
                        Button("Clear Default Folder", role: .destructive) {
                            settingsVM.clearExportFolder()
                        }
                    } else {
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("Choose iCloud Drive / Files Folder...", systemImage: "icloud.and.arrow.up")
                        }
                    }
                    if let folderError {
                        Text(folderError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("GPX Export Folder")
                } footer: {
                    Text("Pick any folder in iCloud Drive or On My iPhone once for 1-tap GPX exports. You can also export via Files or the iOS Share Sheet anytime.")
                }

                // Google Places API Key
                Section {
                    SecureField("Google Places API Key", text: $settingsVM.googlePlacesAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        Button("Save Key") {
                            settingsVM.saveAPIKey()
                            showSavedKeyToast = true
                        }
                        if showSavedKeyToast {
                            Spacer()
                            Text("Saved in Keychain")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Google Places API (New)")
                } footer: {
                    Text("Stored securely in iOS Keychain. Only called on demand when you pick a place in Review mode — never in the background.")
                }

                // Customization
                Section("Timeline") {
                    NavigationLink {
                        ActivityTypesView(settingsVM: settingsVM)
                    } label: {
                        HStack {
                            Label("Custom Move Types", systemImage: "figure.walk")
                            Spacer()
                            Text("\(settingsVM.activityTypes.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        SavedPlacesView(settingsVM: settingsVM)
                    } label: {
                        HStack {
                            Label("Saved Places", systemImage: "mappin.and.ellipse")
                            Spacer()
                            Text("\(settingsVM.savedPlaces.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        settingsVM.saveAPIKey()
                        onDismissChanges()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        do {
                            try settingsVM.setExportFolder(url)
                            folderError = nil
                        } catch {
                            folderError = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    folderError = error.localizedDescription
                }
            }
        }
    }
}
