import Foundation

/// Resolves track numbers for a multi-file book group using a sequential
/// consistency check: the number "position" whose values form a complete,
/// unbroken sequence across ALL files is the track number.
///
/// Example — 18 files named `The House of the Spirits - 001 - Chapter 1.mp3`
/// where chapters only go to 14: the `001...018` sequence wins; chapter
/// numbers (incomplete positions) are ignored.
nonisolated enum TrackNumberResolver {
    /// - Parameter sortedURLs: the group's files, sorted by filename.
    /// - Returns: a mapping of URL → track number.
    static func resolve(sortedURLs: [URL]) -> [URL: Int] {
        guard sortedURLs.count > 1 else {
            // Single-file books: only use a track number if one was explicitly
            // in the filename — never invent one. Handled by FilenameParser.
            return [:]
        }

        // 1. Extract all numbers from every filename (left → right),
        //    excluding 4-digit years 1900–2099.
        let numberLists: [[Int]] = sortedURLs.map { extractNumbers(from: $0.deletingPathExtension().lastPathComponent) }

        // 2. For each number position, check sequential completeness.
        let minPositions = numberLists.map(\.count).min() ?? 0
        var winningPosition: Int? = nil

        for position in 0..<minPositions {
            let values = numberLists.map { $0[position] }
            if isCompleteSequence(values) {
                winningPosition = position
                break // 4. prefer the first (leftmost) qualifying position
            }
        }

        var result: [URL: Int] = [:]
        if let position = winningPosition {
            for (index, url) in sortedURLs.enumerated() {
                result[url] = numberLists[index][position]
            }
        } else {
            // 5. Fall back to sort position (1-based).
            for (index, url) in sortedURLs.enumerated() {
                result[url] = index + 1
            }
        }
        return result
    }

    /// All integers in the string, in order, excluding likely years.
    static func extractNumbers(from string: String) -> [Int] {
        var numbers: [Int] = []
        var current = ""
        for char in string {
            if char.isNumber {
                current.append(char)
            } else if !current.isEmpty {
                appendIfNotYear(current, to: &numbers)
                current = ""
            }
        }
        if !current.isEmpty { appendIfNotYear(current, to: &numbers) }
        return numbers
    }

    private static func appendIfNotYear(_ digits: String, to numbers: inout [Int]) {
        guard let value = Int(digits) else { return }
        let isYear = digits.count == 4 && (1900...2099).contains(value)
        if !isYear { numbers.append(value) }
    }

    /// True when the values form a complete unbroken run with no duplicates
    /// (in any order), e.g. [3,1,2] → yes; [1,2,4] → no; [1,1,2] → no.
    private static func isCompleteSequence(_ values: [Int]) -> Bool {
        guard let minValue = values.min(), let maxValue = values.max() else { return false }
        let unique = Set(values)
        return unique.count == values.count
            && maxValue - minValue + 1 == values.count
    }
}
