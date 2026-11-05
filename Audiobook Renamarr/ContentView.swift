import SwiftUI
import UniformTypeIdentifiers

enum FolderPickerTarget {
    case source, output
}

struct ContentView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var isPickingFolder = false
    @State private var pickerTarget: FolderPickerTarget = .source
    @State private var isEditingRule = false
    @State private var isDroppingSource = false
    @State private var confirmClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.items.isEmpty {
                emptyState
            } else {
                FileListView(viewModel: viewModel)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 580)
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                switch pickerTarget {
                case .output:
                    if let url = urls.first { viewModel.loadOutputFolder(url) }
                case .source:
                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    if let url = urls.first,
                       fm.fileExists(atPath: url.path, isDirectory: &isDir),
                       isDir.boolValue {
                        // Picked a folder
                        viewModel.loadFolder(url)
                    } else if let parent = urls.first?.deletingLastPathComponent() {
                        // Picked one or more audio files — use parent folder
                        viewModel.loadFolder(parent)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDroppingSource) { providers in
            handleDrop(providers: providers)
        }
        .overlay(dropOverlay)
        .confirmationDialog(
            "Clear all files from the list?",
            isPresented: $confirmClearAll
        ) {
            Button("Clear All", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This only empties the list. No files are moved or deleted.")
        }
        .sheet(isPresented: $isEditingRule) {
            RenameRuleEditorView(rule: viewModel.rule) { updated in
                viewModel.updateRule(updated)
            }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let supportedExts = FolderScanner.supportedExtensions
        var resolvedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                resolvedURLs.append(url)
            }
        }

        group.notify(queue: .main) {
            guard !resolvedURLs.isEmpty else { return }

            let fm = FileManager.default
            var folders: [URL] = []
            var audioFiles: [URL] = []

            for url in resolvedURLs {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    folders.append(url)
                } else if supportedExts.contains(url.pathExtension.lowercased()) {
                    audioFiles.append(url)
                }
            }

            if folders.count == 1 && audioFiles.isEmpty {
                viewModel.loadFolder(folders[0])
            } else if folders.count > 1 {
                let commonParent = commonAncestor(of: folders)
                viewModel.recursiveScan = true
                viewModel.loadFolder(commonParent)
            } else if !audioFiles.isEmpty {
                let parents = Set(audioFiles.map { $0.deletingLastPathComponent().path })
                if parents.count == 1, let parent = audioFiles.first?.deletingLastPathComponent() {
                    viewModel.loadFolder(parent)
                } else {
                    let commonParent = commonAncestor(of: audioFiles.map { $0.deletingLastPathComponent() })
                    viewModel.recursiveScan = true
                    viewModel.loadFolder(commonParent)
                }
            }
        }

        return true
    }

    private func commonAncestor(of urls: [URL]) -> URL {
        guard !urls.isEmpty else { return URL(fileURLWithPath: "/") }
        guard urls.count > 1 else { return urls[0] }

        let components = urls.map { $0.pathComponents }
        let minLength  = components.map(\.count).min() ?? 1
        var common: [String] = []

        for i in 0..<minLength {
            let segment = components[0][i]
            if components.allSatisfy({ $0[i] == segment }) {
                common.append(segment)
            } else {
                break
            }
        }

        return URL(fileURLWithPath: common.joined(separator: "/"))
    }

    // MARK: - Drop overlay

    @ViewBuilder
    private var dropOverlay: some View {
        if isDroppingSource {
            ZStack {
                Color.accentColor.opacity(0.15)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop folder or audio files")
                        .font(.title3.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header / footer / empty state

    private func pickFolder(_ target: FolderPickerTarget) {
        pickerTarget = target
        isPickingFolder = true
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { pickFolder(.source) } label: {
                    Label("Source Folder…", systemImage: "folder")
                }
                if let url = viewModel.folderURL {
                    Text(url.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("Include subfolders", isOn: $viewModel.recursiveScan)
                    .toggleStyle(.checkbox)
                    .disabled(viewModel.isScanning)
                Button { isEditingRule = true } label: {
                    Label("Rename Rule…", systemImage: "textformat")
                }
            }

            HStack(spacing: 12) {
                Button { pickFolder(.output) } label: {
                    Label("Output Folder…", systemImage: "arrow.right.circle")
                }
                if let url = viewModel.outputFolderURL {
                    Text(url.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        viewModel.clearOutputFolder()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear — files will be renamed in place")
                } else {
                    Text("Not set — files will be renamed in place")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop a folder here, or click Source Folder…")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Supports folders, subfolders, and audio files dropped directly")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isMatching {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking up metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: viewModel.matchProgress)
                        .progressViewStyle(.linear)
                }
            }

            if viewModel.isRenaming {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(viewModel.dryRun ? "Previewing…" : "Moving files…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let current = viewModel.currentlyProcessing {
                            Text(current)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 400, alignment: .trailing)
                        }
                    }
                    ProgressView(value: viewModel.renameProgress)
                        .progressViewStyle(.linear)
                }
            }

            if let status = viewModel.statusMessage, !viewModel.isMatching, !viewModel.isRenaming {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Dry run (preview only — no files moved)", isOn: $viewModel.dryRun)
                    .toggleStyle(.checkbox)

                if viewModel.completedCount > 0 {
                    Button {
                        viewModel.clearCompleted()
                    } label: {
                        Label("Clear Completed (\(viewModel.completedCount))", systemImage: "checkmark.circle")
                    }
                    .disabled(!viewModel.canEditList)
                    .help("Remove files that have already been moved from the list")
                }

                Button {
                    confirmClearAll = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(viewModel.items.isEmpty || !viewModel.canEditList)
                .help("Empty the list (files on disk are not touched)")

                Spacer()

                Button {
                    Task { await viewModel.matchAll() }
                } label: {
                    if viewModel.isMatching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Find Matches", systemImage: "magnifyingglass")
                    }
                }
                .disabled(viewModel.items.isEmpty || viewModel.isMatching)

                Button {
                    Task { await viewModel.performRename() }
                } label: {
                    Label(
                        viewModel.dryRun ? "Preview Move" : "Move Files",
                        systemImage: viewModel.dryRun ? "eye" : "arrow.right.circle.fill"
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasRenamableItems || viewModel.isRenaming || viewModel.isMatching)
            }
        }
        .padding()
    }

    private var hasRenamableItems: Bool {
        viewModel.items.contains { $0.includeInBatch && $0.proposedFilename != nil }
    }
}

#Preview {
    ContentView()
}
