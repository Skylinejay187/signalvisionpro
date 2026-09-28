import Foundation

/// Architecture migration step 8.
///
/// Centralizes direct-link URL normalization, playback alternate ordering,
/// subtitle URL extraction, and the safe lightweight playback preflight used
/// before handing a debrid/source URL to the player.
enum DebridResolverPreflightManager {
    static func makePlayableURL(from raw: String?) -> URL? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: " ", with: "%20")
        guard value.lowercased().hasPrefix("http") else { return nil }
        return URL(string: value)
    }

    static func playableURLs(from links: [StreamLink], selected: StreamLink? = nil) -> [URL] {
        // v985: Source Intelligence may display 25 or 50 ranked results, but the active
        // player must not retain every direct URL as an adaptive fallback. Large 2160p
        // sessions already carry substantial decoder and packet buffers; keeping dozens
        // of fallback candidates tied to the playback session needlessly extends the
        // resolver handoff and makes memory-pressure termination harder to diagnose.
        // Keep the selected source plus the next three ranked direct alternatives.
        let maximumPlaybackURLs = 4
        var urls: [URL] = []
        func add(_ raw: String?) {
            guard urls.count < maximumPlaybackURLs else { return }
            guard let url = makePlayableURL(from: raw) else { return }
            if !urls.contains(url) { urls.append(url) }
        }
        add(selected?.isDirectPlayable == true ? selected?.url : nil)
        for link in links where link.isDirectPlayable {
            add(link.url)
            if urls.count >= maximumPlaybackURLs { break }
        }
        return urls
    }

    static func subtitleURLs(from link: StreamLink?) -> [URL] {
        (link?.subtitleURLs ?? []).compactMap { URL(string: $0) }
    }

    static func quickPlaybackPreflight(url: URL) async -> Bool? {
        // v903: direct debrid links are already resolved by Source Intelligence.
        // Do not block playback behind a 3.5-second HEAD request; many debrid/CDN
        // endpoints delay or reject HEAD even though the GET stream opens instantly.
        // Let the player open immediately and use the existing alternate-URL fallback
        // only if the actual playback engine reports failure.
        return nil
    }
}
