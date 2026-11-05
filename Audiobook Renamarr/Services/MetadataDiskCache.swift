import Foundation

/// Codable snapshot of a scored match for disk persistence.
nonisolated struct CodableMatch: Codable {
    let product: AudibleProduct
    let score: Double

    init(_ match: ScoredMatch) {
        product = match.product
        score = match.score
    }

    var scoredMatch: ScoredMatch { ScoredMatch(product: product, score: score) }
}

/// Disk half of the two-level cache. Flat JSON: `[String: [CodableMatch]]`
/// at `~/Library/Caches/AudiobookRenamer/metadata_cache.json`.
///
/// `@unchecked Sendable`: all I/O and dictionary access is serialized on a
/// private DispatchQueue.
nonisolated final class MetadataDiskCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MetadataDiskCache.io")
    private var store: [String: [CodableMatch]] = [:]
    private let fileURL: URL

    init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudiobookRenamer", isDirectory: true)
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        fileURL = cachesDir.appendingPathComponent("metadata_cache.json")

        // Load on init — synchronous, happens once.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [CodableMatch]].self, from: data) {
            store = decoded
        }
    }

    func lookup(key: String) -> [ScoredMatch]? {
        queue.sync { store[key]?.map(\.scoredMatch) }
    }

    func save(key: String, matches: [ScoredMatch]) {
        // Fire-and-forget on the background queue.
        queue.async { [weak self] in
            guard let self else { return }
            self.store[key] = matches.map(CodableMatch.init)
            if let data = try? JSONEncoder().encode(self.store) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.store.removeAll()
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
}

/// In-memory half of the cache (this session), plus the gateway that
/// consults disk before allowing a network search.
actor MetadataCache {
    private var memory: [String: [ScoredMatch]] = [:]
    private let disk = MetadataDiskCache()

    func lookup(key: String) -> [ScoredMatch]? {
        if let hit = memory[key] { return hit }
        if let hit = disk.lookup(key: key) {
            memory[key] = hit
            return hit
        }
        return nil
    }

    func save(key: String, matches: [ScoredMatch]) {
        memory[key] = matches
        disk.save(key: key, matches: matches)
    }

    func clearAll() {
        memory.removeAll()
        disk.clear()
    }
}
