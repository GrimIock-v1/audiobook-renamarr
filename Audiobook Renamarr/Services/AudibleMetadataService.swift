import Foundation

/// Abstraction over the metadata source so it can be swapped or mocked.
nonisolated protocol AudibleMetadataSearching: Sendable {
    func search(keywords: String) async throws -> [AudibleProduct]
    func lookup(asin: String) async throws -> AudibleProduct?
}

/// Serializes ALL outbound requests with a true global minimum gap.
/// (Per-task delays with concurrent group searches can still burst; routing
/// everything through this actor guarantees the pacing.)
actor RequestThrottler {
    private var lastRequest: Date = .distantPast
    private let minimumGap: TimeInterval

    init(minimumGap: TimeInterval = 0.5) {
        self.minimumGap = minimumGap
    }

    func waitTurn() async {
        let now = Date()
        let earliest = lastRequest.addingTimeInterval(minimumGap)
        if earliest > now {
            let delay = earliest.timeIntervalSince(now)
            // Claim the slot before sleeping so concurrent callers queue up.
            lastRequest = earliest
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } else {
            lastRequest = now
        }
    }
}

/// Audible's public, unauthenticated catalog search endpoint — the same call
/// audible.com's own search box makes for a signed-out visitor.
nonisolated final class AudibleMetadataService: AudibleMetadataSearching, Sendable {
    private let throttler = RequestThrottler(minimumGap: 0.5)
    private let session: URLSession
    private let baseURL = "https://api.audible.com/1.0/catalog/products"
    private let responseGroups = "contributors,product_desc,product_attrs,series"
    private let userAgent = "AudiobookRenamer/1.0 (personal macOS library organizer; contact via GitHub)"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func search(keywords: String) async throws -> [AudibleProduct] {
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "keywords", value: keywords),
            URLQueryItem(name: "num_results", value: "10"),
            URLQueryItem(name: "products_sort_by", value: "Relevance"),
            URLQueryItem(name: "response_groups", value: responseGroups),
        ]
        let data = try await perform(url: components.url!)
        let decoded = try JSONDecoder().decode(AudibleSearchResponse.self, from: data)
        return decoded.products
    }

    func lookup(asin: String) async throws -> AudibleProduct? {
        var components = URLComponents(string: "\(baseURL)/\(asin)")!
        components.queryItems = [
            URLQueryItem(name: "response_groups", value: responseGroups),
        ]
        struct SingleResponse: Codable { let product: AudibleProduct? }
        let data = try await perform(url: components.url!)
        return try JSONDecoder().decode(SingleResponse.self, from: data).product
    }

    private func perform(url: URL) async throws -> Data {
        await throttler.waitTurn()

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AudibleServiceError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AudibleServiceError.badResponse(status: -1)
        }
        switch http.statusCode {
        case 200: return data
        case 429, 503: throw AudibleServiceError.rateLimited
        default: throw AudibleServiceError.badResponse(status: http.statusCode)
        }
    }
}

/// Extracts an ASIN from a pasted Audible URL or bare ASIN string.
nonisolated enum ASINExtractor {
    static func extract(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare ASIN: 10 alphanumerics starting with B (usually).
        if trimmed.count == 10,
           trimmed.range(of: #"^[A-Z0-9]{10}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.uppercased()
        }
        // URL: .../pd/Title-Audiobook/B0ABCDEFGH or ?asin=...
        if let match = trimmed.range(of: #"(?:/|asin=)(B[A-Z0-9]{9})"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(trimmed[match])
            let asin = matched.suffix(10)
            return String(asin).uppercased()
        }
        return nil
    }
}
