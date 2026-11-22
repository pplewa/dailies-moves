import SwiftUI

/// Manual Review screen: runs segmentation on demand, displays a compact map + editable timeline,
/// and provides Save + GPX export (iCloud Drive / Files + iOS Share Sheet).
struct ReviewTimelineView: View {
    @Bindable var viewModel: DayTimelineViewModel

    private enum ActiveSheet: Identifiable {
        case edit(TimelineSegment)
        case split(TimelineSegment)
        case place(TimelineSegment)
        case share(URL)

        var id: String {
            switch self {
            case .edit(let seg): return "edit-\(seg.id)"
            case .split(let seg): return "split-\(seg.id)"
            case .place(let seg): return "place-\(seg.id)"
            case .share(let url): return "share-\(url.lastPathComponent)"
            }
        }
    }

    @State private var selectedSegmentID: String?
    @State private var activeSheet: ActiveSheet?
    @State private var showFileExporter: Bool = false
    @State private var exportDocument: GPXFileDocument?
    @State private var exportFilename: String = ""
    @State private var showRedetectConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact Map Preview
            TimelineMapView(
                segments: viewModel.segments,
                rawSamples: viewModel.rawSamples,
                activityTypes: viewModel.activityTypes,
                selectedSegmentID: selectedSegmentID
            )
            .frame(height: 220)
            .overlay(alignment: .bottomTrailing) {
                if selectedSegmentID != nil {
                    Button {
                        selectedSegmentID = nil
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding(10)
                }
            }

            // Status / UTC Info Strip
            HStack {
                Text("\(viewModel.segments.count) items · \(viewModel.rawSampleCount) raw pts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Export UTC: \(viewModel.previewExportFilename)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            if viewModel.hasNewerRawDataThanSavedReview {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.orange)
                    Text("New locations recorded since last save")
                        .font(.caption)
                    Spacer()
                    Button("Re-detect") {
                        Task { await viewModel.redetectFromRawData() }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
            }

            if let banner = viewModel.statusBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(banner)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }

            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }

            // Timeline List
            if viewModel.isProcessingReview {
                Spacer()
                ProgressView("Analyzing raw samples...")
                Spacer()
            } else if viewModel.segments.isEmpty {
                ContentUnavailableView(
                    "No Locations Recorded",
                    systemImage: "location.slash",
                    description: Text("No raw GPS samples or visits were recorded on \(viewModel.displayDateTitle). You can add a manual entry from the menu.")
                )
            } else {
                List {
                    ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                        segmentRow(segment: segment, index: index)
                            .listRowBackground(
                                selectedSegmentID == segment.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color(.systemBackground)
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    viewModel.deleteSegment(segmentID: segment.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if index + 1 < viewModel.segments.count {
                                    Button {
                                        viewModel.mergeWithNext(segmentID: segment.id)
                                    } label: {
                                        Label("Merge Down", systemImage: "arrow.down.to.line.compact")
                                    }
                                    .tint(.indigo)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if index > 0 {
                                    Button {
                                        viewModel.mergeWithPrevious(segmentID: segment.id)
                                    } label: {
                                        Label("Merge Up", systemImage: "arrow.up.to.line.compact")
                                    }
                                    .tint(.indigo)
                                }
                                if segment.duration >= 60 {
                                    Button {
                                        activeSheet = .split(segment)
                                    } label: {
                                        Label("Split", systemImage: "scissors")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(viewModel.displayDateTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Save") {
                    viewModel.saveReviewedDay()
                }
                .fontWeight(viewModel.hasUnsavedChanges ? .semibold : .regular)

                Menu {
                    if ExportFolderBookmark.hasSavedFolder {
                        Button {
                            _ = viewModel.exportToSavedFolder()
                        } label: {
                            Label(
                                "Save to \(ExportFolderBookmark.savedFolderName ?? "Folder")",
                                systemImage: "folder.fill"
                            )
                        }
                    }

                    Button {
                        if viewModel.hasUnsavedChanges {
                            viewModel.saveReviewedDay()
                        }
                        let pkg = viewModel.buildGPXExportPackage()
                        exportDocument = GPXFileDocument(data: pkg.data)
                        exportFilename = pkg.filename
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            showFileExporter = true
                        }
                    } label: {
                        Label("Save to Files / iCloud Drive...", systemImage: "icloud.and.arrow.up")
                    }

                    Button {
                        if let url = viewModel.writeTemporaryShareFile() {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                activeSheet = .share(url)
                            }
                        }
                    } label: {
                        Label("Share GPX...", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    Button {
                        viewModel.addManualSegment(kind: .stationary)
                    } label: {
                        Label("Add Stationary Place", systemImage: "mappin.circle")
                    }
                    Button {
                        viewModel.addManualSegment(kind: .move)
                    } label: {
                        Label("Add Move", systemImage: "figure.walk")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showRedetectConfirm = true
                    } label: {
                        Label("Re-detect from Raw Data", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await viewModel.enterReviewMode()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .edit(let seg):
                if let idx = viewModel.segments.firstIndex(where: { $0.id == seg.id }) {
                    SegmentEditorSheet(viewModel: viewModel, segment: seg, segmentIndex: idx)
                }
            case .split(let seg):
                SplitSegmentSheet(viewModel: viewModel, segment: seg)
            case .place(let seg):
                PlacePickerSheet(
                    coordinate: seg.coordinate,
                    currentName: seg.placeName,
                    savedPlaces: viewModel.savedPlaces
                ) { name, googleID, address, coord, existingPlaceID in
                    viewModel.assignPlace(
                        toSegmentID: seg.id,
                        name: name,
                        googlePlaceID: googleID,
                        address: address,
                        coordinate: coord,
                        existingPlaceID: existingPlaceID
                    )
                }
            case .share(let url):
                ActivityShareSheet(items: [url])
            }
        }
        .background(
            Color.clear
                .fileExporter(
                    isPresented: $showFileExporter,
                    document: exportDocument,
                    contentType: .gpx,
                    defaultFilename: exportFilename
                ) { result in
                    switch result {
                    case .success:
                        let pkg = viewModel.buildGPXExportPackage()
                        viewModel.markExported(package: pkg)
                        viewModel.statusBanner = "Exported \(pkg.filename)"
                    case .failure(let error):
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
        )
        .alert(
            "Re-detect timeline from raw samples?",
            isPresented: $showRedetectConfirm
        ) {
            Button("Re-detect", role: .destructive) {
                Task { await viewModel.redetectFromRawData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces current edits for \(viewModel.displayDateTitle) with freshly detected Stationary and Move items.")
        }
    }

    @ViewBuilder
    private func segmentRow(segment: TimelineSegment, index: Int) -> some View {
        HStack(spacing: 12) {
            // Left Icon Badge
            if segment.kind == .stationary {
                Button {
                    activeSheet = .place(segment)
                } label: {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundStyle(segment.placeName == nil ? .orange : .green)
                }
                .buttonStyle(.plain)
            } else {
                let activity = viewModel.activityType(for: segment.activityTypeID)
                Menu {
                    ForEach(viewModel.activityTypes) { option in
                        Button {
                            var updated = segment
                            updated.activityTypeID = option.id
                            viewModel.updateSegment(updated, snapAdjacent: false)
                        } label: {
                            Label(option.name, systemImage: option.sfSymbol)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(activity.swiftUIColor.opacity(0.16))
                            .frame(width: 34, height: 34)
                        Image(systemName: activity.sfSymbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(activity.swiftUIColor)
                    }
                }
            }

            // Center Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if segment.kind == .stationary {
                        Text(segment.placeName ?? "Unnamed Place")
                            .font(.body.weight(.medium))
                            .foregroundStyle(segment.placeName == nil ? .orange : .primary)
                    } else {
                        Text(viewModel.activityType(for: segment.activityTypeID).name)
                            .font(.body.weight(.medium))
                    }

                    if !segment.isConfirmed {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                    }
                }

                HStack(spacing: 6) {
                    Text("\(DateFormatting.localTime(segment.startDate)) – \(DateFormatting.localTime(segment.endDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(DateFormatting.duration(segment.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if segment.kind == .move {
                        let dist = viewModel.distanceMeters(for: segment)
                        if dist >= 10 {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(DateFormatting.distance(dist))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Quick Place Picker, Split on Map, or Edit button
            if segment.kind == .stationary && segment.placeName == nil {
                Button("Name") {
                    activeSheet = .place(segment)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else if segment.duration >= 60 {
                Button {
                    activeSheet = .split(segment)
                } label: {
                    Image(systemName: "scissors")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }

            Button {
                activeSheet = .edit(segment)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSegmentID = (selectedSegmentID == segment.id) ? nil : segment.id
        }
    }
}

/// UIKit share sheet wrapper for clean `.gpx` file sharing.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
