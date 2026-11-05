import Foundation

/// Parses filenames and folder names into structured book metadata.
///
/// Parse order (each step feeds the next):
/// 1. Capture `[02]`-style leading bracket numbers BEFORE bracket stripping
/// 2. Strip narrator: `narrated by X`, `read by X`
/// 3. Strip brackets `[...]`, parentheses `(...)`, braces `{...}`
/// 4. Strip leading chapter prefix: `Chapter 1 -`, `01 -`, `Part 2 -`
/// 5. Strip trailing standalone number (< 500, to avoid year confusion)
/// 6. Strip standalone year segments: ` - 1982 -`, ` - 2003`
/// 7. Collapse whitespace
/// 8. Split on ` - ` → author/title in both conventions
/// 9. Detect series markers: `Book 2`, `Vol. 2`, `#3`
nonisolated enum FilenameParser {

    static func parse(stem rawStem: String) -> ParsedFilename {
        var stem = rawStem.precomposedStringWithCanonicalMapping
        var result = ParsedFilename(title: rawStem)

        // 1. Leading bracket track number, e.g. "[02] Title".
        if let match = firstMatch(in: stem, pattern: #"^\s*\[(\d{1,3})\]"#),
           let n = Int(match.captured) {
            result.trackNumber = n
        }

        // 2. Narrator.
        if let match = firstMatch(in: stem, pattern: #"(?:narrated by|read by)\s+([^\-\[\](){}]+)"#, options: [.caseInsensitive]) {
            result.narrator = match.captured.trimmingCharacters(in: .whitespaces)
            stem.removeSubrange(match.fullRange)
        }

        // 3. Brackets / parens / braces.
        stem = stem.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#, with: " ", options: .regularExpression)

        // 4. Leading chapter/part/track prefix.
        if let match = firstMatch(in: stem, pattern: #"^\s*(?:chapter|part|track)?\s*0*(\d{1,4})\s*[-–.]\s*"#, options: [.caseInsensitive]),
           let n = Int(match.captured) {
            if result.trackNumber == nil, !(1900...2099).contains(n) || match.captured.count < 4 {
                result.trackNumber = n
            }
            stem.removeSubrange(match.fullRange)
        }

        // 5. Trailing standalone number (< 500 to avoid year confusion).
        if let match = firstMatch(in: stem, pattern: #"[-–\s]+0*(\d{1,3})\s*$"#),
           let n = Int(match.captured), n < 500 {
            if result.trackNumber == nil { result.trackNumber = n }
            stem.removeSubrange(match.fullRange)
        }

        // 6. Standalone year segments.
        if let match = firstMatch(in: stem, pattern: #"(?:^|\s[-–]\s)\s*((?:19|20)\d{2})\s*(?=\s[-–]\s|$)"#),
           let year = Int(match.captured) {
            result.year = year
            stem.removeSubrange(match.fullRange)
        }

        // 7. Collapse whitespace.
        stem = collapse(stem)

        // 9 (before splitting so the marker stays attached to its segment).
        if let match = firstMatch(in: stem, pattern: #"(?:book|vol\.?|volume|#)\s*(\d{1,2})"#, options: [.caseInsensitive]),
           let n = Int(match.captured) {
            result.seriesNumber = n
        }

        // 8. Split on " - " into author/title.
        let segments = stem
            .components(separatedBy: " - ")
            .map { collapse($0) }
            .filter { !$0.isEmpty }

        switch segments.count {
        case 0:
            result.title = collapse(rawStem)
        case 1:
            result.title = segments[0]
        case 2:
            // Assume "Author - Title" as primary; the search layer also tries
            // the swapped "Title - Author" interpretation.
            result.author = normalizeAuthor(segments[0])
            result.title = segments[1]
        default:
            // "Author - Series - Title" or "Author - Title - extra"
            result.author = normalizeAuthor(segments[0])
            result.seriesName = segments.count >= 3 ? segments[1] : nil
            result.title = segments.last ?? segments[1]
        }

        if result.title.isEmpty { result.title = collapse(rawStem) }
        return result
    }

    /// Parses a folder name like
    /// `Allende, Isabel - The House of the Spirits - 1982 - read by Narrator`.
    static func parseFolderName(_ name: String) -> ParsedFilename {
        parse(stem: name)
    }

    /// Converts "Lastname, Firstname" → "Firstname Lastname".
    static func normalizeAuthor(_ raw: String) -> String {
        let parts = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
           parts[1].components(separatedBy: " ").count <= 2 {
            return "\(parts[1]) \(parts[0])"
        }
        return raw
    }

    // MARK: - Grouping prefix

    /// The book prefix used for grouping: the stem with trailing
    /// numbers/chapter markers stripped.
    static func bookPrefix(stem: String) -> String {
        var s = stem.precomposedStringWithCanonicalMapping

        // Trailing "chapter N" / "part N" / "track N".
        s = s.replacingOccurrences(
            of: #"[\s\-–_]*(?:chapter|part|track)\s*\d{1,4}\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])

        // Trailing " - N" or trailing bare number.
        s = s.replacingOccurrences(
            of: #"[\s\-–_]+\d{1,4}\s*$"#,
            with: "", options: .regularExpression)

        // Middle track-number segments: "Title - 001 - Chapter" → "Title".
        if let range = s.range(of: #"\s[-–]\s0*\d{1,4}\s[-–]\s.*$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }

        s = collapse(s)
        return s.isEmpty ? collapse(stem) : s
    }

    // MARK: - Helpers

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–_."))
    }

    private struct Match {
        let fullRange: Range<String.Index>
        let captured: String
    }

    private static func firstMatch(in string: String, pattern: String, options: NSRegularExpression.Options = []) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = string as NSString
        guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              let full = Range(m.range, in: string) else { return nil }
        var captured = ""
        if m.numberOfRanges > 1, let capRange = Range(m.range(at: 1), in: string) {
            captured = String(string[capRange])
        }
        return Match(fullRange: full, captured: captured)
    }
}
