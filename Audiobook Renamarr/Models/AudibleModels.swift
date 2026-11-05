import Foundation

// MARK: - API response

nonisolated struct AudibleSearchResponse: Codable {
    let products: [AudibleProduct]
}

nonisolated struct AudibleProduct: Codable, Equatable, Identifiable {
    let asin: String
    let title: String?
    let subtitle: String?
    let authors: [AudiblePerson]?
    let narrators: [AudiblePerson]?
    let series: [AudibleSeries]?
    let releaseDate: String?
    let runtimeLengthMin: Int?
    let publicationName: String?

    var id: String { asin }

    enum CodingKeys: String, CodingKey {
        case asin, title, subtitle, authors, narrators, series
        case releaseDate = "release_date"
        case runtimeLengthMin = "runtime_length_min"
        case publicationName = "publication_name"
    }

    var primaryAuthor: String? { authors?.first?.name }

    var allAuthors: String? {
        guard let authors, !authors.isEmpty else { return nil }
        return authors.map(\.name).joined(separator: ", ")
    }

    var primaryNarrator: String? { narrators?.first?.name }

    var releaseYear: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    var primarySeries: AudibleSeries? { series?.first }

    static func == (lhs: AudibleProduct, rhs: AudibleProduct) -> Bool {
        lhs.asin == rhs.asin
    }
}

nonisolated struct AudiblePerson: Codable {
    let name: String
}

nonisolated struct AudibleSeries: Codable {
    let title: String?
    let sequence: String?

    var sequenceNumber: Int? {
        guard let sequence else { return nil }
        // Sequences can be "2", "2.5", "1-3" — take the leading integer.
        let leading = sequence.prefix { $0.isNumber }
        return Int(leading)
    }
}

// MARK: - Scoring

/// A candidate product with its computed match confidence (0...1).
nonisolated struct ScoredMatch: Equatable, Identifiable {
    let product: AudibleProduct
    let score: Double

    var id: String { product.asin }
    var percent: Int { Int((score * 100).rounded()) }

    static func == (lhs: ScoredMatch, rhs: ScoredMatch) -> Bool {
        lhs.product.asin == rhs.product.asin && lhs.score == rhs.score
    }
}

// MARK: - Errors

nonisolated enum AudibleServiceError: LocalizedError {
    case rateLimited
    case badResponse(status: Int)
    case network(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "Audible is rate limiting — wait a few minutes and try again"
        case .badResponse(let status):
            return "Audible returned an unexpected response (HTTP \(status))"
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        }
    }
}
