import SwiftUI

// A modal sheet for building or editing a smart playlist's name, rules, and optional limit.
struct SmartPlaylistEditorSheet: View {

    // The playlist being edited, or `nil` when creating a new one.
    let existing: Playlist?

    // Called with the finished playlist when the user confirms.
    let onSave: (Playlist) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var definition: SmartPlaylistRules

    init(existing: Playlist? = nil, onSave: @escaping (Playlist) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _definition = State(initialValue: existing?.smartRules ?? SmartPlaylistRules())
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && definition.rules.contains { $0.isComplete }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "smartPlaylist.title.new" : "smartPlaylist.title.edit")
                .font(.title2)
                .bold()

            TextField("newPlaylist.namePlaceholder", text: $name)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 6) {
                Text("smartPlaylist.match")
                Picker("", selection: $definition.matchAll) {
                    Text("smartPlaylist.match.all").tag(true)
                    Text("smartPlaylist.match.any").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("smartPlaylist.matchRules")
            }

            VStack(spacing: 6) {
                ForEach($definition.rules) { $rule in
                    SmartRuleRow(rule: $rule) {
                        definition.rules.removeAll { $0.id == rule.id }
                    }
                }
                HStack {
                    Button {
                        definition.rules.append(SmartRule())
                    } label: {
                        Label("smartPlaylist.addRule", systemImage: "plus")
                    }
                    Spacer()
                }
            }

            Divider()

            HStack(spacing: 6) {
                Toggle("smartPlaylist.limitTo", isOn: $definition.limitEnabled)
                TextField("", value: $definition.limit, format: .number)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 60)
                    .disabled(!definition.limitEnabled)
                Text("smartPlaylist.songsSelectedBy")
                Picker("", selection: $definition.selection) {
                    ForEach(SmartLimitSelection.allCases) { option in
                        Text(option.localizedName).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!definition.limitEnabled)
            }

            HStack {
                Spacer()
                Button("newPlaylist.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("smartPlaylist.save") { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private func save() {
        var rules = definition
        rules.limit = max(rules.limit, 1)
        let playlist = Playlist(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            songs: [],
            smartRules: rules
        )
        onSave(playlist)
        dismiss()
    }
}

// One editable rule: field, operator, value(s), and a remove button.
private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $rule.field) {
                ForEach(SmartRuleField.allCases) { field in
                    Text(field.localizedName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            // Keep the operator valid when switching between text and numeric fields.
            .onChange(of: rule.field) { _, field in
                if !field.availableOperators.contains(rule.op) {
                    rule.op = field.availableOperators[0]
                }
            }

            Picker("", selection: $rule.op) {
                ForEach(rule.field.availableOperators) { op in
                    Text(op.localizedName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField("smartPlaylist.valuePlaceholder", text: $rule.value)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            if rule.op == .inRange {
                Text("smartPlaylist.rangeTo")
                TextField("smartPlaylist.valuePlaceholder", text: $rule.secondValue)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
