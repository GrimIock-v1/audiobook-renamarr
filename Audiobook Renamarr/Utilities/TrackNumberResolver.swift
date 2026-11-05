import Foundation

/// Identifies which number in a set of filenames represents the track
/// ordering by finding the number position that forms a complete,
/// unbroken sequential set across all files.
///
/// Example:
///   "The House of the Spirits - 001 - Chapter 1.mp3"  → numbers: [1, 1]
///   "The House of the Spirits - 002 - Epigraph.mp3"   → numbers: [2]
///   "The House of the Spirits - 003 - Chapter 2.mp3"  → numbers: [3, 2]
///   ...
///   "The House of the Spirits - 016 - Chapter 14.mp3" → numbers: [16, 14]
///   "The House of the Spirits - 017 - Epilogue.mp3"   → numbers: [17]
///   "The House of the Spirits - 018 - Close.mp3"      → numbers: [18]
///
///   Position 0 values: [1,2,3,4,5,...,18] → complete sequence ✅ → track numbers
///   Position 1 values: [1,2,3,...,14, missing, missing] → incomplete ❌
///
enum TrackNumberResolver {

    /// Given a sorted list of file URLs in a group, returns a dictionary
    /// mapping each URL to its resolved track number.
    ///
    /// If no sequential number is found, falls back to sort-position (1-based).
    static func resolve(sortedURLs: [URL]) -> [URL: Int] {
        guard sortedURLs.count > 1 else {
            // Single file — no sequence to check.
            // Return whatever the filename parser found, or nil.
            let parsed = FilenameParser.parse(sortedURLs[0], assumeTitleFirst: false)
            return [sortedURLs[0]: parsed.trackNumber ?? 1]
        }

        // Extract all numbers from each filename, in left-to-right order.
        let allNumbers: [[Int]] = sortedURLs.map { numbersInFilename($0) }

        // Find the maximum number of numeric positions across all files.
        let maxPositions = allNumbers.map(\.count).max() ?? 0

        // Check each position to see if it forms a valid sequence.
        // A valid sequence: present in every file AND the values form
        // a set of distinct integers that are consecutive (no gaps).
        var bestPosition: Int? = nil
        var bestValues: [Int] = []

        for position in 0..<maxPositions {
            // Collect values at this position — skip files that don't
            // have a number at this position.
            let values = allNumbers.compactMap { nums -> Int? in
                position < nums.count ? nums[position] : nil
            }

            guard values.count == sortedURLs.count else {
                // Not present in every file — can't be the track number.
                continue
            }

            guard Set(values).count == values.count else {
                // Duplicate values — not a sequence (e.g. series number
                // repeated across all files).
                continue
            }

            let sorted = values.sorted()
            let isConsecutive = zip(sorted, sorted.dropFirst()).allSatisfy { $1 - $0 == 1 }
            guard isConsecutive else { continue }

            // Valid sequence found. Prefer zero-padded positions (earlier
            // in the filename) when multiple qualify.
            if bestPosition == nil {
                bestPosition = position
                bestValues   = values
            }
        }

        if let _ = bestPosition {
            // Map each URL to its resolved track number.
            var result: [URL: Int] = [:]
            for (index, url) in sortedURLs.enumerated() {
                result[url] = bestValues[index]
            }
            return result
        }

        // No clean sequence found — fall back to sort position (1-based).
        var result: [URL: Int] = [:]
        for (index, url) in sortedURLs.enumerated() {
            // Try to use whatever the individual parser found first.
            let parsed = FilenameParser.parse(url, assumeTitleFirst: false)
            result[url] = parsed.trackNumber ?? (index + 1)
        }
        return result
    }

    /// Extracts all non-year integers from a filename stem, left to right.
    /// Years (1900–2099) are excluded since they are never track numbers.
    private static func numbersInFilename(_ url: URL) -> [Int] {
        let stem = url.deletingPathExtension().lastPathComponent

        // Find all runs of digits in the filename.
        var numbers: [Int] = []
        let pattern = #"\d+"#
        var searchRange = stem.startIndex..<stem.endIndex

        while let range = stem.range(of: pattern, options: .regularExpression, range: searchRange) {
            let digits = String(stem[range])
            if let n = Int(digits) {
                // Skip 4-digit years.
                let isYear = digits.count == 4 && (n >= 1900 && n <= 2099)
                if !isYear {
                    numbers.append(n)
                }
            }
            searchRange = range.upperBound..<stem.endIndex
        }

        return numbers
    }
}
