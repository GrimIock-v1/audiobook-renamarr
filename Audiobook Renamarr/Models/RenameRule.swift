import Foundation

/// User-configurable rename template.
///
/// `{track}` is intentionally NOT a template token: the track number is always
/// injected automatically at the position given by `trackPosition`.
nonisolated struct RenameRule: Codable, Equatable {
    enum TrackPosition: String, Codable, CaseIterable, Identifiable {
        case front = "Front"
        case back = "Back"
        var id: String { rawValue }
    }

    var template: String
    var trackPosition: TrackPosition
    /// 0 = no padding, 2 = "01", etc. Range 0...4.
    var trackPadding: Int
    var replaceSpacesWithUnderscores: Bool
    /// Applies to the filename segment only, not folder components.
    var maxFilenameLength: Int

    static let `default` = RenameRule(
        template: "{author} - {title}",
        trackPosition: .back,
        trackPadding: 2,
        replaceSpacesWithUnderscores: false,
        maxFilenameLength: 200
    )

    static let presets: [(name: String, rule: RenameRule)] = [
        ("Author - Title", RenameRule(template: "{author} - {title}", trackPosition: .back, trackPadding: 2, replaceSpacesWithUnderscores: false, maxFilenameLength: 200)),
        ("Author/Title (folders)", RenameRule(template: "{author}/{title}/{title}", trackPosition: .back, trackPadding: 2, replaceSpacesWithUnderscores: false, maxFilenameLength: 200)),
        ("Series-aware folders", RenameRule(template: "{author}/{series}/{seriesNumber} - {title}/{title}", trackPosition: .back, trackPadding: 3, replaceSpacesWithUnderscores: false, maxFilenameLength: 200)),
        ("Title (Year)", RenameRule(template: "{title} ({year}) - {author}", trackPosition: .back, trackPadding: 2, replaceSpacesWithUnderscores: false, maxFilenameLength: 200)),
        ("Plex/Audiobookshelf", RenameRule(template: "{author}/{title}/{author} - {title}", trackPosition: .back, trackPadding: 3, replaceSpacesWithUnderscores: false, maxFilenameLength: 200)),
    ]

    // MARK: - Token rendering

    struct TokenContext {
        var author: String?
        var title: String?
        var subtitle: String?
        var series: String?
        var seriesNumber: Int?
        var narrator: String?
        var year: Int?
        var ext: String
        var trackNumber: Int?
    }

    /// Produces the sanitized relative path (may contain `/` folder separators),
    /// with the track number injected. Pure — never touches disk.
    func render(context: TokenContext) -> String {
        var substituted = template
        let replacements: [(String, String?)] = [
            ("{author}", context.author),
            ("{title}", context.title),
            ("{subtitle}", context.subtitle),
            ("{series}", context.series),
            ("{seriesNumber}", context.seriesNumber.map(String.init)),
            ("{narrator}", context.narrator),
            ("{year}", context.year.map(String.init)),
            ("{ext}", context.ext),
        ]
        for (token, value) in replacements {
            substituted = substituted.replacingOccurrences(of: token, with: value ?? "")
        }

        // Split into folder components; sanitize each independently.
        var components = substituted
            .components(separatedBy: "/")
            .map { FilenameSanitizer.sanitize($0) }
            .filter { !$0.isEmpty }

        if components.isEmpty { components = ["Untitled"] }

        // Inject track number into the final (filename) component.
        var filename = components.removeLast()
        if let track = context.trackNumber {
            let padded = trackPadding > 0
                ? String(format: "%0\(trackPadding)d", track)
                : String(track)
            switch trackPosition {
            case .front: filename = "\(padded) - \(filename)"
            case .back: filename = "\(filename) - \(padded)"
            }
        }

        if replaceSpacesWithUnderscores {
            components = components.map { $0.replacingOccurrences(of: " ", with: "_") }
            filename = filename.replacingOccurrences(of: " ", with: "_")
        }

        // Enforce max length on the filename segment only (reserve room for extension).
        let extSuffix = "." + context.ext
        let maxStem = max(10, maxFilenameLength - extSuffix.count)
        if filename.count > maxStem {
            filename = String(filename.prefix(maxStem)).trimmingCharacters(in: .whitespaces)
        }

        components.append(filename + extSuffix)
        return components.joined(separator: "/")
    }
}
