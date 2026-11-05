import Foundation

enum FilenameParser {

    static func parse(_ url: URL, assumeTitleFirst: Bool = false) -> ParsedFilename {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: "_", with: " ")

        var narrator: String?
        var trackNumber: Int?

        // ── Capture [02] style bracket numbers BEFORE stripping brackets ──
        // Common in chapter files: "[02] Chapter 1 - The Hook"
        // Must happen first so the number isn't lost when brackets are stripped.
        if let range = name.range(of: #"^\s*\[0*(\d{1,4})\]\s*"#, options: .regularExpression) {
            let segment = String(name[range])
            let digits = segment.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            trackNumber = Int(String(String.UnicodeScalarView(digits)))
        }

        // ── Strip narrator ──
        if let range = name.range(of: #"(?i)(narrated|read)\s+by\s+([^\-\[\(]+)"#, options: .regularExpression) {
            let matched = String(name[range])
            if let nameRange = matched.range(of: #"(?i)(narrated|read)\s+by\s+"#, options: .regularExpression) {
                narrator = String(matched[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            name.removeSubrange(range)
        }

        // ── Strip bracketed/parenthesized content ──
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)

        // ── Strip leading chapter/part/track prefix ──
        // e.g. "Chapter 1 - The Hook" → "The Hook", trackNumber = 1
        // e.g. "01 - Title" → "Title", trackNumber = 1
        if let range = name.range(
            of: #"^\s*(track|chapter|part|disc|disk|episode)?\s*0*(\d{1,4})\s*[-.\s]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let segment = String(name[range])
            let digits = segment.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            // Only overwrite track number if we didn't already get one from brackets.
            if trackNumber == nil {
                trackNumber = Int(String(String.UnicodeScalarView(digits)))
            }
            name.removeSubrange(range)
        }

        // ── Strip trailing standalone number ──
        if trackNumber == nil,
           let range = name.range(of: #"\s*[-\s]\s*0*(\d{1,4})\s*$"#, options: .regularExpression) {
            let segment = String(name[range])
            let digits = segment.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            if let n = Int(String(String.UnicodeScalarView(digits))), n < 500 {
                trackNumber = n
                name.removeSubrange(range)
            }
        }

        name = collapseWhitespace(name)

        // ── Strip standalone year segments ──
        // Folder names often include a year like "Title - 1982 - read by X".
        // After narrator and bracket stripping this can leave " - 1982 - "
        // which causes the year to be parsed as the title. Strip it.
        name = name.replacingOccurrences(
            of: #"\s*-\s*(19|20)\d{2}\s*(?=-|$)"#,
            with: "",
            options: .regularExpression
        )
        name = collapseWhitespace(name)

        // ── Split on " - " to find title / author / series ──
        let parts = name.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var titleGuess = name
        var authorGuess: String?
        var seriesGuess: String?
        var seriesNumberGuess: String?

        switch parts.count {
        case 0:
            titleGuess = name
        case 1:
            titleGuess = parts[0]
        case 2:
            if assumeTitleFirst {
                titleGuess  = parts[0]
                authorGuess = parts[1]
            } else {
                authorGuess = parts[0]
                titleGuess  = parts[1]
            }
        default:
            authorGuess = parts[0]
            titleGuess  = parts.last!
            let middle  = parts[1..<parts.count - 1].joined(separator: " - ")
            let (series, number) = extractSeriesAndNumber(from: middle)
            seriesGuess       = series ?? (middle.isEmpty ? nil : middle)
            seriesNumberGuess = number
        }

        if seriesGuess == nil {
            let (series, number) = extractSeriesAndNumber(from: titleGuess)
            if let series {
                seriesGuess = series
                if let number { seriesNumberGuess = number }
            }
        }

        return ParsedFilename(
            titleGuess: titleGuess,
            authorGuess: authorGuess,
            seriesGuess: seriesGuess,
            seriesNumberGuess: seriesNumberGuess,
            narratorGuess: narrator,
            trackNumber: trackNumber
        )
    }

    private static func extractSeriesAndNumber(from text: String) -> (series: String?, number: String?) {
        let pattern = #"(?i)\b(book|vol\.?|volume|#|part)\s*0*(\d{1,3})\b"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return (nil, nil)
        }
        let matched = String(text[range])
        let number = matched.range(of: #"\d{1,3}"#, options: .regularExpression)
            .map { String(matched[$0]) }

        var series = text
        series.removeSubrange(range)
        series = collapseWhitespace(series.trimmingCharacters(in: CharacterSet(charactersIn: ", -")))
        return (series.isEmpty ? nil : series, number)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
