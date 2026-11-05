import SwiftUI
import AppKit

struct FileRowView: View {
    @EnvironmentObject var viewModel: LibraryViewModel
    let item: AudioFileItem
    @State private var showAlternates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { item.isIncluded },
                    set: { _ in viewModel.toggleIncluded(itemID: item.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.selectedMatch == nil)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(item.proposedRelativePath ?? "—")
                            .font(.callout)
                            .foregroundStyle(item.proposedRelativePath == nil ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let result = item.renameResult {
                        resultView(result)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    confidenceBadge
                    if !item.candidates.isEmpty, item.candidates.count > 1 || item.selectedMatch == nil {
                        Button {
                            showAlternates.toggle()
                        } label: {
                            Text(showAlternates
                                 ? "Hide alternates"
                                 : "Show \(item.candidates.count) alternate\(item.candidates.count == 1 ? "" : "s")")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if showAlternates {
                alternatesList
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if let moved = movedDestination {
                Button("Show in Finder") { reveal(moved) }
            } else {
                Button("Show in Finder") { reveal(item.url) }
                if let folder = previewDestinationFolder {
                    Button("Show Destination Folder in Finder") { reveal(folder) }
                }
            }
        }
    }

    // MARK: - Finder reveal

    private var movedDestination: URL? {
        if case .moved(let destination) = item.renameResult {
            return URL(fileURLWithPath: destination)
        }
        return nil
    }

    /// The folder this file would land in — only offered when it already
    /// exists on disk (before a real move the file itself isn't there yet).
    private var previewDestinationFolder: URL? {
        guard let relative = item.proposedRelativePath else { return nil }
        let base = viewModel.outputFolder ?? URL(fileURLWithPath: item.folderPath)
        var components = relative.components(separatedBy: "/")
        components.removeLast() // drop the filename
        let folder = components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Badge

    @ViewBuilder
    private var confidenceBadge: some View {
        switch item.matchState {
        case .pending:
            Text("Not searched")
                .badgeStyle(color: .secondary)
        case .searching:
            ProgressView()
                .controlSize(.small)
        case .matched(let confidence):
            Label("Matched \(Int((confidence * 100).rounded()))%", systemImage: "checkmark.circle.fill")
                .badgeStyle(color: .green)
        case .review(let confidence):
            Label("Review \(Int((confidence * 100).rounded()))%", systemImage: "exclamationmark.triangle.fill")
                .badgeStyle(color: .orange)
        case .noMatch:
            Label("No match", systemImage: "circle.dotted")
                .badgeStyle(color: .secondary)
        case .error(let message):
            Label("Error", systemImage: "exclamationmark.octagon.fill")
                .badgeStyle(color: .red)
                .help(message)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func resultView(_ result: RenameResult) -> some View {
        switch result {
        case .moved(let destination):
            Label(destination, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .dryRun(let destination):
            Label("Preview: \(destination)", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .skipped:
            Label("Skipped (already named correctly)", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Alternates

    private var alternatesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(item.candidates) { candidate in
                HStack(spacing: 8) {
                    Button {
                        viewModel.selectMatch(candidate, for: item.id)
                    } label: {
                        Image(systemName: item.selectedMatch?.product.asin == candidate.product.asin
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.product.title ?? "Untitled")
                            .font(.callout)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if let author = candidate.product.allAuthors {
                                Text(author)
                            }
                            if let series = candidate.product.primarySeries,
                               let title = series.title {
                                Text("· \(title)\(series.sequence.map { " #\($0)" } ?? "")")
                            }
                            if let year = candidate.product.releaseYear {
                                Text("· \(String(year))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer()

                    Text("\(candidate.percent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button("Apply to folder") {
                        viewModel.applyMatchToFolder(candidate, for: item.id)
                        showAlternates = false
                    }
                    .controlSize(.small)
                    .help("Apply this match to every file in the folder")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func badgeStyle(color: Color) -> some View {
        self
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
