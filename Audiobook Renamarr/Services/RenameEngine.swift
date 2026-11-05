import Foundation

enum RenameEngine {

    static func proposedFilename(for item: AudioFileItem, rule: RenameRule) -> String? {
        guard let match = item.selectedMatch else { return nil }
        let ext = item.originalURL.pathExtension

        var values: [String: String] = [
            "author":       match.primaryAuthor ?? "",
            "title":        match.title,
            "subtitle":     match.subtitle ?? "",
            "series":       match.seriesTitle ?? "",
            "narrator":     match.primaryNarrator ?? "",
            "year":         match.releaseYear ?? "",
            "ext":          ext.isEmpty ? "" : ".\(ext)",
        ]

        if let seq = match.seriesSequence, let num = Int(seq), rule.trackNumberPadding > 0 {
            values["seriesNumber"] = String(format: "%0\(rule.trackNumberPadding)d", num)
        } else {
            values["seriesNumber"] = match.seriesSequence ?? ""
        }

        var result = rule.template
        for token in RenameRule.availableTokens {
            let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            result = result.replacingOccurrences(of: token, with: values[key] ?? "")
        }

        // ── Track number: injected only if one exists ──
        let extPart = ext.isEmpty ? "" : ".\(ext)"
        var nameOnly = result
        if !extPart.isEmpty && nameOnly.lowercased().hasSuffix(extPart.lowercased()) {
            nameOnly = String(nameOnly.dropLast(extPart.count))
        }

        // Sanitize each path segment independently so "/" is preserved.
        let segments = nameOnly.components(separatedBy: "/")
        let sanitizedSegments = segments
            .map { FilenameSanitizer.sanitize($0) }
            .filter { !$0.isEmpty }

        var folderPart = sanitizedSegments.dropLast().joined(separator: "/")
        var filePart   = sanitizedSegments.last ?? "Untitled"

        if let trackNum = item.parsed?.trackNumber {
            let formatted = rule.trackNumberPadding > 0
                ? String(format: "%0\(rule.trackNumberPadding)d", trackNum)
                : String(trackNum)
            switch rule.trackPosition {
            case .front: filePart = "\(formatted) - \(filePart)"
            case .back:  filePart = "\(filePart) - \(formatted)"
            }
        }

        var full = folderPart.isEmpty ? filePart : "\(folderPart)/\(filePart)"
        full += extPart

        if rule.replaceSpacesWithUnderscore {
            full = full.replacingOccurrences(of: " ", with: "_")
        }

        var parts = full.components(separatedBy: "/")
        if let last = parts.last {
            parts[parts.count - 1] = FilenameSanitizer.truncate(last, maxLength: rule.maxFilenameLength)
        }
        return parts.joined(separator: "/")
    }

    /// Applies renames. When `outputFolder` is set, all files are moved
    /// there (organized by the rename rule's folder structure). When nil,
    /// files are renamed in place.
    static func apply(items: [AudioFileItem], rule: RenameRule, outputFolder: URL?, dryRun: Bool) -> [AudioFileItem] {
        var result    = items
        var usedNames = Set<String>()
        let fm        = FileManager.default

        for index in result.indices {
            guard result[index].includeInBatch else { continue }

            guard let proposed = result[index].proposedFilename else {
                result[index].renameResult = .skipped(reason: "No proposed filename")
                continue
            }

            // Determine destination root: output folder or the file's own folder.
            let destinationRoot = outputFolder ?? result[index].originalURL.deletingLastPathComponent()
            let destination     = destinationRoot.appendingPathComponent(proposed)

            // Check if file is already in the right place.
            if destination.path == result[index].originalURL.path {
                result[index].renameResult = .skipped(reason: "Already in the right place")
                usedNames.insert(proposed)
                continue
            }

            let uniqueName        = uniquePath(proposed, in: destinationRoot, alreadyUsed: usedNames)
            let finalDestination  = destinationRoot.appendingPathComponent(uniqueName)
            usedNames.insert(uniqueName)

            if dryRun {
                result[index].renameResult = .dryRun(to: finalDestination.path)
                continue
            }

            do {
                // Create intermediate folders (Author/Title/) if needed.
                try fm.createDirectory(
                    at: finalDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: result[index].originalURL, to: finalDestination)
                result[index].renameResult = .renamed(to: finalDestination.path)
            } catch {
                result[index].renameResult = .failed(reason: error.localizedDescription)
            }
        }

        return result
    }

    private static func uniquePath(_ relative: String, in root: URL, alreadyUsed: Set<String>) -> String {
        let fm      = FileManager.default
        let ext     = (relative as NSString).pathExtension
        let base    = (relative as NSString).deletingPathExtension
        let extPart = ext.isEmpty ? "" : ".\(ext)"

        var candidate = relative
        var counter   = 2
        while alreadyUsed.contains(candidate)
            || fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(counter))\(extPart)"
            counter  += 1
        }
        return candidate
    }
}
