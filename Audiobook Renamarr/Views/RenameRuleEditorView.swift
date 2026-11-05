import SwiftUI

struct RenameRuleEditorView: View {
    @Binding var rule: RenameRule
    @Environment(\.dismiss) private var dismiss

    private let tokens = ["{author}", "{title}", "{subtitle}", "{series}",
                          "{seriesNumber}", "{narrator}", "{year}", "{ext}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Rule")
                .font(.title2.weight(.semibold))

            // Presets
            HStack {
                Text("Preset:")
                Picker("", selection: Binding(
                    get: { RenameRule.presets.firstIndex { $0.rule == rule } ?? -1 },
                    set: { index in
                        if index >= 0 { rule = RenameRule.presets[index].rule }
                    }
                )) {
                    Text("Custom").tag(-1)
                    ForEach(RenameRule.presets.indices, id: \.self) { i in
                        Text(RenameRule.presets[i].name).tag(i)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            // Template
            VStack(alignment: .leading, spacing: 6) {
                Text("Template — use / for folder separators")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Template", text: $rule.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                // Token chips
                HStack(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        Button(token) {
                            rule.template += rule.template.isEmpty ? token : " \(token)"
                        }
                        .font(.caption.monospaced())
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Text("{track} is not a token — the track number is injected automatically at the position below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Track options
            HStack(spacing: 20) {
                Picker("Track position:", selection: $rule.trackPosition) {
                    ForEach(RenameRule.TrackPosition.allCases) { position in
                        Text(position.rawValue).tag(position)
                    }
                }
                .frame(maxWidth: 220)

                Stepper(value: $rule.trackPadding, in: 0...4) {
                    Text("Padding: \(rule.trackPadding) digit\(rule.trackPadding == 1 ? "" : "s")")
                        .monospacedDigit()
                }
            }

            HStack(spacing: 20) {
                Toggle("Replace spaces with underscores", isOn: $rule.replaceSpacesWithUnderscores)

                Stepper(value: $rule.maxFilenameLength, in: 50...255, step: 10) {
                    Text("Max filename length: \(rule.maxFilenameLength)")
                        .monospacedDigit()
                }
            }

            Divider()

            // Live preview — sample book, track 3, so padding/position are
            // immediately visible.
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(previewText)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var previewText: String {
        let context = RenameRule.TokenContext(
            author: "Isabel Allende",
            title: "The House of the Spirits",
            subtitle: "A Novel",
            series: "Del amor y de sombra",
            seriesNumber: 1,
            narrator: "Thom Rivera",
            year: 1982,
            ext: "m4b",
            trackNumber: 3
        )
        return rule.render(context: context)
    }
}
