import SwiftUI
import AppKit

struct FileListView: View {
    @EnvironmentObject var viewModel: LibraryViewModel

    private var folders: [(path: String, name: String, items: [AudioFileItem])] {
        let visible = viewModel.showReviewOnly
            ? viewModel.items.filter {
                if case .review = $0.matchState { return true }
                if case .noMatch = $0.matchState { return true }
                if case .error = $0.matchState { return true }
                return false
            }
            : viewModel.items

        let grouped = Dictionary(grouping: visible, by: \.folderPath)
        return grouped
            .map { (path: $0.key,
                    name: $0.value.first?.folderName ?? $0.key,
                    items: $0.value.sorted {
                        $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                    }) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(folders, id: \.path) { folder in
                    Section {
                        if !viewModel.collapsedFolders.contains(folder.path) {
                            ForEach(folder.items) { item in
                                FileRowView(item: item)
                                Divider().padding(.leading, 36)
                            }
                        }
                    } header: {
                        FolderHeaderView(
                            folderPath: folder.path,
                            folderName: folder.name,
                            items: folder.items
                        )
                    }
                }
            }
        }
    }
}

struct FolderHeaderView: View {
    @EnvironmentObject var viewModel: LibraryViewModel
    let folderPath: String
    let folderName: String
    let items: [AudioFileItem]
    @State private var showManualSearch = false
    @State private var manualQuery = ""

    private var isCollapsed: Bool { viewModel.collapsedFolders.contains(folderPath) }
    private var isMultiFile: Bool { items.count > 1 }
    private var folderNameSearchActive: Bool { viewModel.folderNameOverrides.contains(folderPath) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Folder checkbox: ☑ all / ☐ none / ▣ mixed.
                Button {
                    viewModel.toggleFolderIncluded(folderPath: folderPath)
                } label: {
                    Image(systemName: checkboxSymbol)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Include or exclude all matchable files in this folder")

                // Collapse/expand.
                Button {
                    viewModel.toggleCollapsed(folderPath: folderPath)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(folderName)
                            .fontWeight(.medium)
                        if isCollapsed {
                            Text("(\(items.count) file\(items.count == 1 ? "" : "s"))")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: folderPath)]
                        )
                    }
                }

                Spacer()

                if let error = groupError {
                    Button {
                        if let key = items.first?.groupKey {
                            viewModel.rematchGroup(key: key)
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .help(error)
                }

                if groupHasNoMatch && !showManualSearch {
                    Button {
                        openSearchField()
                    } label: {
                        Label("No results — edit search", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Adjust the keywords that were searched and try again")
                }

                Button {
                    if showManualSearch {
                        showManualSearch = false
                    } else {
                        openSearchField()
                    }
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Manual search — edit the query or paste an Audible URL/ASIN")

                if isMultiFile {
                    Button {
                        viewModel.toggleFolderNameSearch(folderPath: folderPath)
                    } label: {
                        HStack(spacing: 4) {
                            if folderNameSearchActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Text("Search by folder name")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Force this folder's name to be used as the search query")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showManualSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search Audible or paste ASIN / URL…", text: $manualQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runManualSearch)
                    Button("Search", action: runManualSearch)
                        .disabled(manualQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            Divider()
        }
        .background(.bar)
    }

    /// Opens the search field pre-filled with the query that was actually
    /// sent — so a failed search can be inspected and adjusted, not retyped.
    private func openSearchField() {
        if let key = items.first?.groupKey,
           let last = viewModel.lastQueries[key], !last.isEmpty {
            manualQuery = last
        } else if manualQuery.isEmpty {
            manualQuery = folderName
        }
        showManualSearch = true
    }

    private var groupHasNoMatch: Bool {
        items.contains { item in
            if case .noMatch = item.matchState { return true }
            return false
        }
    }

    private func runManualSearch() {
        guard let key = items.first?.groupKey else { return }
        viewModel.manualSearch(keywords: manualQuery, groupKey: key)
        showManualSearch = false
    }

    private var checkboxSymbol: String {
        switch viewModel.folderIncludedState(folderPath: folderPath) {
        case true: return "checkmark.square.fill"
        case false: return "square"
        default: return "minus.square.fill"
        }
    }

    private var groupError: String? {
        for item in items {
            if case .error(let message) = item.matchState { return message }
        }
        return nil
    }
}
