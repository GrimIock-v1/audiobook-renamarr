import SwiftUI
import UniformTypeIdentifiers

/// Single `.fileImporter` target selector — avoids SwiftUI's two-importer
/// conflict bug.
enum FolderPickerTarget: Identifiable {
    case source
    case output
    var id: Int { self == .source ? 0 : 1 }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: LibraryViewModel
    @State private var pickerTarget: FolderPickerTarget = .source
    @State private var showPicker = false
    @State private var showRuleEditor = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            progressArea
            content
            Divider()
            bottomBar
        }
        .overlay(dropOverlay)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: pickerTarget == .source ? [.folder, .audio] : [.folder],
            allowsMultipleSelection: pickerTarget == .source
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            switch pickerTarget {
            case .source:
                let folders = urls.filter(\.hasDirectoryPath)
                let files = urls.filter { !$0.hasDirectoryPath }
                if let folder = folders.first {
                    viewModel.setSourceFolder(folder)
                }
                if !files.isEmpty {
                    viewModel.addFiles(files)
                }
            case .output:
                if let url = urls.first {
                    viewModel.setOutputFolder(url)
                }
            }
        }
        .sheet(isPresented: $showRuleEditor) {
            RenameRuleEditorView(rule: $viewModel.rule)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                pickerTarget = .source
                showPicker = true
            } label: {
                Label(
                    viewModel.sourceFolder?.lastPathComponent ?? "Add Folder or Files",
                    systemImage: "folder"
                )
            }
            .help("Choose a folder to scan, or pick individual audio files to import")

            Toggle("Include subfolders", isOn: $viewModel.includeSubfolders)
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.includeSubfolders) { _ in
                    Task { await viewModel.scan() }
                }

            Divider().frame(height: 16)

            Button {
                pickerTarget = .output
                showPicker = true
            } label: {
                Label(
                    viewModel.outputFolder?.lastPathComponent ?? "Output Folder",
                    systemImage: "folder.badge.plus"
                )
            }
            .help("Files are moved here, organized by the rename template. Leave unset to rename in place.")

            if viewModel.outputFolder != nil {
                Button {
                    viewModel.setOutputFolder(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear output folder (rename in place)")
            }

            Spacer()

            if viewModel.canUndoLastMove {
                Button {
                    Task { await viewModel.undoLastMove() }
                } label: {
                    Label("Undo Last Move", systemImage: "arrow.uturn.backward")
                }
                .disabled(viewModel.isRenaming || viewModel.isMatching)
            }

            Toggle(isOn: $viewModel.showReviewOnly) {
                Label("Needs review", systemImage: "line.3.horizontal.decrease.circle")
            }
            .toggleStyle(.button)
            .help("Show only files that need review")

            Button {
                showRuleEditor = true
            } label: {
                Label("Rename Rule", systemImage: "textformat")
            }

            Button {
                Task { await viewModel.findMatches() }
            } label: {
                Label("Find Matches", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(viewModel.items.isEmpty || viewModel.isMatching || viewModel.isRenaming)
        }
        .padding(10)
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressArea: some View {
        if viewModel.isMatching {
            HStack(spacing: 8) {
                ProgressView(value: viewModel.matchProgress)
                Text("\(Int(viewModel.matchProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else if viewModel.isRenaming {
            HStack(spacing: 8) {
                ProgressView(value: viewModel.renameProgress)
                if let current = viewModel.currentlyProcessing {
                    Text(current)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            emptyState
        } else {
            FileListView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Drop a folder or audio files here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or click “Source Folder” in the toolbar")
                .font(.callout)
                .foregroundStyle(.tertiary)
            if viewModel.isScanning {
                ProgressView().padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Move companion files", isOn: $viewModel.moveCompanionFiles)
                .toggleStyle(.checkbox)
                .help("Cover art, .cue, .nfo and similar files move with the book")

            Toggle("Clean empty folders", isOn: $viewModel.cleanupEmptyFolders)
                .toggleStyle(.checkbox)
                .help("Delete source folders left empty after moving")

            Toggle("Copy instead of move", isOn: $viewModel.copyInsteadOfMove)
                .toggleStyle(.checkbox)
                .help("Safer for first runs — sources are left untouched")

            Toggle("Dry run", isOn: $viewModel.dryRun)
                .toggleStyle(.switch)

            Button {
                Task { await viewModel.performRename() }
            } label: {
                Label(
                    viewModel.dryRun ? "Preview Move" : (viewModel.copyInsteadOfMove ? "Copy Files" : "Move Files"),
                    systemImage: viewModel.dryRun ? "eye" : "arrow.right.doc.on.clipboard"
                )
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.includedCount == 0 || viewModel.isMatching || viewModel.isRenaming)

            Text("\(viewModel.includedCount) selected")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: - Drop handling

    private var dropOverlay: some View {
        Group {
            if isDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, dash: [10, 6])
                        )
                        .padding(8)
                    Label("Drop folder or audio files", systemImage: "arrow.down.circle")
                        .font(.title2)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        // loadObject completions can arrive concurrently on background
        // threads — serialize all appends onto the main queue.
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let collected = urls
            Task { @MainActor in
                viewModel.handleDrop(urls: collected)
            }
        }
        return true
    }
}
