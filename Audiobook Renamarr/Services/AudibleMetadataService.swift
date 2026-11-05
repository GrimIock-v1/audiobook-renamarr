import Foundation

protocol AudibleMetadataSearching {
    func search(parsed: ParsedFilename) async throws -> [AudibleMatch]
}

final class AudibleMetadataService: AudibleMetadataSearching {

    private let session: URLSession
    private let baseURL = URL(string: "https://api.audible.com/1.0/catalog/products")!
    private let maxResults: Int
    private let requestDelay: UInt64

    init(session: URLSession = .shared, maxResults: Int = 10, requestDelayMs: UInt64 = 500) {
        self.session = session
        self.maxResults = maxResults
        self.requestDelay = requestDelayMs * 1_000_000
    }

    func search(parsed: ParsedFilename) async throws -> [AudibleMatch] {
        var keywords = parsed.titleGuess
        if let author = parsed.authorGuess, !author.isEmpty {
            keywords += " \(author)"
        }
        return try await rawSearch(keywords: keywords)
    }

    private func rawSearch(keywords: String) async throws -> [AudibleMatch] {
        try await Task.sleep(nanoseconds: requestDelay)

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MetadataError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "keywords", value: keywords),
            URLQueryItem(name: "num_results", value: String(maxResults)),
            URLQueryItem(name: "products_sort_by", value: "Relevance"),
            URLQueryItem(name: "response_groups", value: "contributors,product_desc,product_attrs,series"),
        ]
        guard let url = components.url else { throw MetadataError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("AudiobookRenamer/1.0 (personal use; macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MetadataError.badResponse
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 429, 503:
            throw MetadataError.rateLimited
        default:
            throw MetadataError.httpStatus(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(AudibleCatalogResponse.self, from: data)
            return (decoded.products ?? []).compactMap(AudibleMatch.init)
        } catch {
            throw MetadataError.decodingFailed(error)
        }
    }
}

enum MetadataError: LocalizedError {
    case invalidURL
    case badResponse
    case httpStatus(Int)
    case rateLimited
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:       return "Could not build a search URL."
        case .badResponse:      return "Audible returned an unexpected response."
        case .httpStatus(let c): return "Audible search failed (HTTP \(c))."
        case .rateLimited:      return "Rate limited — please wait a few minutes and try again."
        case .decodingFailed:   return "Could not understand Audible\u{2019}s search response."
        }
    }
}

/// Two-level cache: memory (this session) + disk (across sessions).
/// The disk cache is accessed only from within this actor's executor,
/// so no extra synchronisation is needed.
actor MetadataCache {
    private var memory: [String: [AudibleMatch]] = [:]
    private let disk = MetadataDiskCache()

    func cachedResult(for key: String) -> [AudibleMatch]? {
        if let hit = memory[key] { return hit }
        if let hit = disk.load(for: key) {
            memory[key] = hit
            return hit
        }
        return nil
    }

    func store(_ results: [AudibleMatch], for key: String) {
        memory[key] = results
        disk.save(results, for: key)
    }
}
