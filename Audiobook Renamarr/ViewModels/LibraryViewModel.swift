import Foundation
import Combine
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: - Published state

    @Published var items: [AudioFileItem] = []
    @Published var sourceFolder: URL?
    @Published var outputFolder: URL?
    @Published var includeSubfolders = true
    @Published var isScanning = false
    @Published var isMatching = false
    @Published var isRenaming = false
    @Published var dryRun = true
    @Published var copyInsteadOfMove = false
    @Published var moveCompanionFiles = true
    @Published var cleanupEmptyFolders = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var matchProgress: Double = 0
    @Published var renameProgress: Double = 0
    @Published var currentlyProcessing: String?
    @Published var collapsedFolders: Set<String> = []
    @Published var showReviewOnly = false
    /// Folders forced to search by folder name; persists across re-matches
    /// in the same session.
    @Published var folderNameOverrides: Set<String> = []
    /// The exact keywords last sent to Audible, per group — surfaced in the
    /// UI so a failed search can be inspected and edited rather than retyped.
    @Published var lastQueries: [String: String] = [:]
    @Published var canUndoLastMove = false
    @Published var rule: RenameRule = .default {
        didSet { persistRule() }
    }

    // MARK: - Services

    private let scanner = FolderScanner()
    private let tagReader = TagReader()
    private let metadataService: AudibleMetadataSearching
    private let cache = MetadataCache()
    private let scorer = MatchScorer()
    private let renameEngine = RenameEngine()
    private let manifest = MoveManifest()

    // Security-scoped access, held for session lifetime.
    private var sourceAccessURL: URL?
    private var outputAccessURL: URL?
    /// Individually imported files (drag-in / file picker) each carry their
    /// own security scope, retained for the session.
    private var fileAccessURLs: [URL] = []

    private static let ruleDefaultsKey = "renameRule"
    private static let sourceBookmarkKey = "sourceFolderBookmark"
    private static let outputBookmarkKey = "outputFolderBookmark"

    init(metadataService: AudibleMetadataSearching = AudibleMetadataService()) {
        self.metadataService = metadataService
        restoreRule()
        restoreBookmarks()
        canUndoLastMove = manifest.hasManifest
    }

    deinit {
        sourceAccessURL?.stopAccessingSecurityScopedResource()
        outputAccessURL?.stopAccessingSecurityScopedResource()
        for url in fileAccessURLs { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: - Folder selection

    func setSourceFolder(_ url: URL, fromBookmark: Bool = false) {
        sourceAccessURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            sourceAccessURL = url
        }
        sourceFolder = url
        if !fromBookmark { persistBookmark(for: url, key: Self.sourceBookmarkKey) }
        Task { await scan() }
    }

    func setOutputFolder(_ url: URL?, fromBookmark: Bool = false) {
        outputAccessURL?.stopAccessingSecurityScopedResource()
        outputAccessURL = nil
        outputFolder = url
        if let url {
            if url.startAccessingSecurityScopedResource() {
                outputAccessURL = url
            }
            if !fromBookmark { persistBookmark(for: url, key: Self.outputBookmarkKey) }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.outputBookmarkKey)
        }
        refreshProposals()
    }

    /// Imports explicitly chosen audio files — appended to the current list
    /// (deduplicated by path), never expanding to their parent folders.
    func addFiles(_ urls: [URL]) {
        let audio = urls.filter { FolderScanner.isSupportedAudioFile($0) }
        guard !audio.isEmpty else { return }

        for url in audio where url.startAccessingSecurityScopedResource() {
            fileAccessURLs.append(url)
        }

        let existingPaths = Set(items.map { $0.url.path })
        let newURLs = audio.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else {
            statusMessage = "Those files are already in the list"
            return
        }

        let newItems = scanner.items(forFiles: newURLs)
        items.append(contentsOf: newItems)
        statusMessage = "\(items.count) file\(items.count == 1 ? "" : "s") in \(groupKeys.count) book group\(groupKeys.count == 1 ? "" : "s")"
        Task { await readTags(urls: newURLs) }
    }

    /// Handles a drop of folders and/or audio files.
    func handleDrop(urls: [URL]) {
        let folders = urls.filter { $0.hasDirectoryPath || isDirectory($0) }
        let audioFiles = urls.filter { FolderScanner.isSupportedAudioFile($0) }

        if folders.count == 1 {
            setSourceFolder(folders[0])
        } else if folders.count > 1 {
            if let ancestor = commonAncestor(of: folders) {
                includeSubfolders = true
                setSourceFolder(ancestor)
            }
        } else if !audioFiles.isEmpty {
            // Bare files: import exactly these — do NOT expand to the folder.
            addFiles(audioFiles)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    func commonAncestor(of urls: [URL]) -> URL? {
        guard var common = urls.first?.pathComponents else { return nil }
        for url in urls.dropFirst() {
            let components = url.pathComponents
            var shared: [String] = []
            for (a, b) in zip(common, components) where a == b {
                shared.append(a)
            }
            common = shared
        }
        guard common.count > 1 else { return nil }
        return URL(fileURLWithPath: common.joined(separator: "/").replacingOccurrences(of: "//", with: "/"))
    }

    // MARK: - Scanning

    func scan() async {
        guard let sourceFolder else { return }
        isScanning = true
        statusMessage = nil
        errorMessage = nil
        let include = includeSubfolders
        let scanned = await Task.detached(priority: .userInitiated) { [scanner] in
            scanner.scan(root: sourceFolder, includeSubfolders: include)
        }.value

        items = scanned
        isScanning = false
        statusMessage = scanned.isEmpty
            ? "No audio files found"
            : "\(scanned.count) file\(scanned.count == 1 ? "" : "s") in \(groupKeys.count) book group\(groupKeys.count == 1 ? "" : "s")"

        // Read embedded tags in the background; strong search signal.
        Task { await readTags() }
    }

    private func readTags(urls: [URL]? = nil) async {
        let targets = urls ?? items.map(\.url)
        for url in targets {
            guard let tags = await tagReader.readTags(from: url) else { continue }
            if let index = items.firstIndex(where: { $0.url == url }) {
                items[index].tags = tags
                // Tags are a more reliable track source than filename heuristics
                // — but only within multi-file groups where order matters.
                if let track = tags.trackNumber,
                   items.filter({ $0.groupKey == items[index].groupKey }).count > 1 {
                    items[index].trackNumber = track
                }
            }
        }
    }

    // MARK: - Matching

    var groupKeys: [String] {
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.groupKey).inserted ? $0.groupKey : nil }
    }

    func findMatches() async {
        guard !items.isEmpty, !isMatching else { return }
        isMatching = true
        matchProgress = 0
        errorMessage = nil
        statusMessage = nil

        let keys = groupKeys
        let total = Double(keys.count)
        let counter = Counter()

        // Max 3 concurrent group searches per chunk; the throttler enforces
        // the true global request gap underneath regardless of concurrency.
        let chunks = stride(from: 0, to: keys.count, by: 3).map {
            Array(keys[$0..<min($0 + 3, keys.count)])
        }
        for chunk in chunks {
            await withTaskGroup(of: Void.self) { group in
                for key in chunk {
                    group.addTask { [weak self] in
                        await self?.matchGroup(key: key)
                        await counter.increment()
                    }
                }
                await group.waitForAll()
            }
            let done = await counter.value
            matchProgress = total > 0 ? Double(done) / total : 1
        }

        isMatching = false
        matchProgress = 1
        let matched = items.filter { $0.selectedMatch != nil }.count
        statusMessage = "Matched \(matched) of \(items.count) files"
        refreshProposals()
    }

    /// Re-runs matching for a single group (e.g. after a network error or
    /// toggling folder-name search).
    func rematchGroup(key: String) {
        Task {
            for index in items.indices where items[index].groupKey == key {
                items[index].matchState = .pending
            }
            await matchGroup(key: key, bypassCache: true)
            refreshProposals()
        }
    }

    private func matchGroup(key: String, bypassCache: Bool = false) async {
        guard let firstItem = items.first(where: { $0.groupKey == key }) else { return }
        setState(.searching, forGroupKey: key)

        let query = buildQuery(for: key)
        lastQueries[key] = [query.author, query.title]
            .compactMap { $0 }
            .joined(separator: " ")
        let cacheKey = "\(query.title)|\(query.author ?? "")"

        var matches: [ScoredMatch]?
        if !bypassCache {
            matches = await cache.lookup(key: cacheKey)
        }

        if matches == nil {
            do {
                matches = try await searchAndScore(query: query, item: firstItem)
                await cache.save(key: cacheKey, matches: matches ?? [])
            } catch {
                let message = (error as? AudibleServiceError)?.errorDescription
                    ?? error.localizedDescription
                setState(.error(message), forGroupKey: key)
                if case AudibleServiceError.rateLimited = error {
                    errorMessage = message
                }
                return
            }
        }

        // Recompute indices AFTER the awaits — items may have changed.
        applyMatches(matches ?? [], toGroupKey: key)
    }

    private func setState(_ state: MatchState, forGroupKey key: String) {
        for i in items.indices where items[i].groupKey == key {
            items[i].matchState = state
        }
    }

    private func searchAndScore(query: MatchScorer.Query, item: AudioFileItem) async throws -> [ScoredMatch] {
        var keywordSets: [String] = []

        // Primary convention.
        if let author = query.author {
            keywordSets.append("\(author) \(query.title)")
        }
        keywordSets.append(query.title)

        // Swapped convention ("Title - Author" filenames).
        if let swapped = item.parsed.swappedInterpretation {
            keywordSets.append("\(swapped.author ?? "") \(swapped.title)".trimmingCharacters(in: .whitespaces))
        }

        var best: [ScoredMatch] = []
        for keywords in deduplicate(keywordSets) {
            let products = try await metadataService.search(keywords: keywords)
            let scored = scorer.score(products: products, against: query)
            // Merge, keeping the best score per ASIN.
            for match in scored {
                if let existing = best.firstIndex(where: { $0.product.asin == match.product.asin }) {
                    if match.score > best[existing].score { best[existing] = match }
                } else {
                    best.append(match)
                }
            }
            // If we already have a very strong hit, skip remaining conventions.
            if best.contains(where: { $0.score >= 0.9 }) { break }
        }
        return best.sorted { $0.score > $1.score }
    }

    /// Removes empty and duplicate keyword sets while preserving order.
    private func deduplicate(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func buildQuery(for key: String) -> MatchScorer.Query {
        let group = items.filter { $0.groupKey == key }
        guard let first = group.first else {
            return MatchScorer.Query(title: "")
        }

        let totalDuration = group.compactMap { $0.tags?.durationSeconds }.reduce(0, +)
        let duration: Double? = totalDuration > 0 && group.allSatisfy({ $0.tags?.durationSeconds != nil })
            ? totalDuration : nil

        let forceFolderName = folderNameOverrides.contains(first.folderPath)

        // Tags first: album + artist beat filename parsing when present.
        if !forceFolderName,
           let album = first.tags?.album, !album.isEmpty {
            return MatchScorer.Query(
                title: album,
                author: first.tags?.artist,
                seriesNumber: first.parsed.seriesNumber,
                totalDurationSeconds: duration
            )
        }

        if group.count > 1 || forceFolderName {
            // Multi-file groups: parent folder name ONLY — chapter filenames
            // are noise, not book titles.
            let parsed = FilenameParser.parseFolderName(first.folderName)
            return MatchScorer.Query(
                title: parsed.title,
                author: parsed.author,
                seriesNumber: parsed.seriesNumber,
                totalDurationSeconds: duration
            )
        }

        // Single-file books: filename + immediate parent folder as combined
        // signals (one level up only).
        let parsed = first.parsed
        let folderParsed = FilenameParser.parseFolderName(first.folderName)
        return MatchScorer.Query(
            title: parsed.title,
            author: parsed.author ?? folderParsed.author,
            seriesNumber: parsed.seriesNumber ?? folderParsed.seriesNumber,
            totalDurationSeconds: duration
        )
    }

    private func applyMatches(_ matches: [ScoredMatch], toGroupKey key: String) {
        let indices = items.indices.filter { items[$0].groupKey == key }
        for i in indices {
            items[i].candidates = matches
            if let top = matches.first {
                if top.score >= MatchScorer.autoAcceptThreshold {
                    items[i].matchState = .matched(confidence: top.score)
                    items[i].selectedMatch = top
                    items[i].isIncluded = true
                } else {
                    items[i].matchState = .review(confidence: top.score)
                    items[i].selectedMatch = top
                    items[i].isIncluded = false
                }
            } else {
                items[i].matchState = .noMatch
                items[i].selectedMatch = nil
                items[i].isIncluded = false
            }
        }
    }

    // MARK: - Manual match controls

    func selectMatch(_ match: ScoredMatch, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].selectedMatch = match
        items[index].matchState = match.score >= MatchScorer.autoAcceptThreshold
            ? .matched(confidence: match.score)
            : .review(confidence: match.score)
        items[index].isIncluded = true
        refreshProposals()
    }

    /// One click fixes 50 chapter files: applies a match to ALL files
    /// sharing the folder path.
    func applyMatchToFolder(_ match: ScoredMatch, for itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        for index in items.indices where items[index].folderPath == item.folderPath {
            items[index].selectedMatch = match
            items[index].matchState = .matched(confidence: match.score)
            items[index].isIncluded = true
        }
        refreshProposals()
    }

    /// Manual search typed by the user, applied to one group.
    func manualSearch(keywords: String, groupKey: String) {
        Task {
            lastQueries[groupKey] = keywords
            setState(.searching, forGroupKey: groupKey)

            // Pasted ASIN / Audible URL → exact lookup.
            if let asin = ASINExtractor.extract(from: keywords) {
                do {
                    if let product = try await metadataService.lookup(asin: asin) {
                        let match = ScoredMatch(product: product, score: 1.0)
                        applyMatches([match], toGroupKey: groupKey)
                        refreshProposals()
                        return
                    }
                } catch { /* fall through to keyword search */ }
            }

            do {
                let products = try await metadataService.search(keywords: keywords)
                let query = buildQuery(for: groupKey)
                var scored = scorer.score(products: products, against: query)
                if scored.isEmpty {
                    // User insisted on this search — show raw results for
                    // manual pick even if scores are weak.
                    scored = products.map { ScoredMatch(product: $0, score: 0.5) }
                }
                applyMatches(scored, toGroupKey: groupKey)
            } catch {
                let message = (error as? AudibleServiceError)?.errorDescription ?? error.localizedDescription
                setState(.error(message), forGroupKey: groupKey)
            }
            refreshProposals()
        }
    }

    func toggleFolderNameSearch(folderPath: String) {
        if folderNameOverrides.contains(folderPath) {
            folderNameOverrides.remove(folderPath)
        } else {
            folderNameOverrides.insert(folderPath)
        }
        // Re-run immediately for affected groups.
        let keys = Set(items.filter { $0.folderPath == folderPath }.map(\.groupKey))
        for key in keys { rematchGroup(key: key) }
    }

    // MARK: - Inclusion toggles

    func toggleIncluded(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].isIncluded.toggle()
    }

    /// nil = mixed, true = all included, false = none.
    func folderIncludedState(folderPath: String) -> Bool? {
        let matchable = items.filter { $0.folderPath == folderPath && $0.selectedMatch != nil }
        guard !matchable.isEmpty else { return false }
        let included = matchable.filter(\.isIncluded).count
        if included == 0 { return false }
        if included == matchable.count { return true }
        return nil
    }

    func toggleFolderIncluded(folderPath: String) {
        let target = folderIncludedState(folderPath: folderPath) != true
        for index in items.indices
        where items[index].folderPath == folderPath && items[index].selectedMatch != nil {
            items[index].isIncluded = target
        }
    }

    func toggleCollapsed(folderPath: String) {
        if collapsedFolders.contains(folderPath) {
            collapsedFolders.remove(folderPath)
        } else {
            collapsedFolders.insert(folderPath)
        }
    }

    // MARK: - Proposals

    func refreshProposals() {
        for index in items.indices {
            guard let match = items[index].selectedMatch else {
                items[index].proposedRelativePath = nil
                continue
            }
            items[index].proposedRelativePath = renameEngine.proposedRelativePath(
                match: match,
                trackNumber: items[index].trackNumber,
                fileExtension: items[index].fileExtension,
                rule: rule
            )
        }

        // Safety net: if several files in the SAME source folder rendered
        // identical proposed paths, the grouper missed a numbering scheme.
        // Run the track resolver over just those files — it detects an
        // increasing sequence in the filenames, or falls back to filename
        // order — then re-render with the recovered track numbers.
        var byProposal: [String: [Int]] = [:]
        for index in items.indices {
            guard let path = items[index].proposedRelativePath else { continue }
            byProposal[items[index].folderPath + "|" + path, default: []].append(index)
        }
        for (_, indices) in byProposal where indices.count > 1 {
            let sorted = indices.sorted {
                items[$0].filename.localizedStandardCompare(items[$1].filename) == .orderedAscending
            }
            let resolved = TrackNumberResolver.resolve(sortedURLs: sorted.map { items[$0].url })
            for i in sorted {
                items[i].trackNumber = resolved[items[i].url]
                if let match = items[i].selectedMatch {
                    items[i].proposedRelativePath = renameEngine.proposedRelativePath(
                        match: match,
                        trackNumber: items[i].trackNumber,
                        fileExtension: items[i].fileExtension,
                        rule: rule
                    )
                }
            }
        }
    }

    // MARK: - Rename / move

    var includedCount: Int {
        items.filter { $0.isIncluded && $0.proposedRelativePath != nil }.count
    }

    func performRename() async {
        guard !isRenaming, !isMatching else { return }
        refreshProposals()

        let targets = items.indices.filter {
            items[$0].isIncluded && items[$0].proposedRelativePath != nil
        }
        guard !targets.isEmpty else { return }

        isRenaming = true
        renameProgress = 0
        errorMessage = nil
        let isDryRun = dryRun
        var records: [MoveRecord] = []
        var takenLowercased = Set<String>()
        var moved = 0, failed = 0
        var companionsHandled = Set<String>()

        for (progressIndex, index) in targets.enumerated() {
            currentlyProcessing = items[index].filename

            let outcome = renameEngine.apply(
                fileURL: items[index].url,
                relativePath: items[index].proposedRelativePath!,
                outputFolder: outputFolder,
                dryRun: isDryRun,
                copyInsteadOfMove: copyInsteadOfMove,
                takenLowercased: &takenLowercased
            )
            items[index].renameResult = outcome.result
            if let record = outcome.record { records.append(record) }

            switch outcome.result {
            case .moved: moved += 1
            case .failed: failed += 1
            default: break
            }

            // Companion files: move alongside the first file of each source
            // folder that had a real (non-dry-run) move to an output folder.
            if !isDryRun, moveCompanionFiles, outputFolder != nil,
               case .moved(let destinationPath) = outcome.result,
               !companionsHandled.contains(items[index].folderPath) {
                companionsHandled.insert(items[index].folderPath)
                let destinationFolder = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
                for companion in scanner.companionFiles(in: URL(fileURLWithPath: items[index].folderPath)) {
                    let target = destinationFolder.appendingPathComponent(companion.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        if copyInsteadOfMove {
                            try? FileManager.default.copyItem(at: companion, to: target)
                        } else if (try? FileManager.default.moveItem(at: companion, to: target)) != nil {
                            records.append(MoveRecord(source: companion.path, destination: target.path))
                        }
                    }
                }
            }

            renameProgress = Double(progressIndex + 1) / Double(targets.count)
            await Task.yield() // let the UI update the progress bar
        }

        if !isDryRun {
            if !records.isEmpty {
                manifest.save(records)
                canUndoLastMove = true
            }
            if cleanupEmptyFolders, !copyInsteadOfMove, let sourceFolder {
                let removed = renameEngine.removeEmptyDirectories(under: sourceFolder)
                if !removed.isEmpty {
                    statusMessage = "Moved \(moved), failed \(failed) — cleaned \(removed.count) empty folder\(removed.count == 1 ? "" : "s")"
                }
            }
        }

        currentlyProcessing = nil
        isRenaming = false
        renameProgress = 1
        if statusMessage == nil || isDryRun {
            statusMessage = isDryRun
                ? "Preview complete — \(targets.count) file\(targets.count == 1 ? "" : "s") would be processed"
                : "Moved \(moved) file\(moved == 1 ? "" : "s")\(failed > 0 ? ", \(failed) failed" : "")"
        }
    }

    func undoLastMove() async {
        let records = manifest.load()
        guard !records.isEmpty else { return }
        isRenaming = true
        statusMessage = "Undoing last move…"
        let result = await Task.detached(priority: .userInitiated) { [renameEngine] in
            renameEngine.undo(records: records)
        }.value
        manifest.clear()
        canUndoLastMove = false
        isRenaming = false
        statusMessage = "Restored \(result.restored) file\(result.restored == 1 ? "" : "s")\(result.failed > 0 ? " — \(result.failed) could not be restored" : "")"
        await scan()
    }

    // MARK: - Persistence

    private func persistRule() {
        if let data = try? JSONEncoder().encode(rule) {
            UserDefaults.standard.set(data, forKey: Self.ruleDefaultsKey)
        }
        refreshProposals()
    }

    private func restoreRule() {
        if let data = UserDefaults.standard.data(forKey: Self.ruleDefaultsKey),
           let restored = try? JSONDecoder().decode(RenameRule.self, from: data) {
            rule = restored
        }
    }

    private func persistBookmark(for url: URL, key: String) {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func restoreBookmarks() {
        if let url = resolveBookmark(key: Self.outputBookmarkKey) {
            setOutputFolder(url, fromBookmark: true)
        }
        // Source folder intentionally not auto-restored to a scan on launch;
        // resolve it so the picker starts in the right place if wanted.
        if let url = resolveBookmark(key: Self.sourceBookmarkKey) {
            _ = url // available for future "reopen last folder" feature
        }
    }

    private func resolveBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return url
    }
}

/// Thread-safe progress counter across concurrent tasks.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
