import Foundation

/// v780 architecture migration step 6.
/// Centralizes the stable v400-style trailer identity and URL guard rules so
/// CatalogStore can keep its current public behavior while trailer logic is
/// migrated out one safe piece at a time.
struct TrailerServiceManager {
    static let shared = TrailerServiceManager()

    private init() {}

    func directPreviewURL(for item: MediaItem) -> URL? {
        guard let preview = item.previewURL, let url = URL(string: preview) else { return nil }
        let lower = preview.lowercased()
        // Internal trailer playback must receive direct media only. Web/watch
        // URLs continue through the backend resolver lane.
        if lower.contains("youtube.com") || lower.contains("youtu.be") { return nil }
        return url
    }

    func cacheKey(for item: MediaItem) -> String {
        // v400/v399-style identity: lock by actual trailer identity, not by
        // catalog provider ID, so duplicate rows do not start duplicate backend
        // extraction jobs for the same title/year/type.
        let title = item.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let year = item.year.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (item.type.isEmpty ? "movie" : item.type)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [title, year, type].filter { !$0.isEmpty }.joined(separator: "|")
    }

    func extractedIMDbId(from raw: String) -> String {
        guard let range = raw.range(of: #"tt\d{5,}"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
        return String(raw[range]).lowercased()
    }

    func extractedTMDBId(from raw: String) -> String {
        if extractedIMDbId(from: raw).isEmpty == false { return "" }
        if let range = raw.range(of: #"(?:tmdb[:_/\-]|themoviedb[:_/\-])(\d{2,})"#, options: [.regularExpression, .caseInsensitive]) {
            let match = String(raw[range])
            return match.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        }
        if raw.range(of: #"^\d{2,}$"#, options: .regularExpression) != nil { return raw }
        return ""
    }

    func playableTrailerURL(from raw: String) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if lower.hasPrefix("file://"), let localURL = URL(string: clean),
           FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        guard lower.hasPrefix("http"),
              !lower.contains("youtube.com/watch"),
              !lower.contains("youtu.be/"),
              !lower.contains("youtube.com/shorts"),
              !lower.contains("vimeo.com/") else { return nil }
        if lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains("video") || lower.contains("playback") || lower.contains("preview") {
            return URL(string: clean)
        }
        return nil
    }
}
