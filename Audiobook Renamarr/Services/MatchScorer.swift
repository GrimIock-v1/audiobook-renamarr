import Foundation

/// Scores Audible candidates against parsed/tag signals.
///
/// Base score: title similarity 70% + author token overlap 30%,
/// plus a small series bonus and a duration cross-check adjustment.
/// Thresholds: auto-accept ≥ 0.72, review 0.45–0.72, exclude < 0.45.
nonisolated struct MatchScorer {
    static let autoAcceptThreshold = 0.72
    static let reviewThreshold = 0.45

    struct Query {
        var title: String
        var author: String?
        var seriesNumber: Int?
        /// Sum of the group's file durations, if known (seconds).
        var totalDurationSeconds: Double?
    }

    func score(products: [AudibleProduct], against query: Query) -> [ScoredMatch] {
        products
            .map { ScoredMatch(product: $0, score: score(product: $0, against: query)) }
            .filter { $0.score >= Self.reviewThreshold }
            .sorted { $0.score > $1.score }
    }

    func score(product: AudibleProduct, against query: Query) -> Double {
        let productTitle = [product.title, product.subtitle]
            .compactMap { $0 }
            .joined(separator: " ")

        var titleScore = StringSimilarity.titleSimilarity(query.title, product.title ?? "")
        // Subtitle sometimes carries the real distinguishing text.
        if !productTitle.isEmpty {
            titleScore = max(titleScore, StringSimilarity.titleSimilarity(query.title, productTitle))
        }

        let authorScore: Double
        if let author = query.author, let productAuthor = product.allAuthors {
            authorScore = max(
                StringSimilarity.tokenOverlap(author, productAuthor),
                StringSimilarity.tokenOverlap(productAuthor, author)
            )
        } else {
            // No author signal — score on title alone at a mild discount so a
            // perfect title match without an author can still auto-accept.
            authorScore = titleScore * 0.85
        }

        var score = titleScore * 0.70 + authorScore * 0.30

        // Small series bonus when the sequence number lines up.
        if let wanted = query.seriesNumber,
           let sequence = product.primarySeries?.sequenceNumber,
           wanted == sequence {
            score += 0.05
        }

        // Duration cross-check: strong disambiguator for abridged vs.
        // unabridged editions and dramatizations.
        if let localSeconds = query.totalDurationSeconds,
           let runtimeMin = product.runtimeLengthMin, runtimeMin > 0 {
            let localMin = localSeconds / 60
            let ratio = localMin / Double(runtimeMin)
            if (0.92...1.08).contains(ratio) {
                score += 0.05
            } else if ratio < 0.6 || ratio > 1.6 {
                score -= 0.10
            }
        }

        return min(max(score, 0), 1)
    }
}
