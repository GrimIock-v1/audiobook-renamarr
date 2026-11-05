import Foundation

nonisolated enum FilenameSanitizer {
    /// Cleans a single path component (never a full path).
    static func sanitize(_ raw: String) -> String {
        // Normalize to NFC so accented characters compare consistently
        // (APFS stores NFD; string matching breaks otherwise).
        var s = raw.precomposedStringWithCanonicalMapping

        // Replace illegal / risky characters.
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
        s = s.components(separatedBy: illegal).joined(separator: " ")

        // Collapse artifacts left by empty template tokens: " -  - ", "- -", etc.
        while let range = s.range(of: #"\s*-\s*-\s*"#, options: .regularExpression) {
            s.replaceSubrange(range, with: " - ")
        }

        // Collapse whitespace runs.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        // Trim leading/trailing separators and whitespace.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))

        // A leading dot would hide the file; already stripped above, but a
        // component that became empty needs a fallback handled by callers.
        return s
    }

    /// Case-insensitive collision-safe filename within a set of taken names
    /// (APFS is case-insensitive by default). Appends " (2)", " (3)", ...
    static func uniqueFilename(_ desired: String, takenLowercased: Set<String>) -> String {
        if !takenLowercased.contains(desired.lowercased()) { return desired }
        let ext = (desired as NSString).pathExtension
        let stem = (desired as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !takenLowercased.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }
}
