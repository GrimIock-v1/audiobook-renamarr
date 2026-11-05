import Foundation
import Combine

final class LibraryViewModel: ObservableObject {
    @Published var items: [AudioFileItem] = []
    @Published var folderURL: URL?
    @Published var outputFolderURL: URL?
    @Published var rule = RenameRule()
    @Published var dryRun: Bool = true
    @Published var recursiveScan: Bool = true
    @Published var isScanning = false
    @Published var isMatching = false
    @Published var isRenaming = false
    @Published var statusMessage: String?
    @Published var folderNameOverrides: Set<String> = []

    // Progress tracking
    @Published var matchProgress: Double = 0   // 0.0 – 1.0
    @Published var renameProgress: Double = 0  // 0.0 – 1.0
    @Published var currentlyProcessing: String? = nil  // live filename log

    private let metadataService: AudibleMetadataSearching
    private let cache = MetadataCache()
    private var securityScopedFolder: URL?
    private var securityScopedOutput: URL?

    init(metadataService: AudibleMetadataSearching = AudibleMetadataService()) {
        self.metadataService = metadataService
    }

    deinit {
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        securityScopedOutput?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Folder selection

    func loadFolder(_ url: URL) {
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        let didStart = url.startAccessingSecurityScopedResource()
        securityScopedFolder = didStart ? url : nil

        folderURL = url
        items = []
        folderNameOverrides = []
        statusMessage = nil
        matchProgress = 0
        renameProgress = 0

        isScanning = true
        defer { isScanning = false }

        do {
            let urls = try FolderScanner.scan(folder: url, recursive: recursiveScan)
            items = urls.map { AudioFileItem(originalURL: $0) }
            statusMessage = urls.isEmpty
                ? "No supported audio files found in this folder."
                : "\(urls.count) audio file(s) found. Click \u{201c}Find Matches\u{201d} to look them up."
        } catch {
            statusMessage = "Could not scan folder: \(error.localizedDescription)"
        }
    }

    func loadOutputFolder(_ url: URL) {
        securityScopedOutput?.stopAccessingSecurityScopedResource()
        let didStart = url.startAccessingSecurityScopedResource()
        securityScopedOutput = didStart ? url : nil
        outputFolderURL = url
        for index in items.indices {
            items[index].proposedFilename = RenameEngine.proposedFilename(for: items[index], rule: rule)
        }
    }

    func clearOutputFolder() {
        securityScopedOutput?.stopAccessingSecurityScopedResource()
        securityScopedOutput = nil
        outputFolderURL = nil
        for index in items.indices {
            items[index].proposedFilename = RenameEngine.proposedFilename(for: items[index], rule: rule)
        }
    }

    // MARK: - Folder name override toggle

    func toggleFolderNameOverride(for folderPath: String) async {
        if folderNameOverrides.contains(folderPath) {
            folderNameOverrides.remove(folderPath)
        } else {
            folderNameOverrides.insert(folderPath)
        }

        let affectedIndices = items.indices.filter {
            items[$0].originalURL.deletingLastPathComponent().path == folderPath
        }
        guard !affectedIndices.isEmpty else { return }

        let groups = buildGroups(from: Array(affectedIndices))
        await MainActor.run { isMatching = true }
        defer { Task { @MainActor in self.isMatching = false } }

        await withTaskGroup(of: Void.self) { group in
            for indices in groups {
                group.addTask { [weak self] in
                    await self?.matchGroup(indices: indices)
                }
            }
        }
    }

    // MARK: - Apply match to entire folder

    /// Applies a chosen match to every file in the same folder,
    /// so the user doesn't have to correct 50 files one by one.
    func applyMatchToFolder(_ match: AudibleMatch, for itemID: UUID) {
        guard let clickedIndex = items.firstIndex(where: { $0.id == itemID }) else { return }
        let folderPath = items[clickedIndex].originalURL.deletingLastPathComponent().path

        for index in items.indices {
            guard items[index].originalURL.deletingLastPathComponent().path == folderPath else { continue }
            items[index].selectedMatch    = match
            items[index].status           = .matched(confidence: 1.0)
            items[index].includeInBatch   = true
            items[index].proposedFilename = RenameEngine.proposedFilename(for: items[index], rule: rule)
        }
    }

    // MARK: - Grouping

    private func buildGroups(from indices: [Int]) -> [[Int]] {
        let byFolder = Dictionary(grouping: indices) { index in
            items[index].originalURL.deletingLastPathComponent().path
        }

        var groups: [[Int]] = []
        for (_, folderIndices) in byFolder {
            if folderIndices.count == 1 {
                groups.append(folderIndices)
                continue
            }
            let byPrefix = Dictionary(grouping: folderIndices) { index in
                filenamePrefix(for: items[index].originalURL)
            }
            for (_, prefixIndices) in byPrefix {
                groups.append(prefixIndices)
            }
        }
        return groups
    }

    private func filenamePrefix(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()

        // Strip trailing chapter/track/number patterns.
        let trailingPatterns = [
            #"\s*(chapter|part|track|disc|disk|episode)\s*\d+\s*$"#,
            #"\s*[-–]\s*\d+\s*$"#,
            #"\s+\d+\s*$"#,
        ]
        for pattern in trailingPatterns {
            if let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                name.removeSubrange(range)
            }
        }

        // Strip middle track-number segments: "Title - 001 - Chapter Name"
        // → "Title". Covers the common pattern where a zero-padded track
        // number sits between the book title and chapter title.
        if let range = name.range(of: #"\s*-\s*0*\d{1,4}\s*-.*$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }

        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Search signal helpers

    private func searchCandidates(for url: URL, forceFolder: Bool) -> [ParsedFilename] {
        let parentFolder = url.deletingLastPathComponent()
        let rootFolder   = folderURL ?? parentFolder
        let folderName   = parentFolder.path == rootFolder.path
            ? url.deletingPathExtension().lastPathComponent
            : parentFolder.lastPathComponent
        let fakeURL = URL(fileURLWithPath: "/tmp/\(folderName).m4b")
        let folderCandidates = [
            FilenameParser.parse(fakeURL, assumeTitleFirst: false),
            FilenameParser.parse(fakeURL, assumeTitleFirst: true),
        ]

        if forceFolder { return folderCandidates }

        var candidates = [
            FilenameParser.parse(url, assumeTitleFirst: false),
            FilenameParser.parse(url, assumeTitleFirst: true),
        ]
        if parentFolder.path != rootFolder.path {
            candidates += folderCandidates
        }
        return candidates
    }

    // MARK: - Matching

    func matchAll() async {
        guard !items.isEmpty else { return }
        await MainActor.run {
            isMatching    = true
            matchProgress = 0
            statusMessage = "Looking up metadata\u{2026}"
        }
        defer { Task { @MainActor in self.isMatching = false } }

        let groups = buildGroups(from: Array(items.indices))
        let total  = Double(groups.count)
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for indices in groups {
                group.addTask { [weak self] in
                    await self?.matchGroup(indices: indices)
                    let done = await counter.increment()
                    await MainActor.run {
                        self?.matchProgress = Double(done) / total
                    }
                }
            }
        }

        let matchedCount = items.filter {
            if case .matched = $0.status { return true }
            return false
        }.count
        await MainActor.run {
            matchProgress = 1.0
            statusMessage = "Matched \(matchedCount) of \(items.count) file(s)."
        }
    }

    private func matchGroup(indices: [Int]) async {
        guard !indices.isEmpty else { return }

        let sorted = indices.sorted {
            items[$0].originalURL.lastPathComponent
                .localizedStandardCompare(items[$1].originalURL.lastPathComponent) == .orderedAscending
        }

        let isMultiFile = sorted.count > 1
        let folderPath  = items[sorted[0]].originalURL.deletingLastPathComponent().path
        let forceFolder = folderNameOverrides.contains(folderPath)

        // ── Resolve track numbers using sequence consistency check ──
        // For multi-file groups: find the number position in the filenames
        // that forms a complete unbroken sequence across all files. This
        // correctly identifies track numbers even when chapter numbers,
        // series numbers, or years are also present in the filename.
        // For single files: use whatever the parser found, or nil.
        var trackNumbers: [Int: Int?] = [:]

        if isMultiFile {
            let sortedURLs = sorted.map { items[$0].originalURL }
            let resolved   = TrackNumberResolver.resolve(sortedURLs: sortedURLs)
            for i in sorted {
                trackNumbers[i] = resolved[items[i].originalURL]
            }
        } else {
            let parsed = FilenameParser.parse(items[sorted[0]].originalURL, assumeTitleFirst: false)
            trackNumbers[sorted[0]] = parsed.trackNumber
        }

        await MainActor.run {
            for i in sorted { items[i].status = .searching }
        }

        let representativeURL = items[sorted[0]].originalURL
        let candidates: [ParsedFilename] = isMultiFile && !forceFolder
            ? searchCandidates(for: representativeURL, forceFolder: true)
            : searchCandidates(for: representativeURL, forceFolder: forceFolder)

        do {
            var seen = Set<String>()
            var allResults: [AudibleMatch] = []

            for parsed in candidates {
                let cacheKey = parsed.searchQuery.lowercased()
                guard !cacheKey.isEmpty else { continue }
                let results: [AudibleMatch]
                if let cached = await cache.cachedResult(for: cacheKey) {
                    results = cached
                } else {
                    results = try await metadataService.search(parsed: parsed)
                    await cache.store(results, for: cacheKey)
                }
                for match in results where seen.insert(match.asin).inserted {
                    allResults.append(match)
                }
            }

            let scored = allResults
                .map { match -> (match: AudibleMatch, score: Double) in
                    let best = candidates.map {
                        MatchScorer.score(parsed: $0, candidate: match)
                    }.max() ?? 0
                    return (match, best)
                }
                .sorted { $0.score > $1.score }

            let status      = MatchScorer.status(forTopScore: scored.first?.score)
            let bestMatch   = scored.first?.match
            let matchCandidates = scored.map(\.match)

            await MainActor.run {
                for i in sorted {
                    var parsed = FilenameParser.parse(items[i].originalURL, assumeTitleFirst: false)
                    parsed.trackNumber       = trackNumbers[i] ?? nil
                    items[i].parsed          = parsed
                    items[i].candidates      = matchCandidates
                    items[i].status          = status
                    items[i].selectedMatch   = bestMatch
                    items[i].includeInBatch  = bestMatch != nil
                    items[i].proposedFilename = RenameEngine.proposedFilename(for: items[i], rule: rule)
                }
            }

        } catch {
            await MainActor.run {
                for i in sorted {
                    var parsed = FilenameParser.parse(items[i].originalURL, assumeTitleFirst: false)
                    parsed.trackNumber  = trackNumbers[i] ?? nil
                    items[i].parsed     = parsed
                    items[i].status     = .error(error.localizedDescription)
                    items[i].includeInBatch = false
                }
            }
        }
    }

    // MARK: - Manual overrides

    func selectMatch(_ match: AudibleMatch, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].selectedMatch    = match
        items[index].status           = .matched(confidence: 1.0)
        items[index].includeInBatch   = true
        items[index].proposedFilename = RenameEngine.proposedFilename(for: items[index], rule: rule)
    }

    func setIncluded(_ included: Bool, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].includeInBatch = included
    }

    /// Toggles the included state for every file in a folder.
    /// If any file is currently excluded, includes all; if all included, excludes all.
    func toggleFolderIncluded(folderPath: String) {
        let indices = items.indices.filter {
            items[$0].originalURL.deletingLastPathComponent().path == folderPath
            && items[$0].selectedMatch != nil
        }
        let allIncluded = indices.allSatisfy { items[$0].includeInBatch }
        for i in indices {
            items[i].includeInBatch = !allIncluded
        }
    }

    /// Returns true if all matchable files in the folder are included,
    /// false if none, nil if mixed.
    func folderIncludedState(folderPath: String) -> Bool? {
        let indices = items.indices.filter {
            items[$0].originalURL.deletingLastPathComponent().path == folderPath
            && items[$0].selectedMatch != nil
        }
        guard !indices.isEmpty else { return nil }
        let included = indices.filter { items[$0].includeInBatch }.count
        if included == indices.count { return true }
        if included == 0 { return false }
        return nil
    }

    // MARK: - Clearing the list

    /// Removing items shifts the indices that in-flight matching and moving
    /// rely on, so list edits are blocked while either is running.
    var canEditList: Bool { !isMatching && !isRenaming }

    /// Number of files that have already been moved (safe to clear).
    var completedCount: Int {
        items.filter { if case .renamed = $0.renameResult { return true }; return false }.count
    }

    /// Removes one file from the list. The file on disk is not touched.
    func removeItem(_ itemID: UUID) {
        guard canEditList else { return }
        items.removeAll { $0.id == itemID }
        pruneFolderState()
    }

    /// Removes every file in a folder from the list. Nothing on disk changes.
    func removeFolder(_ folderPath: String) {
        guard canEditList else { return }
        items.removeAll { $0.originalURL.deletingLastPathComponent().path == folderPath }
        pruneFolderState()
    }

    /// Removes files that have already been moved, leaving the rest in place.
    func clearCompleted() {
        guard canEditList else { return }
        let removed = completedCount
        items.removeAll { if case .renamed = $0.renameResult { return true }; return false }
        pruneFolderState()
        if !items.isEmpty {
            statusMessage = "Cleared \(removed) completed file(s)."
        }
    }

    /// Empties the list and releases the source folder. The output folder and
    /// rename rule are kept so the next batch can start straight away.
    func clearAll() {
        guard canEditList else { return }
        items = []
        folderNameOverrides = []
        folderURL = nil
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        securityScopedFolder = nil
        matchProgress = 0
        renameProgress = 0
        currentlyProcessing = nil
        statusMessage = nil
    }

    /// Drops per-folder state for folders that no longer have any files.
    private func pruneFolderState() {
        let livePaths = Set(items.map { $0.originalURL.deletingLastPathComponent().path })
        folderNameOverrides = folderNameOverrides.intersection(livePaths)
        if items.isEmpty {
            statusMessage = "List cleared. Drop a folder or choose a source folder to start again."
        }
    }

    func updateRule(_ newRule: RenameRule) {
        rule = newRule
        for index in items.indices {
            items[index].proposedFilename = RenameEngine.proposedFilename(for: items[index], rule: rule)
        }
    }

    // MARK: - Renaming

    func performRename() async {
        isRenaming          = true
        renameProgress      = 0
        currentlyProcessing = nil
        defer {
            isRenaming          = false
            currentlyProcessing = nil
        }

        let eligible = items.filter { $0.includeInBatch && $0.proposedFilename != nil }
        let total    = Double(max(eligible.count, 1))
        var done     = 0
        var usedNames = Set<String>()
        let fm        = FileManager.default
        let isDry     = dryRun
        let outputURL = outputFolderURL

        for index in items.indices {
            guard items[index].includeInBatch,
                  let proposed = items[index].proposedFilename else { continue }

            // Show the current file in the footer so the user knows
            // the app is working and hasn't frozen.
            currentlyProcessing = items[index].originalFilename

            let destinationRoot = outputURL ?? items[index].originalURL.deletingLastPathComponent()
            let destination     = destinationRoot.appendingPathComponent(proposed)

            if destination.path == items[index].originalURL.path {
                items[index].renameResult = .skipped(reason: "Already in the right place")
                usedNames.insert(proposed)
            } else {
                let uniqueName       = uniquePath(proposed, in: destinationRoot, alreadyUsed: usedNames, fm: fm)
                let finalDestination = destinationRoot.appendingPathComponent(uniqueName)
                usedNames.insert(uniqueName)

                if isDry {
                    items[index].renameResult = .dryRun(to: finalDestination.path)
                } else {
                    // Yield to the run loop between files so the UI can
                    // update the progress bar and filename log.
                    await Task.yield()
                    do {
                        try fm.createDirectory(
                            at: finalDestination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fm.moveItem(at: items[index].originalURL, to: finalDestination)
                        items[index].renameResult = .renamed(to: finalDestination.path)
                    } catch {
                        items[index].renameResult = .failed(reason: error.localizedDescription)
                    }
                }
            }

            done += 1
            renameProgress = Double(done) / total
        }

        let renamed    = items.filter { if case .renamed  = $0.renameResult { return true }; return false }.count
        let plannedDry = items.filter { if case .dryRun   = $0.renameResult { return true }; return false }.count
        let failed     = items.filter { if case .failed   = $0.renameResult { return true }; return false }.count

        renameProgress = 1.0

        if isDry {
            statusMessage = "Dry run complete: \(plannedDry) file(s) would be moved."
        } else {
            let dest = outputURL?.path ?? "in place"
            statusMessage = failed == 0
                ? "Moved \(renamed) file(s) to \(dest)."
                : "Moved \(renamed) file(s), \(failed) failed \u{2014} see details below."
        }
    }

    private func uniquePath(_ relative: String, in root: URL, alreadyUsed: Set<String>, fm: FileManager) -> String {
        let ext     = (relative as NSString).pathExtension
        let base    = (relative as NSString).deletingPathExtension
        let extPart = ext.isEmpty ? "" : ".\(ext)"

        var candidate = relative
        var counter   = 2
        while alreadyUsed.contains(candidate)
            || fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(counter))\(extPart)"
            counter  += 1
        }
        return candidate
    }
}

/// Thread-safe counter for tracking concurrent group completions.
private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
