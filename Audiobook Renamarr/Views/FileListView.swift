import SwiftUI

struct FileListView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var collapsedFolders: Set<String> = []

    private var groupedItems: [(folderPath: String, folderName: String, items: [AudioFileItem])] {
        let grouped = Dictionary(grouping: viewModel.items) { item in
            item.originalURL.deletingLastPathComponent().path
        }
        return grouped
            .map { path, items in (
                folderPath: path,
                folderName: URL(fileURLWithPath: path).lastPathComponent,
                items: items.sorted {
                    $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending
                }
            )}
            .sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            List {
                ForEach(groupedItems, id: \.folderPath) { group in
                    Section(header: folderHeader(group)) {
                        if !collapsedFolders.contains(group.folderPath) {
                            ForEach(group.items) { item in
                                FileRowView(
                                    item: item,
                                    candidates: item.candidates,
                                    onToggleInclude: { include in
                                        viewModel.setIncluded(include, for: item.id)
                                    },
                                    onSelectMatch: { match in
                                        viewModel.selectMatch(match, for: item.id)
                                    },
                                    onApplyToFolder: { match in
                                        viewModel.applyMatchToFolder(match, for: item.id)
                                    },
                                    onRemove: {
                                        viewModel.removeItem(item.id)
                                    },
                                    canRemove: viewModel.canEditList
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func folderHeader(_ group: (folderPath: String, folderName: String, items: [AudioFileItem])) -> some View {
        let isOverride   = viewModel.folderNameOverrides.contains(group.folderPath)
        let isCollapsed  = collapsedFolders.contains(group.folderPath)
        let includedState = viewModel.folderIncludedState(folderPath: group.folderPath)

        return HStack(spacing: 8) {

            // ── Folder checkbox ──
            Button {
                viewModel.toggleFolderIncluded(folderPath: group.folderPath)
            } label: {
                Image(systemName: includedState == true
                      ? "checkmark.square.fill"
                      : includedState == false
                        ? "square"
                        : "minus.square.fill")   // mixed state
                    .foregroundStyle(includedState == true ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Check/uncheck all files in this folder")

            // ── Collapse toggle ──
            Button {
                if isCollapsed {
                    collapsedFolders.remove(group.folderPath)
                } else {
                    collapsedFolders.insert(group.folderPath)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(group.folderName)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("(\(group.items.count) file\(group.items.count == 1 ? "" : "s"))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // ── Search by folder name toggle ──
            if group.items.count > 1 {
                Button {
                    Task { await viewModel.toggleFolderNameOverride(for: group.folderPath) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isOverride ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOverride ? .green : .secondary)
                        Text("Search by folder name")
                            .font(.caption)
                            .foregroundStyle(isOverride ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Ignore individual filenames and search Audible using only the folder name.")
            }

            // ── Remove whole folder from the list ──
            Button {
                viewModel.removeFolder(group.folderPath)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canEditList)
            .help("Remove this folder from the list (files on disk are not touched)")
        }
        .padding(.vertical, 4)
    }

    private var columnHeader: some View {
        HStack {
            Text("").frame(width: 48)  // checkbox + chevron space
            Text("Original Filename").frame(maxWidth: .infinity, alignment: .leading)
            Text("Proposed Filename").frame(maxWidth: .infinity, alignment: .leading)
            Text("Match").frame(width: 120, alignment: .leading)
            Text("").frame(width: 20)  // remove button space
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
