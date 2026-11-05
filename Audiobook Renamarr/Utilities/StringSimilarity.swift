import Foundation

nonisolated enum StringSimilarity {
    /// Normalized similarity in 0...1 based on Levenshtein distance over
    /// case/diacritic-folded strings. 1 = identical.
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty && nb.isEmpty { return 1 }
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        let distance = levenshtein(Array(na), Array(nb))
        let maxLen = max(na.count, nb.count)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    /// Fraction of tokens in `a` that also appear in `b` (order-independent).
    /// Useful for author names where ordering and middle names vary.
    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let tokensA = tokens(of: a)
        let tokensB = Set(tokens(of: b))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let matched = tokensA.filter { tokensB.contains($0) }.count
        return Double(matched) / Double(tokensA.count)
    }

    /// Combined title similarity: best of raw string similarity and a
    /// token-set comparison, so word reordering isn't over-penalized.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let raw = similarity(a, b)
        let setA = Set(tokens(of: a))
        let setB = Set(tokens(of: b))
        guard !setA.isEmpty, !setB.isEmpty else { return raw }
        let jaccard = Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
        return max(raw, jaccard)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(of s: String) -> [String] {
        normalize(s)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 || Int($0) != nil } // drop stray single letters, keep digits
            .filter { !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "of", "and", "unabridged", "audiobook"]

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
