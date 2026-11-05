import SwiftUI

struct FileRowView: View {
    let item: AudioFileItem
    let candidates: [AudibleMatch]
    let onToggleInclude: (Bool) -> Void
    let onSelectMatch: (AudibleMatch) -> Void
    let onApplyToFolder: (AudibleMatch) -> Void
    let onRemove: () -> Void
    let canRemove: Bool

    @State private var showAlternates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Toggle("", isOn: Binding(get: { item.includeInBatch }, set: onToggleInclude))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 24)
                    .disabled(item.selectedMatch == nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.originalFilename)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let result = item.renameResult {
                        Text(resultDescription(result))
                            .font(.caption2)
                            .foregroundStyle(resultColor(result))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.proposedFilename ?? "—")
                        .font(.callout)
                        .foregroundStyle(item.proposedFilename == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if candidates.count > 1 {
                        Button(showAlternates ? "Hide alternates" : "Show \(candidates.count - 1) alternate(s)") {
                            showAlternates.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusBadge
                    .frame(width: 120, alignment: .leading)

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .disabled(!canRemove)
                .help("Remove from list (the file itself is not touched)")
            }

            // ── Alternates picker ──
            if showAlternates {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { candidate in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                onSelectMatch(candidate)
                                showAlternates = false
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: candidate.asin == item.selectedMatch?.asin
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(candidate.asin == item.selectedMatch?.asin ? .green : .secondary)
                                    Text("\(candidate.title) — \(candidate.authors.joined(separator: ", "))")
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Apply to entire folder button
                            Button {
                                onApplyToFolder(candidate)
                                showAlternates = false
                            } label: {
                                Label("Apply to folder", systemImage: "folder.badge.checkmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Apply this match to every file in the same folder")
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.vertical, 4)
                .padding(.trailing, 8)
            }

            if case .error(let message) = item.status {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending:
            Label("Pending", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .searching:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            }
            .foregroundStyle(.secondary)
        case .matched(let confidence):
            Label("Matched \(percentage(confidence))", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .needsReview(let confidence):
            Label("Review \(percentage(confidence))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .noMatch:
            Label("No match", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .error:
            Label("Error", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func resultDescription(_ result: RenameOutcome) -> String {
        switch result {
        case .renamed(let to): return "Moved → \(to)"
        case .dryRun(let to):  return "Would move → \(to)"
        case .skipped(let r):  return "Skipped: \(r)"
        case .failed(let r):   return "Failed: \(r)"
        }
    }

    private func resultColor(_ result: RenameOutcome) -> Color {
        switch result {
        case .renamed: return .green
        case .dryRun:  return .blue
        case .skipped: return .secondary
        case .failed:  return .red
        }
    }
}
