import SwiftUI

/// Manage custom editable Move activity types (Walking, Car, Biking, etc.).
struct ActivityTypesView: View {
    @Bindable var settingsVM: SettingsViewModel

    @State private var editingType: ActivityType?
    @State private var isCreatingNew: Bool = false

    var body: some View {
        List {
            Section {
                ForEach(settingsVM.activityTypes) { item in
                    Button {
                        editingType = item
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(item.swiftUIColor.opacity(0.18))
                                    .frame(width: 32, height: 32)
                                Image(systemName: item.sfSymbol)
                                    .foregroundStyle(item.swiftUIColor)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Text("GPX <type>: \(item.gpxType)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    for idx in offsets {
                        let item = settingsVM.activityTypes[idx]
                        settingsVM.deleteActivityType(id: item.id)
                    }
                }
            } footer: {
                Text("Custom move types appear in Review mode and are exported as the GPX <type> field.")
            }
        }
        .navigationTitle("Move Types")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingType) { item in
            ActivityTypeEditorSheet(existing: item) { saved in
                settingsVM.addOrUpdateActivityType(saved)
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            ActivityTypeEditorSheet(
                existing: ActivityType(
                    id: UUID().uuidString,
                    name: "",
                    sfSymbol: "figure.walk",
                    colorHex: "#007AFF",
                    sortOrder: settingsVM.activityTypes.count
                )
            ) { saved in
                settingsVM.addOrUpdateActivityType(saved)
            }
        }
    }
}

private struct ActivityTypeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: ActivityType
    let onSave: (ActivityType) -> Void

    init(existing: ActivityType, onSave: @escaping (ActivityType) -> Void) {
        _draft = State(initialValue: existing)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Scooter, Ferry, Hike", text: $draft.name)
                        .textInputAutocapitalization(.words)
                }

                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 38))], spacing: 10) {
                        ForEach(ActivityType.paletteHexes, id: \.self) { hex in
                            let color = Color(hex: hex) ?? .blue
                            Button {
                                draft.colorHex = hex
                            } label: {
                                Circle()
                                    .fill(color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if draft.colorHex == hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 42))], spacing: 10) {
                        ForEach(ActivityType.suggestedSymbols, id: \.self) { symbol in
                            let isSelected = draft.sfSymbol == symbol
                            Button {
                                draft.sfSymbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isSelected ? draft.swiftUIColor.opacity(0.22) : Color(.secondarySystemFill))
                                    )
                                    .foregroundStyle(isSelected ? draft.swiftUIColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(draft.name.isEmpty ? "New Move Type" : "Edit Move Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var trimmed = draft
                        trimmed.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.name.isEmpty else { return }
                        onSave(trimmed)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
