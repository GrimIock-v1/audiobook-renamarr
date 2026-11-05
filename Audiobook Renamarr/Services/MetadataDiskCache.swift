import Foundation

/// Persists Audible search results to disk so the same book is never
/// looked up twice across sessions.
///
/// All file I/O is dispatched to a background queue so it never blocks
/// the main actor or triggers Swift concurrency warnings.
final class MetadataDiskCache: @unchecked Sendable {

    private let cacheURL: URL
    private let queue = DispatchQueue(label: "com.audiobookrenamer.diskcache", qos: .utility)
    private var store: [String: [CodableMatch]] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("AudiobookRenamer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("metadata_cache.json")
        // Load synchronously once at init time — happens on whatever thread
        // constructs this object (the MetadataCache actor's executor).
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: [CodableMatch]].self, from: data) {
            store = decoded
        }
    }

    func load(for key: String) -> [AudibleMatch]? {
        store[key].map { $0.map(\.match) }
    }

    func save(_ results: [AudibleMatch], for key: String) {
        store[key] = results.map(CodableMatch.init)
        // Write to disk in the background — fire and forget.
        let snapshot = store
        let url = cacheURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Codable bridge

private struct CodableMatch: Codable {
    let asin: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let narrators: [String]
    let seriesTitle: String?
    let seriesSequence: String?
    let releaseYear: String?

    init(_ match: AudibleMatch) {
        asin           = match.asin
        title          = match.title
        subtitle       = match.subtitle
        authors        = match.authors
        narrators      = match.narrators
        seriesTitle    = match.seriesTitle
        seriesSequence = match.seriesSequence
        releaseYear    = match.releaseYear
    }

    var match: AudibleMatch {
        AudibleMatch(
            asin:           asin,
            title:          title,
            subtitle:       subtitle,
            authors:        authors,
            narrators:      narrators,
            seriesTitle:    seriesTitle,
            seriesSequence: seriesSequence,
            releaseYear:    releaseYear
        )
    }
}
