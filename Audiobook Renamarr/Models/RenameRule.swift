import Foundation

/// Where the track number appears in the final filename.
enum TrackPosition: String, CaseIterable, Codable {
    case front = "Front"
    case back  = "Back"
}

/// A user-customizable template for building the new filename.
///
/// Track number is ALWAYS included — it is never optional.
/// Its position (front or back) and padding width are controlled
/// separately so the template itself doesn't need a {track} token.
///
/// Supported tokens in `template` (track is handled automatically):
///   {author}  {title}  {subtitle}  {series}  {seriesNumber}
///   {narrator}  {year}  {ext}
struct RenameRule: Equatable, Codable {
    var template: String        = "{author} - {title}{ext}"
    var trackPosition: TrackPosition = .front
    var trackNumberPadding: Int = 2          // 0 = no padding, 2 = "01", 3 = "001"
    var replaceSpacesWithUnderscore: Bool = false
    var maxFilenameLength: Int  = 200

    /// Tokens the user can insert into the template.
    /// Note: {track} is intentionally excluded — it is always injected
    /// automatically at the position specified by `trackPosition`.
    static let availableTokens = [
        "{author}", "{title}", "{subtitle}", "{series}",
        "{seriesNumber}", "{narrator}", "{year}", "{ext}",
    ]

    static let presets: [(name: String, rule: RenameRule)] = [
        ("Author - Title",                RenameRule(template: "{author} - {title}{ext}")),
        ("Title - Author",                RenameRule(template: "{title} - {author}{ext}")),
        ("Author - Series Num - Title",   RenameRule(template: "{author} - {series} {seriesNumber} - {title}{ext}")),
        ("Series Num - Title",            RenameRule(template: "{series} {seriesNumber} - {title}{ext}")),
        ("Title",                         RenameRule(template: "{title}{ext}")),
    ]
}
