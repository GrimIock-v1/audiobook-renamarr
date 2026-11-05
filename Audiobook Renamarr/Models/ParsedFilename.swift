import Foundation

/// Best-effort structured guess extracted from an audio file's name.
struct ParsedFilename: Equatable {
    var titleGuess: String
    var authorGuess: String? = nil
    var seriesGuess: String? = nil
    var seriesNumberGuess: String? = nil
    var narratorGuess: String? = nil
    var trackNumber: Int? = nil

    /// The string actually sent to the search service.
    var searchQuery: String {
        [titleGuess, seriesGuess]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
