import Foundation

nonisolated struct FolderScanner {
    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus", "alac"
    ]

    nonisolated static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Companion (non-audio) files worth moving with a book.
    nonisolated static let companionExtensions: Set<String> = [
        "jpg", "jpeg", "png", "cue", "nfo", "txt", "pdf", "epub"
    ]

    /// Scans `root` for audio files and returns them as grouped items.
    /// Grouping key = folderPath + book prefix, so multiple books in one flat
    /// folder each get their own group while chapter files stay together.
    func scan(root: URL, includeSubfolders: Bool) -> [AudioFileItem] {
        let fm = FileManager.default
        var audioURLs: [URL] = []

        if includeSubfolders {
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let url = enumerator?.nextObject() as? URL {
                if Self.isSupportedAudioFile(url) { audioURLs.append(url) }
            }
        } else {
            let contents = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            audioURLs = contents.filter(Self.isSupportedAudioFile)
        }

        audioURLs.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        return buildItems(from: audioURLs)
    }

    /// Builds items from explicitly chosen files (drag-in or file picker) —
    /// no directory traversal; only the given files are considered.
    func items(forFiles urls: [URL]) -> [AudioFileItem] {
        let audioURLs = urls
            .filter(Self.isSupportedAudioFile)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return buildItems(from: audioURLs)
    }

    private func buildItems(from audioURLs: [URL]) -> [AudioFileItem] {
        // Group by (folder, prefix). Only strip trailing numbers for grouping
        // when doing so causes ≥2 files to share a prefix — a lone file keeps
        // its full stem so titles like "Fahrenheit 451" survive intact.
        //
        // Second tier: digit skeleton. Files whose stems are identical except
        // for embedded digit runs (e.g. "MGS01-18 Title", "MGS02-18 Title")
        // belong to one book even though prefix-stripping can't see it.
        struct RawEntry { let url: URL; let stem: String; let strippedPrefix: String; let skeleton: String }
        let entries = audioURLs.map { url -> RawEntry in
            let stem = url.deletingPathExtension().lastPathComponent
            return RawEntry(
                url: url,
                stem: stem,
                strippedPrefix: FilenameParser.bookPrefix(stem: stem),
                skeleton: Self.digitSkeleton(stem)
            )
        }

        var prefixCounts: [String: Int] = [:]
        var skeletonCounts: [String: Int] = [:]
        for entry in entries {
            let folder = entry.url.deletingLastPathComponent().path
            prefixCounts[folder + "|" + entry.strippedPrefix, default: 0] += 1
            skeletonCounts[folder + "|#" + entry.skeleton, default: 0] += 1
        }

        var items: [AudioFileItem] = []
        for entry in entries {
            let folderURL = entry.url.deletingLastPathComponent()
            let prefixKey = folderURL.path + "|" + entry.strippedPrefix
            let skeletonKey = folderURL.path + "|#" + entry.skeleton

            let groupKey: String
            if (prefixCounts[prefixKey] ?? 0) >= 2 {
                groupKey = prefixKey
            } else if (skeletonCounts[skeletonKey] ?? 0) >= 2 {
                groupKey = skeletonKey
            } else {
                groupKey = folderURL.path + "|" + entry.stem
            }

            items.append(AudioFileItem(
                url: entry.url,
                folderPath: folderURL.path,
                folderName: folderURL.lastPathComponent,
                groupKey: groupKey,
                parsed: FilenameParser.parse(stem: entry.stem)
            ))
        }

        // Resolve track numbers per group.
        let grouped = Dictionary(grouping: items.indices, by: { items[$0].groupKey })
        for (_, indices) in grouped {
            let urls = indices.map { items[$0].url }
            if urls.count > 1 {
                let resolved = TrackNumberResolver.resolve(sortedURLs: urls)
                for i in indices {
                    items[i].trackNumber = resolved[items[i].url]
                }
            } else if let i = indices.first {
                // Single-file book: only if explicitly present in the filename.
                items[i].trackNumber = items[i].parsed.trackNumber
            }
        }

        return items
    }

    /// Replaces every run of digits with `#`, so stems that differ only in
    /// numbering collapse to the same skeleton.
    /// "MGS01-18 Mira Grant - Symbiont" → "mgs#-# mira grant - symbiont"
    nonisolated static func digitSkeleton(_ stem: String) -> String {
        var out = ""
        var lastWasDigit = false
        for char in stem.precomposedStringWithCanonicalMapping {
            if char.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                out.append(char)
                lastWasDigit = false
            }
        }
        return out.lowercased()
    }

    /// Non-audio companion files sitting in `folder` (top level only).
    func companionFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            Self.companionExtensions.contains($0.pathExtension.lowercased())
        }
    }
}
