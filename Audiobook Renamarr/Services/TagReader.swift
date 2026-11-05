import Foundation
import AVFoundation

/// Reads embedded ID3 / MP4 metadata. Tags, when present, are a stronger
/// search signal than filename parsing and a more reliable track source.
nonisolated struct TagReader {
    func readTags(from url: URL) async -> EmbeddedTags? {
        let asset = AVURLAsset(url: url)
        var tags = EmbeddedTags()

        do {
            let metadata = try await asset.load(.metadata)
            let common = try await asset.load(.commonMetadata)

            tags.title = await stringValue(in: common, key: .commonKeyTitle)
            tags.artist = await stringValue(in: common, key: .commonKeyArtist)
            tags.album = await stringValue(in: common, key: .commonKeyAlbumName)
            tags.trackNumber = await trackNumber(in: metadata)

            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 { tags.durationSeconds = seconds }
            }
        } catch {
            return nil
        }

        let hasAnything = tags.title != nil || tags.artist != nil
            || tags.album != nil || tags.trackNumber != nil || tags.durationSeconds != nil
        return hasAnything ? tags : nil
    }

    private func stringValue(in items: [AVMetadataItem], key: AVMetadataKey) async -> String? {
        let matches = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common)
        guard let item = matches.first else { return nil }
        let value = try? await item.load(.stringValue)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func trackNumber(in items: [AVMetadataItem]) async -> Int? {
        // ID3: TRCK is a string like "3" or "3/12".
        if let item = AVMetadataItem.metadataItems(
            from: items, filteredByIdentifier: .id3MetadataTrackNumber).first,
           let raw = try? await item.load(.stringValue) {
            let leading = raw.prefix { $0.isNumber }
            if let n = Int(leading), n > 0 { return n }
        }

        // MP4/iTunes: 'trkn' is binary — track number lives in bytes 2–3 (BE).
        if let item = AVMetadataItem.metadataItems(
            from: items, filteredByIdentifier: .iTunesMetadataTrackNumber).first {
            if let number = try? await item.load(.numberValue),
               number.intValue > 0 {
                return number.intValue
            }
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                let n = Int(data[2]) << 8 | Int(data[3])
                if n > 0 { return n }
            }
        }
        return nil
    }
}
