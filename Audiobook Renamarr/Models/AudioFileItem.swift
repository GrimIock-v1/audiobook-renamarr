import Foundation

/// The result of attempting to move/rename a single file.
nonisolated enum RenameResult: Equatable {
    case moved(destination: String)
    case dryRun(destination: String)
    case failed(reason: String)
    case skipped
}

/// Where a file stands in the matching pipeline.
nonisolated enum MatchState: Equatable {
    case pending
    case searching
    case matched(confidence: Double)   // >= auto-accept threshold
    case review(confidence: Double)    // needs human review
    case noMatch
    case error(String)
}

/// One audio file discovered during a scan.
nonisolated struct AudioFileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Absolute path of the immediate parent folder — used for section grouping.
    let folderPath: String
    /// Display name of the immediate parent folder.
    let folderName: String
    /// Group key: files with the same key are treated as one book.
    var groupKey: String
    var parsed: ParsedFilename
    /// Metadata read from embedded tags (ID3 / MP4), if any.
    var tags: EmbeddedTags?
    /// Resolved track number within its group (nil for untracked single files).
    var trackNumber: Int?
    var isIncluded: Bool = false
    var matchState: MatchState = .pending
    /// Ranked candidates from the last search.
    var candidates: [ScoredMatch] = []
    /// The match currently applied (either auto-accepted or user-selected).
    var selectedMatch: ScoredMatch?
    var proposedRelativePath: String?
    var renameResult: RenameResult?

    var filename: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    static func == (lhs: AudioFileItem, rhs: AudioFileItem) -> Bool {
        lhs.id == rhs.id
            && lhs.matchState == rhs.matchState
            && lhs.isIncluded == rhs.isIncluded
            && lhs.selectedMatch?.product.asin == rhs.selectedMatch?.product.asin
            && lhs.proposedRelativePath == rhs.proposedRelativePath
            && lhs.renameResult == rhs.renameResult
            && lhs.candidates.count == rhs.candidates.count
    }
}

/// Metadata extracted from embedded audio tags.
nonisolated struct EmbeddedTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var trackNumber: Int?
    var durationSeconds: Double?
}
