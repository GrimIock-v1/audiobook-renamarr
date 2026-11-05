import Foundation

/// The structured interpretation of a filename or folder name.
nonisolated struct ParsedFilename: Equatable {
    /// Best-guess title (always populated, falls back to cleaned stem).
    var title: String
    var author: String?
    var narrator: String?
    var seriesName: String?
    var seriesNumber: Int?
    var trackNumber: Int?
    var year: Int?

    /// The alternate interpretation with author/title swapped, when the
    /// filename used a `X - Y` convention and we can't be sure which is which.
    var swappedInterpretation: (title: String, author: String?)? {
        guard let author, !author.isEmpty else { return nil }
        return (title: author, author: title)
    }

    static func == (lhs: ParsedFilename, rhs: ParsedFilename) -> Bool {
        lhs.title == rhs.title
            && lhs.author == rhs.author
            && lhs.narrator == rhs.narrator
            && lhs.seriesName == rhs.seriesName
            && lhs.seriesNumber == rhs.seriesNumber
            && lhs.trackNumber == rhs.trackNumber
            && lhs.year == rhs.year
    }
}
