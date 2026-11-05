import SwiftUI

struct RenameRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RenameRule
    let onSave: (RenameRule) -> Void

    init(rule: RenameRule, onSave: @escaping (RenameRule) -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Rule")
                .font(.title2.bold())

            // ── Preset picker ──
            Picker("Preset", selection: presetSelection) {
                Text("Custom").tag(Optional<String>.none)
                ForEach(RenameRule.presets, id: \.name) { preset in
                    Text(preset.name).tag(Optional(preset.name))
                }
            }

            // ── Template ──
            VStack(alignment: .leading, spacing: 6) {
                Text("Filename Template").font(.headline)
                Text("Track number is always added automatically — use the options below to control it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Template", text: $draft.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                FlowTokenPicker(tokens: RenameRule.availableTokens) { token in
                    draft.template += token
                }
            }

            Divider()

            // ── Track number options ──
            VStack(alignment: .leading, spacing: 10) {
                Text("Track Number").font(.headline)

                HStack(spacing: 12) {
                    Text("Position")
                    Picker("Position", selection: $draft.trackPosition) {
                        ForEach(TrackPosition.allCases, id: \.self) { pos in
                            Text(pos.rawValue).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                Stepper(
                    "Padding: \(draft.trackNumberPadding == 0 ? "none" : "\(draft.trackNumberPadding) digits  (e.g. \(paddingExample))")",
                    value: $draft.trackNumberPadding,
                    in: 0...4
                )
            }

            Divider()

            Toggle("Replace spaces with underscores", isOn: $draft.replaceSpacesWithUnderscore)
                .toggleStyle(.checkbox)

            // ── Live preview ──
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview").font(.headline)
                Text(previewFilename)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
    }

    // MARK: - Helpers

    private var paddingExample: String {
        String(format: "%0\(draft.trackNumberPadding)d", 3)
    }

    private var presetSelection: Binding<String?> {
        Binding(
            get: { RenameRule.presets.first { $0.rule.template == draft.template }?.name },
            set: { name in
                if let name, let preset = RenameRule.presets.first(where: { $0.name == name }) {
                    draft.template = preset.rule.template
                }
            }
        )
    }

    private var previewFilename: String {
        let sampleMatch = AudibleMatch(
            asin: "B000000000",
            title: "The Legend of Uh",
            authors: ["Aaron N. Hall"],
            narrators: ["Aaron N. Hall"],
            seriesTitle: "The Legend of Uh",
            seriesSequence: "1",
            releaseYear: "2023"
        )
        var item = AudioFileItem(
            originalURL: URL(fileURLWithPath: "/tmp/The_Legend_of_Uh_3.m4b")
        )
        item.selectedMatch = sampleMatch
        item.parsed = ParsedFilename(
            titleGuess: "The Legend of Uh",
            authorGuess: "Aaron N. Hall",
            trackNumber: 3
        )
        return RenameEngine.proposedFilename(for: item, rule: draft) ?? "—"
    }
}

// MARK: - Token button grid

private struct FlowTokenPicker: View {
    let tokens: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 6) {
            ForEach(tokens, id: \.self) { token in
                Button(token) { onTap(token) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

#Preview {
    RenameRuleEditorView(rule: RenameRule()) { _ in }
}
