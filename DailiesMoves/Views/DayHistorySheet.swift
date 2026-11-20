import SwiftUI

/// Browse, review, edit, or re-export any previous tracked day.
struct DayHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: DayTimelineViewModel
    let onSelectDay: (String) -> Void

    @State private var pickedDate: Date = Date()

    var body: some View {
        NavigationStack {
            List {
                Section("Jump to Date") {
                    DatePicker(
                        "Local Date",
                        selection: $pickedDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    Button("Open Selected Date") {
                        let key = DateFormatting.localDayKey(for: pickedDate)
                        onSelectDay(key)
                        dismiss()
                    }
                }

                Section("Tracked & Reviewed Days") {
                    if viewModel.trackedDays.isEmpty {
                        Text("No days recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.trackedDays) { day in
                            Button {
                                onSelectDay(day.localDayKey)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(DateFormatting.localDisplayDate(forDayKey: day.localDayKey))
                                            .font(.body.weight(day.localDayKey == viewModel.selectedDayKey ? .semibold : .regular))
                                            .foregroundStyle(.primary)

                                        HStack(spacing: 8) {
                                            Text("\(day.rawSampleCount) raw pts")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if day.segmentCount > 0 {
                                                Text("· \(day.segmentCount) items")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let filename = day.reviewRecord?.lastExportFilename {
                                                Text("· \(filename)")
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if day.isReviewed {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else if day.rawSampleCount > 0 {
                                        Text("Unreviewed")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Previous Days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                viewModel.reloadReferenceData()
                if let d = DateFormatting.date(fromDayKey: viewModel.selectedDayKey) {
                    pickedDate = d
                }
            }
        }
    }
}
