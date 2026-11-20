import SwiftUI
import CoreLocation
import CoreMotion

/// Minimal main screen: passive tracking status + day selector + manual Review & Export triggers.
/// Does ZERO background or foreground processing until the user explicitly opens Review.
struct RootView: View {
    @State private var tracker = LocationTracker.shared
    @State private var dayVM = DayTimelineViewModel()
    @State private var settingsVM = SettingsViewModel()

    @State private var showHistory: Bool = false
    @State private var showSettings: Bool = false
    @State private var showFileExporter: Bool = false
    @State private var exportDocument: GPXFileDocument?
    @State private var exportFilename: String = ""
    @State private var shareFileURL: URL?
    @State private var showShareSheet: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // 1. Minimal Tracking Status Section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Background Tracking")
                                .font(.body.weight(.medium))
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusDotColor)
                                    .frame(width: 8, height: 8)
                                Text(tracker.state.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let lastDate = tracker.lastSampleDate {
                                    Text("· \(DateFormatting.localTime(lastDate))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { tracker.isEnabled },
                            set: { tracker.setTrackingEnabled($0) }
                        ))
                        .labelsHidden()
                    }

                    if tracker.isEnabled && tracker.authorizationStatus != .authorizedAlways {
                        permissionNotice
                    }

                    if tracker.isEnabled && tracker.motionAuthorizationStatus != .authorized && CMMotionActivityManager.isActivityAvailable() {
                        motionPermissionNotice
                    }
                }

                // 2. Local Day Switcher
                Section {
                    HStack {
                        Button {
                            dayVM.goToPreviousDay()
                        } label: {
                            Image(systemName: "chevron.left")
                                .padding(6)
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            showHistory = true
                        } label: {
                            VStack(spacing: 2) {
                                Text(dayVM.displayDateTitle)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    if dayVM.isSelectedDayToday {
                                        Text("Today (Local)")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                    if dayVM.previewUTCExportDateKey != dayVM.selectedDayKey {
                                        Text("UTC Save: \(dayVM.previewUTCExportDateKey)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text("UTC: \(dayVM.previewUTCExportDateKey)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            dayVM.goToNextDay()
                        } label: {
                            Image(systemName: "chevron.right")
                                .padding(6)
                        }
                        .buttonStyle(.borderless)
                        .disabled(dayVM.isSelectedDayToday)
                    }
                    .padding(.vertical, 2)
                }

                // 3. Day Overview & Manual Review Trigger
                Section {
                    HStack {
                        Label("Raw GPS Points", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        Text("\(dayVM.rawSampleCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if let reviewedAt = dayVM.reviewRecord?.reviewedAt {
                        HStack {
                            Label("Reviewed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(DateFormatting.localTime(reviewedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let exportedFilename = dayVM.reviewRecord?.lastExportFilename {
                        HStack {
                            Label("Last GPX Export", systemImage: "doc.text")
                            Spacer()
                            Text(exportedFilename)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        ReviewTimelineView(viewModel: dayVM)
                    } label: {
                        HStack {
                            Image(systemName: dayVM.segments.isEmpty ? "checklist" : "pencil.and.list.clipboard")
                                .foregroundStyle(.blue)
                            Text(dayVM.segments.isEmpty ? "Review Day" : "Review / Edit Timeline")
                                .fontWeight(.semibold)
                        }
                    }
                } header: {
                    Text("Day Summary")
                } footer: {
                    if dayVM.segments.isEmpty {
                        Text("Zero processing runs in the background. Tap Review Day when you're ready to detect Stationary & Move items.")
                    }
                }

                // 4. Saved Timeline Preview (if already reviewed)
                if !dayVM.segments.isEmpty {
                    Section("Saved Timeline (\(dayVM.segments.count))") {
                        ForEach(dayVM.segments) { seg in
                            HStack(spacing: 10) {
                                if seg.kind == .stationary {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.orange)
                                } else {
                                    let act = dayVM.activityType(for: seg.activityTypeID)
                                    Image(systemName: act.sfSymbol)
                                        .foregroundStyle(act.swiftUIColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(seg.kind == .stationary
                                         ? (seg.placeName ?? "Unnamed Place")
                                         : dayVM.activityType(for: seg.activityTypeID).name)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(DateFormatting.localTime(seg.startDate)) – \(DateFormatting.localTime(seg.endDate)) · \(DateFormatting.duration(seg.duration))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // 5. Manual GPX Export Actions
                if dayVM.rawSampleCount > 0 || !dayVM.segments.isEmpty {
                    Section {
                        if ExportFolderBookmark.hasSavedFolder {
                            Button {
                                _ = dayVM.exportToSavedFolder()
                            } label: {
                                Label(
                                    "Save \(dayVM.previewExportFilename) to \(ExportFolderBookmark.savedFolderName ?? "Folder")",
                                    systemImage: "folder.fill"
                                )
                            }
                        }

                        Button {
                            let pkg = dayVM.buildGPXExportPackage()
                            exportDocument = GPXFileDocument(data: pkg.data)
                            exportFilename = pkg.filename
                            showFileExporter = true
                        } label: {
                            Label("Export \(dayVM.previewExportFilename) to Files / iCloud Drive", systemImage: "icloud.and.arrow.up")
                        }

                        Button {
                            if let url = dayVM.writeTemporaryShareFile() {
                                shareFileURL = url
                                showShareSheet = true
                            }
                        } label: {
                            Label("Share GPX...", systemImage: "square.and.arrow.up")
                        }

                        if let banner = dayVM.statusBanner {
                            Text(banner)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let error = dayVM.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Export GPX (UTC)")
                    }
                }
            }
            .navigationTitle("Dailies")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "calendar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsVM.reload()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                dayVM.loadSelectedDayLight()
            }
            .sheet(isPresented: $showHistory) {
                DayHistorySheet(viewModel: dayVM) { chosenKey in
                    dayVM.selectDay(chosenKey)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    tracker: tracker,
                    settingsVM: settingsVM
                ) {
                    dayVM.reloadReferenceData()
                }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDocument,
                contentType: .gpx,
                defaultFilename: exportFilename
            ) { result in
                switch result {
                case .success:
                    let pkg = dayVM.buildGPXExportPackage()
                    dayVM.markExported(package: pkg)
                    dayVM.statusBanner = "Exported \(pkg.filename)"
                case .failure(let error):
                    dayVM.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareFileURL {
                    ActivityShareSheet(items: [shareFileURL])
                }
            }
        }
    }

    private var statusDotColor: Color {
        switch tracker.state {
        case .stopped: return .gray
        case .sleeping: return .green
        case .moving: return .blue
        }
    }

    @ViewBuilder
    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tracker.authorizationStatus == .denied || tracker.authorizationStatus == .restricted {
                Label("Location access is denied. Enable \"Always\" in iOS Settings for background tracking.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Label("Allow \"Always\" location so iOS can sleep GPS and wake only when you leave a place.", systemImage: "battery.100percent.bolt")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Grant Always Permission") {
                    tracker.requestPermissions()
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var motionPermissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if tracker.motionAuthorizationStatus == .denied || tracker.motionAuthorizationStatus == .restricted {
                Label("Motion & Fitness is off. Enable it in iOS Settings for instant low-battery departure wake.", systemImage: "figure.walk.motion")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Enable Motion & Fitness so the hardware motion chip wakes GPS instantly when you start walking or riding.", systemImage: "figure.walk.motion")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Button("Allow Motion & Fitness") {
                    tracker.requestMotionPermissionIfNeeded()
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }
}
