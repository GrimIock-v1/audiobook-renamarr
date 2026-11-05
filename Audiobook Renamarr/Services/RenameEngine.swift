import Foundation

/// A single recorded move, for the undo manifest.
nonisolated struct MoveRecord: Codable {
    let source: String
    let destination: String
}

/// Persists the last real move batch so it can be undone.
/// Stored at `~/Library/Application Support/AudiobookRenamer/last_move.json`.
nonisolated final class MoveManifest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MoveManifest.io")
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudiobookRenamer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("last_move.json")
    }

    var hasManifest: Bool {
        queue.sync { FileManager.default.fileExists(atPath: fileURL.path) }
    }

    func save(_ records: [MoveRecord]) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(records) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func load() -> [MoveRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder().decode([MoveRecord].self, from: data)
            else { return [] }
            return records
        }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}

nonisolated struct RenameEngine {
    /// Pure — never touches disk. Builds the proposed relative path
    /// (possibly containing folder separators) for one file.
    func proposedRelativePath(
        match: ScoredMatch,
        trackNumber: Int?,
        fileExtension: String,
        rule: RenameRule
    ) -> String {
        let product = match.product
        let context = RenameRule.TokenContext(
            author: product.allAuthors,
            title: product.title,
            subtitle: product.subtitle,
            series: product.primarySeries?.title,
            seriesNumber: product.primarySeries?.sequenceNumber,
            narrator: product.primaryNarrator,
            year: product.releaseYear,
            ext: fileExtension,
            trackNumber: trackNumber
        )
        return rule.render(context: context)
    }

    struct MoveOutcome {
        let result: RenameResult
        let record: MoveRecord?
    }

    /// Executes (or previews) one move. `outputFolder == nil` means rename
    /// in place within the file's current folder.
    ///
    /// - Parameter takenLowercased: destination paths already claimed in this
    ///   batch, lowercased (APFS is case-insensitive by default).
    func apply(
        fileURL: URL,
        relativePath: String,
        outputFolder: URL?,
        dryRun: Bool,
        copyInsteadOfMove: Bool,
        takenLowercased: inout Set<String>
    ) -> MoveOutcome {
        let baseFolder = outputFolder ?? fileURL.deletingLastPathComponent()

        // Resolve collisions against both the batch and the filesystem.
        var components = relativePath.components(separatedBy: "/")
        let filename = components.removeLast()
        let containingFolder = components.reduce(baseFolder) { $0.appendingPathComponent($1, isDirectory: true) }

        func isTaken(_ name: String) -> Bool {
            let full = containingFolder.appendingPathComponent(name).path
            if full == fileURL.path { return false } // renaming onto itself is fine
            return FileManager.default.fileExists(atPath: full)
                || takenLowercased.contains(full.lowercased())
        }

        var candidate = filename
        if isTaken(candidate) {
            let ext = (filename as NSString).pathExtension
            let stem = (filename as NSString).deletingPathExtension
            var counter = 2
            repeat {
                candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
                counter += 1
            } while isTaken(candidate)
        }

        let destination = containingFolder.appendingPathComponent(candidate)
        takenLowercased.insert(destination.path.lowercased())

        if destination.path == fileURL.path {
            return MoveOutcome(result: .skipped, record: nil)
        }

        if dryRun {
            return MoveOutcome(result: .dryRun(destination: destination.path), record: nil)
        }

        do {
            try FileManager.default.createDirectory(
                at: containingFolder,
                withIntermediateDirectories: true
            )
            if copyInsteadOfMove {
                try FileManager.default.copyItem(at: fileURL, to: destination)
            } else {
                try FileManager.default.moveItem(at: fileURL, to: destination)
            }
            let record = copyInsteadOfMove
                ? nil // copies don't need undo — the source is untouched
                : MoveRecord(source: fileURL.path, destination: destination.path)
            return MoveOutcome(result: .moved(destination: destination.path), record: record)
        } catch {
            return MoveOutcome(result: .failed(reason: error.localizedDescription), record: nil)
        }
    }

    /// Reverses a batch of recorded moves. Returns (restored, failed) counts.
    func undo(records: [MoveRecord]) -> (restored: Int, failed: Int) {
        var restored = 0
        var failed = 0
        for record in records.reversed() {
            let src = URL(fileURLWithPath: record.destination)
            let dst = URL(fileURLWithPath: record.source)
            do {
                try FileManager.default.createDirectory(
                    at: dst.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: src, to: dst)
                restored += 1
            } catch {
                failed += 1
            }
        }
        return (restored, failed)
    }

    /// Deletes now-empty directories under `root` (deepest first).
    /// Returns the paths removed.
    func removeEmptyDirectories(under root: URL) -> [String] {
        let fm = FileManager.default
        var directories: [URL] = []
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }
        var removed: [String] = []
        for dir in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let visible = contents.filter { $0 != ".DS_Store" }
            if visible.isEmpty {
                try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store"))
                if (try? fm.removeItem(at: dir)) != nil {
                    removed.append(dir.path)
                }
            }
        }
        return removed
    }
}
