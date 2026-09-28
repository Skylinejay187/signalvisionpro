import Foundation

// v784: Catalog artwork/cache manager cleanup.
// This manager centralizes lightweight artwork URL selection, provider labeling,
// and catalog artwork theme interpretation without changing the rendering path.
// Image fetching/decoding remains owned by RemoteImageFit/AsyncImage so current
// tvOS behavior, cache keys, focus restoration, and poster quality are preserved.
enum CatalogArtworkCacheManager {
    struct ThemeFlags {
        let usesArtworkBackground: Bool
        let usesArtwork2: Bool
        let usesArtwork3Hero: Bool
        let usesArtwork4Hero2: Bool
        let usesArtwork5Floating: Bool

        var usesHeroDepthLayer: Bool { usesArtwork3Hero || usesArtwork4Hero2 || usesArtwork5Floating }
        var usesFloatingQuickPanel: Bool { usesArtwork4Hero2 || usesArtwork5Floating }
        var usesTransparentPanel: Bool { usesArtwork2 || usesArtwork3Hero || usesArtwork4Hero2 || usesArtwork5Floating }

        var backdropOpacity: Double {
            if usesArtwork4Hero2 { return 0.96 }
            if usesArtwork5Floating { return 0.52 }
            if usesArtwork2 { return 0.24 }
            if usesHeroDepthLayer { return 0.64 }
            return usesTransparentPanel ? 0.58 : 0.64
        }

        var backdropSaturation: Double {
            if usesArtwork4Hero2 { return 1.10 }
            if usesArtwork5Floating { return 1.10 }
            if usesArtwork2 { return 0.86 }
            if usesHeroDepthLayer { return 1.14 }
            return 1.08
        }

        var backdropContrast: Double {
            if usesArtwork4Hero2 { return 1.14 }
            if usesArtwork5Floating { return 1.16 }
            if usesArtwork2 { return 0.92 }
            if usesHeroDepthLayer { return 1.14 }
            return 1.10
        }
    }

    static func themeFlags(for preset: String) -> ThemeFlags {
        let key = preset.lowercased()
        return ThemeFlags(
            usesArtworkBackground: key.contains("artwork"),
            usesArtwork2: key.contains("artwork 2"),
            usesArtwork3Hero: key.contains("artwork 3 hero"),
            usesArtwork4Hero2: key.contains("artwork 4 hero 2"),
            usesArtwork5Floating: key.contains("artwork 5")
        )
    }

    static func preferredBackdropURL(for item: MediaItem) -> String? {
        if let landscape = nonEmpty(item.landscapeURL) { return landscape }
        if let preview = nonEmpty(item.previewURL) { return preview }
        return nonEmpty(item.posterURL)
    }

    static func themedLogoURL(for item: MediaItem) -> String? {
        nonEmpty(item.logoURL)
    }

    static func providerName(for rawURL: String?, item: MediaItem) -> String {
        let raw = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "Stremio" }
        let lower = raw.lowercased()
        if lower.contains("fanart.tv") || lower.contains("assets.fanart.tv") { return "Fanart" }
        if lower.contains("image.tmdb.org") || lower.contains("themoviedb.org") { return "TMDB" }
        if lower.contains("cinemeta") || item.catalog.lowercased().contains("cinemeta") || (item.addonName ?? "").lowercased().contains("cinemeta") { return "Cinemeta" }
        return "Stremio"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
