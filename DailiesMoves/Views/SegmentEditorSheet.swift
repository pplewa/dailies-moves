import SwiftUI

/// Detailed editor for any timeline segment:
/// switch Stationary <-> Move, pick custom Move type or Place, adjust start/end times, merge, split, delete.
struct SegmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: DayTimelineViewModel
    let segmentIndex: Int

    @State private var draft: TimelineSegment
    @State private var snapAdjacent: Bool = true
    @State private var splitDate: Date
    @State private var showPlacePicker: Bool = false
    @State private var showManageActivities: Bool = false

    init(viewModel: DayTimelineViewModel, segment: TimelineSegment, segmentIndex: Int) {
        self.viewModel = viewModel
        self.segmentIndex = segmentIndex
        _draft = State(initialValue: segment)
        let midpoint = segment.startDate.addingTimeInterval(segment.duration / 2)
        _splitDate = State(initialValue: midpoint)
    }

    private var canMergePrevious: Bool { segmentIndex > 0 }
    private var canMergeNext: Bool { segmentIndex + 1 < viewModel.segments.count }
    private var canSplit: Bool { draft.duration >= 60 }

    var body: some View {
        NavigationStack {
            Form {
                // Segment Kind
                Section("Type") {
                    Picker("Segment Kind", selection: $draft.kind) {
                        Text("Stationary").tag(TimelineSegment.Kind.stationary)
                        Text("Move").tag(TimelineSegment.Kind.move)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.kind) { _, newKind in
                        if newKind == .move && draft.activityTypeID == nil {
                            draft.activityTypeID = viewModel.activityTypes.first?.id ?? "walking"
                        }
                    }
                }

                // Stationary Place Picker OR Move Activity Type
                if draft.kind == .stationary {
                    Section("Place") {
                        Button {
                            showPlacePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.orange)
                                Text(draft.placeName ?? "Choose or Name Place...")
                                    .foregroundStyle(draft.placeName == nil ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if let lat = draft.latitude, let lon = draft.longitude {
                            Text(String(format: "%.5f, %.5f", lat, lon))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(viewModel.activityTypes) { activity in
                                let isSelected = draft.activityTypeID == activity.id
                                Button {
                                    draft.activityTypeID = activity.id
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: activity.sfSymbol)
                                            .font(.subheadline)
                                        Text(activity.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isSelected ? activity.swiftUIColor : Color(.secondarySystemFill))
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)

                        Button("Edit Custom Move Types...") {
                            showManageActivities = true
                        }
                        .font(.footnote)
                    } header: {
                        Text("Move Activity")
                    }
                }

                // Start / End Dates (Local display, UTC saved)
                Section {
                    DatePicker("Start (Local)", selection: $draft.startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End (Local)", selection: $draft.endDate, in: draft.startDate..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("Snap adjacent segments", isOn: $snapAdjacent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved UTC window:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(DateFormatting.iso8601UTC(draft.startDate)) → \(DateFormatting.iso8601UTC(draft.endDate))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Time Range (\(DateFormatting.duration(draft.duration)))")
                }

                // Merge & Split Actions
                Section("Merge & Split") {
                    if canMergePrevious {
                        Button {
                            viewModel.updateSegment(draft, snapAdjacent: snapAdjacent)
                            viewModel.mergeWithPrevious(segmentID: draft.id)
                            dismiss()
                        } label: {
                            Label("Merge with Previous", systemImage: "arrow.up.to.line.compact")
                        }
                    }

                    if canMergeNext {
                        Button {
                            viewModel.updateSegment(draft, snapAdjacent: snapAdjacent)
                            viewModel.mergeWithNext(segmentID: draft.id)
                            dismiss()
                        } label: {
                            Label("Merge with Next", systemImage: "arrow.down.to.line.compact")
                        }
                    }

                    if canSplit {
                        DatePicker(
                            "Split At",
                            selection: $splitDate,
                            in: draft.startDate.addingTimeInterval(15)...draft.endDate.addingTimeInterval(-15),
                            displayedComponents: [.hourAndMinute]
                        )
                        Button {
                            viewModel.updateSegment(draft, snapAdjacent: snapAdjacent)
                            viewModel.splitSegment(segmentID: draft.id, at: splitDate)
                            dismiss()
                        } label: {
                            Label("Split Segment Here", systemImage: "scissors")
                        }
                    }
                }

                // Delete
                Section {
                    Button(role: .destructive) {
                        viewModel.deleteSegment(segmentID: draft.id)
                        dismiss()
                    } label: {
                        Label("Delete Segment", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(draft.kind == .stationary ? "Edit Stationary" : "Edit Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        viewModel.updateSegment(draft, snapAdjacent: snapAdjacent)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showPlacePicker) {
                PlacePickerSheet(
                    coordinate: draft.coordinate,
                    currentName: draft.placeName,
                    savedPlaces: viewModel.savedPlaces
                ) { name, googleID, address, coord, existingPlaceID in
                    viewModel.assignPlace(
                        toSegmentID: draft.id,
                        name: name,
                        googlePlaceID: googleID,
                        address: address,
                        coordinate: coord,
                        existingPlaceID: existingPlaceID
                    )
                    if let updated = viewModel.segments.first(where: { $0.id == draft.id }) {
                        draft = updated
                    }
                }
            }
            .sheet(isPresented: $showManageActivities, onDismiss: {
                viewModel.reloadReferenceData()
            }) {
                NavigationStack {
                    ActivityTypesView(settingsVM: SettingsViewModel())
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showManageActivities = false }
                            }
                        }
                }
            }
        }
    }
}
