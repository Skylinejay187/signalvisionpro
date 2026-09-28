import SwiftUI
import Foundation
import AVFoundation
import UserNotifications


struct CastMember: Identifiable, Hashable, Codable {
    var id: String {
        if let tmdbPersonId { return "tmdb-person-\(tmdbPersonId)" }
        return name.lowercased() + "|" + (role ?? "")
    }
    var name: String
    var role: String? = nil
    var imageURL: String? = nil
    // v1134 Phase 13: retain the stable TMDB person identity from credits so Cast Explorer
    // opens the exact person without a name-search round trip when metadata provides it.
    var tmdbPersonId: Int? = nil
}

struct MediaItem: Identifiable, Hashable, Codable {
    let id: String
    var tmdbId: String? = nil
    var imdbId: String? = nil
    var tvdbId: String? = nil
    var title: String
    var year: String
    var type: String
    var catalog: String
    var description: String
    var genres: [String]
    var rating: String
    var posterURL: String?
    var landscapeURL: String?
    var logoURL: String?
    var previewURL: String? = nil
    // v274: Preserve the Stremio JSON add-on identity that supplied this catalog item
    // so UI cards/details can show the corresponding add-on icon/source name.
    var addonName: String? = nil
    var addonIconURL: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    // v468: Optional credits surfaced in the movie/show popup.
    // These stay app-local and are hydrated from Stremio/Cinemeta metadata when available.
    var cast: [String] = []
    var directors: [String] = []
    // v469: actor face cards for popup cast row. Uses TMDB credits images when available.
    var castMembers: [CastMember] = []
    // v607: Optional episode air/release date used for next-up alerts.
    var airDateString: String? = nil
    var episodeDateStrings: [String] = []
    // v616: movie-only collection/franchise shelf. Empty unless TMDB confirms a real belongs_to_collection result.
    var franchiseItems: [MediaItem] = []
}

private struct CachedCatalogItem: Codable {
    var id: String
    var tmdbId: String?
    var imdbId: String?
    var tvdbId: String?
    var title: String
    var year: String
    var type: String
    var catalog: String
    var description: String
    var genres: [String]
    var rating: String
    var posterURL: String?
    var landscapeURL: String?
    var logoURL: String?
    var previewURL: String?
    var addonName: String?
    var addonIconURL: String?
    var cast: [String]
    var directors: [String]

    init(_ item: MediaItem) {
        id = item.id
        tmdbId = item.tmdbId
        imdbId = item.imdbId
        tvdbId = item.tvdbId
        title = item.title
        year = item.year
        type = item.type
        catalog = item.catalog
        description = item.description
        genres = item.genres
        rating = item.rating
        posterURL = item.posterURL
        landscapeURL = item.landscapeURL
        logoURL = item.logoURL
        previewURL = item.previewURL
        addonName = item.addonName
        addonIconURL = item.addonIconURL
        cast = item.cast
        directors = item.directors
    }

    var mediaItem: MediaItem {
        MediaItem(
            id: id,
            tmdbId: tmdbId,
            imdbId: imdbId,
            tvdbId: tvdbId,
            title: title,
            year: year,
            type: type,
            catalog: catalog,
            description: description,
            genres: genres,
            rating: rating,
            posterURL: posterURL,
            landscapeURL: landscapeURL,
            logoURL: logoURL,
            previewURL: previewURL,
            addonName: addonName,
            addonIconURL: addonIconURL,
            cast: cast,
            directors: directors
        )
    }
}

private struct CachedCatalogRow: Codable {
    var id: String
    var title: String
    var items: [CachedCatalogItem]
    var presentation: CatalogRowPresentation? = nil

    init(_ row: MediaRow) {
        id = row.id
        title = row.title
        items = row.items.map(CachedCatalogItem.init)
        presentation = row.presentation
    }

    var mediaRow: MediaRow {
        MediaRow(id: id, title: title, items: items.map(\.mediaItem), presentation: presentation)
    }
}


// v1032 Phase 5: full, versioned last-known-good official catalog snapshot.
// This is intentionally separate from the small fast-launch UserDefaults cache. It keeps
// every official row (including rows hidden by local customization) and is promoted only
// after structural validation succeeds.
private struct CatalogReliabilitySnapshot: Codable {
    let schemaVersion: Int
    let createdAt: Date
    let source: String
    let rows: [MediaRow]
}

private enum CatalogReliabilityError: LocalizedError {
    case invalidManifest
    case untrustedEndpoint
    case incompleteCatalog
    case malformedCatalog
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The official catalog manifest was invalid."
        case .untrustedEndpoint:
            return "The official catalog response referenced an untrusted service."
        case .incompleteCatalog:
            return "The official catalog response was incomplete."
        case .malformedCatalog:
            return "The official catalog response contained malformed rows."
        case .unavailable:
            return "The official catalog service is temporarily unavailable."
        }
    }
}

struct NewEpisodeAlertHit: Identifiable, Hashable, Codable {
    var id: String { alertKey }
    let alertKey: String
    let show: MediaItem
    let episode: MediaItem
}

struct NewEpisodeAlertScanReport: Equatable {
    var recentWindowDays: Int = 7
    var periodicScannerEnabled: Bool = false
    var scanIntervalMinutes: Int = 0
    var scanFrequencyTestMode: Bool = false
    var selectedScanFrequencyRawValue: String = "10"
    var selectedScanFrequencySeconds: Int = 600
    var activeHeartbeatIntervalSeconds: Int = 0
    var heartbeatTaskActive: Bool = false
    var heartbeatGeneration: Int = 0
    var lastHeartbeatFiredTime: String = "None"
    var nextScheduledScanTime: String = "None"
    var lastScanReason: String = "None"
    var duplicateHeartbeatPreventedCount: Int = 0
    var bannerSideSetting: String = "Right"
    var alertStyleSetting: String = "Banner"
    var alertThemeSetting: String = "Glass"
    var bannerDurationSeconds: Int = 15
    var lastScanTime: String = "None"
    var nextScanEstimate: String = "None"
    var scanAlreadyRunning: Bool = false
    var followedKeysCount: Int = 0
    var followedShowsMatchedInLoadedRows: Int = 0
    var showsChecked: Int = 0
    var metadataFetchAttempted: Bool = false
    var metadataFetchSuccessCount: Int = 0
    var metadataFetchFailureCount: Int = 0
    var followedSnapshotCount: Int = 0
    var scanCompletedSuccessfully: Bool = false
    var scanWasPartial: Bool = false
    var scanOutcome: String = "Not run"
    var persistentQueueCount: Int = 0
    var scheduleConsecutiveFailureCount: Int = 0
    var episodesFetchedCount: Int = 0
    var newerTodayEpisodeDetected: Bool = false
    var newestEligibleEpisodeDate: String = "None"
    var recentEpisodeDetected: Bool = false
    var newestRawDateStringSeen: String = "None"
    var newestParsedDate: String = "None"
    var missingDateCount: Int = 0
    var dateParseSuccessCount: Int = 0
    var dateParseFailedCount: Int = 0
    var eligibleButConsumedCount: Int = 0
    var suppressedDuplicateCount: Int = 0
    var alreadyAlertedCount: Int = 0
    var suppressedSameEpisodeCount: Int = 0
    var newestDetectedEpisodeKey: String = "None"
    var lastAlertedEpisodeKeyForShow: String = "None"
    var alertQueuedCount: Int = 0
    var returnedAlertHits: Int = 0
    var alertDisplayed: Bool = false
    var displayedThisCycleCount: Int = 0
    var remainingQueueCount: Int = 0
    var hitSourceSummaries: [String] = []
    var hits: [NewEpisodeAlertHit] = []
}

private struct FollowedShowSnapshot: Codable {
    var id: String
    var title: String
    var year: String
    var type: String
    var catalog: String
    var description: String
    var genres: [String]
    var rating: String
    var posterURL: String?
    var landscapeURL: String?
    var logoURL: String?
    var previewURL: String?
    var addonName: String?
    var addonIconURL: String?
    var tmdbId: String?
    var imdbId: String?
    var tvdbId: String?

    init(item: MediaItem) {
        id = item.id
        tmdbId = item.tmdbId
        imdbId = item.imdbId
        tvdbId = item.tvdbId
        title = item.title
        year = item.year
        type = item.type
        catalog = item.catalog
        description = item.description
        genres = item.genres
        rating = item.rating
        posterURL = item.posterURL
        landscapeURL = item.landscapeURL
        logoURL = item.logoURL
        previewURL = item.previewURL
        addonName = item.addonName
        addonIconURL = item.addonIconURL
    }

    var mediaItem: MediaItem {
        MediaItem(
            id: id,
            tmdbId: tmdbId,
            imdbId: imdbId,
            tvdbId: tvdbId,
            title: title,
            year: year,
            type: type,
            catalog: catalog,
            description: description,
            genres: genres,
            rating: rating,
            posterURL: posterURL,
            landscapeURL: landscapeURL,
            logoURL: logoURL,
            previewURL: previewURL,
            addonName: addonName,
            addonIconURL: addonIconURL
        )
    }
}


private struct FanartTVImage: Decodable, Hashable {
    var url: String?
    var lang: String?
    var likes: String?

    var likeScore: Int { Int(likes ?? "0") ?? 0 }
}

private struct FanartMovieResponse: Decodable {
    var hdmovielogo: [FanartTVImage]?
    var movielogo: [FanartTVImage]?
    var moviebackground: [FanartTVImage]?
    var movieposter: [FanartTVImage]?
}

private struct FanartTVResponse: Decodable {
    var hdtvlogo: [FanartTVImage]?
    var clearlogo: [FanartTVImage]?
    var showbackground: [FanartTVImage]?
    var tvposter: [FanartTVImage]?
}

private struct TMDBExternalIDsResponse: Decodable {
    var imdb_id: String?
    var tvdb_id: Int?
}

private struct PremiumFanartArtwork: Hashable {
    var backdropURL: String? = nil
    var logoURL: String? = nil
    var posterURL: String? = nil

    var hasAny: Bool { backdropURL != nil || logoURL != nil || posterURL != nil }
}

private struct TMDBMultiSearchResponse: Decodable {
    var results: [TMDBSearchResult]
}

private struct TMDBSearchResult: Decodable {
    var id: Int
    var media_type: String?
    var title: String?
    var name: String?
    var overview: String?
    var release_date: String?
    var first_air_date: String?
    var poster_path: String?
    var backdrop_path: String?
    var vote_average: Double?
}

private struct TMDBListResponse: Decodable {
    var results: [TMDBListItem]
}

private struct TMDBCreditsResponse: Decodable {
    var cast: [TMDBCreditCastMember]?
    var guest_stars: [TMDBCreditCastMember]?
    var crew: [TMDBCreditCrewMember]?
}

private struct TMDBCreditRole: Decodable {
    var character: String?
    var episode_count: Int?
}

private struct TMDBCreditJob: Decodable {
    var job: String?
    var episode_count: Int?
}

private struct TMDBCreditCastMember: Decodable {
    var id: Int?
    var name: String?
    var character: String?
    var profile_path: String?
    // Aggregate-credit endpoints return per-character roles instead of `character`.
    var roles: [TMDBCreditRole]?
}

private struct TMDBCreditCrewMember: Decodable {
    var name: String?
    var job: String?
    // Aggregate-credit endpoints return per-job entries instead of `job`.
    var jobs: [TMDBCreditJob]?
}

private struct TMDBFindResponse: Decodable {
    var movie_results: [TMDBFindResult]?
    var tv_results: [TMDBFindResult]?
}

private struct TMDBFindResult: Decodable {
    var id: Int?
}

private struct TMDBListItem: Decodable {
    var id: Int
    var title: String?
    var name: String?
    var overview: String?
    var release_date: String?
    var first_air_date: String?
    var poster_path: String?
    var backdrop_path: String?
    var vote_average: Double?
}

// v1104: exact episode metadata is separate from parent-series metadata.
// `air_date` is the only date accepted by the episode presentation path.
private struct TMDBEpisodeDetail: Decodable {
    var id: Int
    var name: String?
    var overview: String?
    var air_date: String?
    var still_path: String?
    var vote_average: Double?
    var season_number: Int?
    var episode_number: Int?
}


// v1053: Episode-alert verification uses TVMaze as an identity/date source before
// falling back to configured Stremio metadata. This matches the Follow Center UI
// contract and prevents addon/catalog outages from silently disabling alerts.
private struct TVMazeSearchResult: Decodable {
    var score: Double?
    var show: TVMazeShow
}

private struct TVMazeShow: Decodable {
    var id: Int
    var name: String
    var premiered: String?
    var externals: TVMazeExternalIDs?
}

private struct TVMazeExternalIDs: Decodable {
    var imdb: String?
    var thetvdb: Int?
}

private struct TVMazeEpisode: Decodable {
    var id: Int
    var name: String
    var season: Int
    var number: Int?
    var airdate: String?
    var airstamp: String?
    var summary: String?
    var image: TVMazeImage?
}

private struct TVMazeImage: Decodable {
    var medium: String?
    var original: String?
}

private struct TMDBMovieCollectionLink: Decodable {
    var id: Int?
    var name: String?
}

private struct TMDBMovieDetailWithCollection: Decodable {
    var belongs_to_collection: TMDBMovieCollectionLink?
}

private struct TMDBCollectionResponse: Decodable {
    var id: Int?
    var name: String?
    var parts: [TMDBListItem]?
}

private struct TMDBImagesResponse: Decodable {
    var logos: [TMDBLogoImage]?
    var backdrops: [TMDBBackdropImage]?
}

private struct TMDBBackdropImage: Decodable {
    var file_path: String?
    var iso_639_1: String?
    var width: Int?
    var height: Int?
    var vote_average: Double?
    var vote_count: Int?
}

private struct TMDBLogoImage: Decodable {
    var file_path: String?
    var iso_639_1: String?
    var vote_average: Double?
    var vote_count: Int?
}

struct CatalogRowVisualTheme: Hashable, Codable {
    var style: String? = nil
    var accentHex: String? = nil
    var secondaryHex: String? = nil
    var symbol: String? = nil
    var labelStyle: String? = nil
}

struct CatalogRowPresentation: Hashable, Codable {
    var shortName: String? = nil
    var description: String? = nil
    var rowKind: String? = nil
    var providerName: String? = nil
    var themeLogoURL: String? = nil
    var providerBadgeURL: String? = nil
    var backgroundURL: String? = nil
    var theme: CatalogRowVisualTheme? = nil
}

struct MediaRow: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var items: [MediaItem]
    var presentation: CatalogRowPresentation? = nil

    init(id: String, title: String, items: [MediaItem], presentation: CatalogRowPresentation? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.presentation = presentation
    }
}

struct BuiltInCatalogRowDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
}

// v1099 Phase 5: lightweight, app-owned catalog health diagnostics. These models
// intentionally contain only display-safe provider labels and aggregate row state;
// provider credentials and resolved playback URLs are never retained here.
enum CatalogProviderHealthState: String, Hashable {
    case checking = "Checking"
    case loaded = "Loaded"
    case streamOnly = "Stream only"
    case noRows = "No rows"
    case timedOut = "Timed out"
    case failed = "Failed"
    case cached = "Cached"
}

struct CatalogProviderHealth: Identifiable, Hashable {
    let id: String
    var name: String
    var endpoint: String
    var state: CatalogProviderHealthState
    var loadedRows: Int
    var message: String
}

struct CatalogPageFailure: Identifiable, Hashable {
    let id: String
    var rowID: String
    var rowTitle: String
    var page: Int
    var skip: Int
    var message: String
}

struct CatalogRowHealth: Identifiable, Hashable {
    let id: String
    var title: String
    var posterCount: Int
    var paginationState: String
    var provider: String
    var failed: Bool
}

struct CatalogHealthSnapshot: Hashable {
    var configuredProviders: [CatalogProviderHealth]
    var expectedRows: Int
    var loadedRows: Int
    var totalPosters: Int
    var rows: [CatalogRowHealth]
    var lastSuccessfulRefresh: Date?
    var lastFullPaginationRefresh: Date?
    var failedProviders: [CatalogProviderHealth]
    var timedOutProviders: [CatalogProviderHealth]
    var failedPages: [CatalogPageFailure]
    var refreshInProgress: Bool
}

struct StremioAddonIdentity: Hashable {
    var name: String
    var iconURL: String?
    var kind: String
}

enum SourceProviderRequestState: String, Hashable {
    case searching
    case returnedLinks
    case noLinks
    case failed
    case timeout
}

struct SourceProviderRequestStatus: Identifiable, Hashable {
    var id: String { provider }
    var provider: String
    var state: SourceProviderRequestState
    var linkCount: Int
    var message: String
}

enum AddonSearchProviderState: String, Hashable {
    case loading = "Loading"
    case results = "Results"
    case noResults = "No results"
    case timedOut = "Timed out"
    case failed = "Failed"
}

struct AddonSearchProviderStatus: Identifiable, Hashable {
    var id: String { provider }
    var provider: String
    var state: AddonSearchProviderState
    var resultCount: Int
    var message: String
}

/// Phase 8 isolated source preparation result for the next television episode.
/// It contains only episode-owned ranked links and never publishes into the visible
/// Source Intelligence state of the currently playing title.
struct UpNextEpisodePreparation {
    let episode: MediaItem
    let rankedLinks: [StreamLink]
    let primaryURL: URL?
    let primaryAvailability: Bool?
    let alternateURLs: [URL]
    let subtitleURLs: [URL]

    var sourceReady: Bool { primaryURL != nil }
    var readinessLabel: String {
        switch primaryAvailability {
        case .some(true): return "Verified ready"
        case .some(false): return "Unavailable"
        case .none: return sourceReady ? "Prepared" : "Not ready"
        }
    }
    var sourceCount: Int { rankedLinks.filter(\.isDirectPlayable).count }
    var providerLabel: String { rankedLinks.first(where: \.isDirectPlayable)?.providerDisplay ?? "No ranked source" }
    var qualityLabel: String { rankedLinks.first(where: \.isDirectPlayable)?.quality ?? "Unknown quality" }
}

struct StreamRequestHeader: Hashable {
    var name: String
    var value: String
}

extension Array where Element == StreamRequestHeader {
    var playbackHTTPHeaderDictionary: [String: String] {
        reduce(into: [String: String]()) { result, field in
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return }
            result[name] = value
        }
    }
}

struct StreamLink: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: String?
    var quality: String
    var size: String
    var source: String
    // Distinguishes the debrid account behind multi-account addons such as
    // Torrentio, Comet, Debrido, and MediaFusion. This keeps Real-Debrid and
    // TorBox links independently visible and round-robin balanced.
    var providerService: String? = nil
    var infoHash: String? = nil
    var fileIndex: Int? = nil
    var subtitleURLs: [String] = []
    // vBRDC089: provider-owned request context must survive Source Intelligence all the
    // way to the playback engine. Protected plugin/CDN links can require Referer, Origin,
    // Cookie, Authorization, or a provider-specific User-Agent; dropping those headers
    // turns a valid resolved URL into a 401/403/empty stream on Apple TV.
    var requestHeaders: [StreamRequestHeader] = []
    var isExternalURL: Bool = false
    // vBRDC050: TorBox Voyager Usenet results are intentionally represented as
    // unresolved Source Intelligence rows until the user selects one. TorBox owns
    // the NZB download/repair/unpack path; the app only stores the opaque TorBox
    // handoff URL/hash needed to ask TorBox for the final CDN media URL.
    var torBoxUsenetNZBURL: String? = nil
    var torBoxUsenetHash: String? = nil
    var torBoxUsenetCached: Bool? = nil
    var torBoxUsenetOwned: Bool? = nil
    // vBRDC060: owned-library fallback can identify a TorBox Usenet job directly even
    // when restricted Voyager discovery did not provide an internal NZB handoff URL.
    var torBoxUsenetDownloadID: Int? = nil
    // vBRDC075: A configured whitelisted AIOStreams bridge can return an already-resolved
    // HTTP stream instead of an opaque TorBox NZB/hash. Keep an explicit provider marker
    // so these direct rows still live in the TorBox Usenet lane and bypass ordinary caps.
    var torBoxUsenetBridgeDirect: Bool = false

    var isTorBoxUsenetCandidate: Bool {
        let nzb = torBoxUsenetNZBURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hash = torBoxUsenetHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return torBoxUsenetBridgeDirect || !nzb.isEmpty || !hash.isEmpty || (torBoxUsenetDownloadID ?? 0) > 0
    }

    var isDirectPlayable: Bool {
        guard let url else { return false }
        if isExternalURL { return false }
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let lower = url.lowercased()
        // v92: Debrid providers such as TorBox/Real-Debrid often return signed CDN URLs with no file extension.
        // Treat HTTP(S) stream.url as playable unless it is clearly a webpage/configuration/deep-link.
        if lower.hasPrefix("stremio://") || lower.hasPrefix("magnet:") { return false }
        if lower.contains("/configure") || lower.contains("youtube.com") || lower.contains("youtu.be") { return false }
        if lower.contains("/manifest.json") || lower.contains("/catalog/") || lower.contains("/meta/") { return false }
        if lower.contains("imdb.com/title") || lower.contains("themoviedb.org") { return false }
        return true
    }
}

extension StreamLink {
    var sourceIntelligenceHaystack: String {
        [title, quality, size, source, url ?? ""].joined(separator: " ").lowercased()
    }

    var sourceIntelligenceIsCached: Bool {
        // vBRDC050: Voyager tells us the actual Usenet cache state. Do not infer
        // "TorBox == cached" for these rows, and never let the word "Uncached"
        // accidentally satisfy the generic `contains("cached")` fallback.
        if let torBoxUsenetCached { return torBoxUsenetCached }
        let h = sourceIntelligenceHaystack
        if h.contains("uncached") || h.contains("not cached") || h.contains("download required") { return false }
        return h.contains("cached") ||
            h.contains("cache hit") ||
            h.contains("cache-hit") ||
            h.contains("instant") ||
            h.contains("rd+") ||
            h.contains("real-debrid") ||
            h.contains("alldebrid") ||
            h.contains("all-debrid") ||
            h.contains("premiumize") ||
            h.contains("debrid-link") ||
            h.contains("debridlink") ||
            h.contains("easydebrid") ||
            h.contains("offcloud") ||
            h.contains("put.io") ||
            h.contains("putio") ||
            h.contains("torbox")
    }

    var sourceIntelligenceCacheLabel: String {
        sourceIntelligenceIsCached ? "Cached" : "Uncached"
    }

    /// vBRDC168: Torrent/debrid addons often publish swarm health only inside the
    /// human-readable stream title (for example `Seeders: 12`, `S:12`, or `👤 12`).
    /// Parse that already-owned metadata locally so PlaybackKit can give weak/uncached
    /// sources a deeper safety buffer without any new network probe or resolver request.
    var sourceIntelligenceSeederCount: Int? {
        let value = sourceIntelligenceHaystack
        let patterns = [
            #"(?:seeders?|seeds?|peers?)\s*[:=+\-]?\s*(\d{1,6})"#,
            #"(?:👤|👥)\s*(\d{1,6})"#,
            #"(?:^|\s)s\s*[:=]\s*(\d{1,6})(?:\s|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  match.numberOfRanges > 1,
                  let countRange = Range(match.range(at: 1), in: value),
                  let count = Int(value[countRange]) else { continue }
            return count
        }
        return nil
    }

    /// Compact transport-only marker appended to the internal playback route hint.
    /// Cached debrid rows do not need swarm compensation even when their original torrent
    /// reports few seeders. Uncached rows do, and numeric seeder counts let the adaptive
    /// cache distinguish a genuinely weak source from an uncached but healthy swarm.
    var sourceIntelligenceAdaptiveCacheHint: String {
        var parts: [String] = []
        if !sourceIntelligenceIsCached { parts.append("cache-health=uncached") }
        if let seeders = sourceIntelligenceSeederCount { parts.append("seeders=\(seeders)") }
        // Keep the addon's raw transport facts available to PlaybackKit (bitrate,
        // remux tags, swarm markers) without exposing them in the user-facing label.
        let metadata = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !metadata.isEmpty { parts.append("source-meta=\(metadata.prefix(240))") }
        return parts.joined(separator: " ")
    }

    var sourceIntelligenceIsEnglish: Bool {
        sourceIntelligenceLanguageRank == 0
    }

    var sourceIntelligenceLanguageRank: Int {
        let h = sourceIntelligenceHaystack
        let nonEnglishTokens = [
            " spanish", " latino", " castellano", " spa", ".spa", "-spa",
            " french", " fre", " fra", ".fre", ".fra",
            " german", " ger", " deu", ".ger", ".deu",
            " italian", " ita", ".ita",
            " portuguese", " por", ".por",
            " polish", " pldub", " lektor", ".pl.",
            " russian", " rus", ".rus",
            " hindi", " hin", " japanese", " jpn", " korean", " kor", " tamil", " telugu", " malayalam", " arabic", " thai", " viet"
        ]
        let englishTokens = [" english", " eng", ".eng", "-eng", "[eng", "(eng", "[en", " en ", " en-", ".en.", "en-us", "en-gb", "dual audio", "dual-audio", "multi", "🇺🇸", "🇬🇧"]
        if englishTokens.contains(where: { h.contains($0) }) { return 0 }
        if nonEnglishTokens.contains(where: { h.contains($0) }) { return 2 }
        return 1
    }

    var sourceIntelligenceLanguageLabel: String {
        if sourceIntelligenceLanguageRank == 0 { return "English" }
        let h = sourceIntelligenceHaystack
        if h.contains("spanish") || h.contains("latino") || h.contains(" spa") { return "Spanish" }
        if h.contains("french") || h.contains(" fre") || h.contains(" fra") { return "French" }
        if h.contains("german") || h.contains(" ger") || h.contains(" deu") { return "German" }
        if h.contains("italian") || h.contains(" ita") { return "Italian" }
        if h.contains("polish") || h.contains("pldub") || h.contains("lektor") { return "Polish" }
        if h.contains("russian") || h.contains(" rus") { return "Russian" }
        if h.contains("hindi") { return "Hindi" }
        if h.contains("japanese") || h.contains(" jpn") { return "Japanese" }
        if h.contains("korean") { return "Korean" }
        return "Language Unknown"
    }

    var sourceIntelligenceResolutionRank: Int {
        let h = sourceIntelligenceHaystack
        if h.contains("2160") || h.contains("4k") { return 0 }
        if h.contains("1440") { return 1 }
        if h.contains("1080") { return 2 }
        if h.contains("720") { return 3 }
        if h.contains("480") { return 4 }
        if h.contains("auto") { return 8 }
        return 9
    }

    var sourceIntelligenceSizeGB: Double {
        let haystack = [size, title, quality, source].joined(separator: " ")
        let pattern = #"(\d+(?:[\.,]\d+)?)\s*(gb|gib|mb|mib)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return Double.greatestFiniteMagnitude
        }
        let nsRange = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let numberRange = Range(match.range(at: 1), in: haystack),
              let unitRange = Range(match.range(at: 2), in: haystack) else {
            return Double.greatestFiniteMagnitude
        }
        let rawNumber = haystack[numberRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(rawNumber) else { return Double.greatestFiniteMagnitude }
        let unit = haystack[unitRange].lowercased()
        return unit.hasPrefix("m") ? value / 1024.0 : value
    }

    var sourceIntelligenceReliabilityRank: Int {
        let h = sourceIntelligenceHaystack
        if isDirectPlayable && (h.contains(".mp4") || h.contains(".m4v") || h.contains(".mov") || h.contains(".m3u8")) { return 0 }
        if isDirectPlayable && (h.contains("web-dl") || h.contains("webdl") || h.contains("bluray") || h.contains("remux")) { return 1 }
        if isDirectPlayable { return 2 }
        if isTorBoxUsenetCandidate { return torBoxUsenetCached == true ? 3 : 5 }
        if h.hasPrefix("magnet:") || infoHash != nil { return 7 }
        if isExternalURL { return 8 }
        return 6
    }
}



struct LastPlaybackLinkEntry: Codable, Hashable {
    var key: String
    var url: String
    var title: String
    var quality: String
    var size: String
    var source: String
    var updatedAt: Date
}

final class LastPlaybackLinkCacheManager {
    static let shared = LastPlaybackLinkCacheManager()
    private let legacyStorageKey = "DebridChannels.v620.lastPlaybackLinks"
    private let maxEntries = 30
    private let maxEncodedBytes = 48 * 1024
    private init() {}

    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DebridChannels", isDirectory: true)
            .appendingPathComponent("lastPlaybackLinks.json")
    }

    func entry(for item: MediaItem) -> LastPlaybackLinkEntry? {
        allEntries()[PlaybackResumeCacheManager.shared.playbackKey(for: item)]
    }

    func save(item: MediaItem, link: StreamLink, url: URL) {
        let key = trimmed(PlaybackResumeCacheManager.shared.playbackKey(for: item), limit: 160)
        var entries = allEntries()
        entries[key] = LastPlaybackLinkEntry(
            key: key,
            url: trimmed(url.absoluteString, limit: 2048),
            title: trimmed(link.title, limit: 240),
            quality: trimmed(link.quality, limit: 40),
            size: trimmed(link.size, limit: 40),
            source: trimmed(link.source, limit: 80),
            updatedAt: Date()
        )
        entries = bounded(entries)
        write(entries)
    }

    private func allEntries() -> [String: LastPlaybackLinkEntry] {
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: LastPlaybackLinkEntry].self, from: data) {
            return bounded(decoded)
        }
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
              let decoded = try? JSONDecoder().decode([String: LastPlaybackLinkEntry].self, from: data) else { return [:] }
        return bounded(decoded)
    }

    private func write(_ entries: [String: LastPlaybackLinkEntry]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var payload = bounded(entries)
            var data = try JSONEncoder().encode(payload)
            while data.count > maxEncodedBytes, payload.count > 1 {
                let keepCount = max(1, payload.count / 2)
                payload = Dictionary(uniqueKeysWithValues: payload.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(keepCount).map { ($0.key, $0) })
                data = try JSONEncoder().encode(payload)
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Last-link memory is a convenience only. Never let cache writes crash playback or navigation.
        }
    }

    private func bounded(_ entries: [String: LastPlaybackLinkEntry]) -> [String: LastPlaybackLinkEntry] {
        let keep = entries.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxEntries).map { entry in
            LastPlaybackLinkEntry(
                key: trimmed(entry.key, limit: 160),
                url: trimmed(entry.url, limit: 2048),
                title: trimmed(entry.title, limit: 240),
                quality: trimmed(entry.quality, limit: 40),
                size: trimmed(entry.size, limit: 40),
                source: trimmed(entry.source, limit: 80),
                updatedAt: entry.updatedAt
            )
        }
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        if value.count <= limit { return value }
        return String(value.prefix(limit))
    }
}

struct AlternateAudioSource: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: String
    var quality: String
    var source: String
    var confidence: String
    var matchClassification: String = AlternateAudioMatchClassification.possibleMatch.rawValue
    var audioTrackIndex: Int? = nil
    var audioCodec: String? = nil
    var audioLanguage: String? = nil
    var audioTrackTitle: String? = nil
    var durationSeconds: Double? = nil
    var startTimeSeconds: Double? = nil
    var frameRate: Double? = nil
    var edition: String? = nil
    var chapterCount: Int? = nil
    var fingerprintSimilarity: Double? = nil
    var fingerprintStatus: String? = nil
    var rejectionReason: String? = nil
    var releaseMetadata: String? = nil
    var isCommentary: Bool = false
    var isDescriptiveAudio: Bool = false
    // vBRDC160: preserve provider-owned auth/referer/cookie context so the selected
    // alternate copy can be demuxed directly on Apple TV without a backend audio bridge.
    var requestHeaders: [StreamRequestHeader] = []

    var displayTitle: String {
        let cleanQuality = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = audioLanguage?.uppercased() ?? "Audio"
        let codec = audioCodec?.uppercased() ?? "Unknown codec"
        let cleanTrackTitle = audioTrackTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trackLabel = cleanTrackTitle.isEmpty ? "\(language) \(codec)" : "\(language) \(codec) • \(cleanTrackTitle)"
        // vBRDC162: compatibility classification is legacy bridge diagnostics only. Every
        // resolved copy is locally selectable, so the main UI reports local readiness instead
        // of labelling usable copies as Incompatible.
        let localState = audioTrackIndex == nil ? "Local audio ready" : "English track verified"
        let prefix = "\(localState) • \(trackLabel)"
        if cleanQuality.isEmpty { return "\(prefix) • \(title) • \(cleanSource)" }
        return "\(prefix) • \(title) • \(cleanQuality) • \(cleanSource)"
    }

    var diagnosticSummary: String {
        var parts: [String] = []
        if let index = audioTrackIndex { parts.append("stream \(index)") }
        if let durationSeconds { parts.append(String(format: "%.2fs", durationSeconds)) }
        if let frameRate { parts.append(String(format: "%.3f fps", frameRate)) }
        if let edition, !edition.isEmpty { parts.append(edition) }
        if let chapterCount { parts.append("\(chapterCount) chapters") }
        if let fingerprintStatus, !fingerprintStatus.isEmpty { parts.append(fingerprintStatus) }
        if let rejectionReason, !rejectionReason.isEmpty { parts.append(rejectionReason) }
        return parts.joined(separator: " • ")
    }
}

struct StremioStreamResponse: Decodable {
    var streams: [StremioStream]?
}

struct StremioStream: Decodable {
    var title: String?
    var name: String?
    var url: String?
    var infoHash: String?
    var externalUrl: String?
    var fileIdx: Int?
    var behaviorHints: StremioBehaviorHints?
    var subtitles: [StremioSubtitle]?
}

struct StremioSubtitle: Decodable, Hashable {
    var id: String?
    var url: String?
    var lang: String?
    var language: String?
    var label: String?
}

struct StremioProxyHeaders: Decodable {
    var request: [String: String]?
    var response: [String: String]?
}

struct StremioBehaviorHints: Decodable {
    var filename: String?
    var videoSize: Int64?
    var videoHash: String?
    var bingeGroup: String?
    // vBRDC089 parity with the Stremio/Nuvio stream contract. Some hosters are
    // intentionally unusable without these request headers.
    var proxyHeaders: StremioProxyHeaders?
}

struct DebridChannelsManifestExtension: Decodable, Hashable {
    var allInOne: Bool? = nil
    var batchRowsURL: String? = nil
    var defaultItemsPerRow: Int? = nil
    // v1010 Phase 4B: optional single-endpoint database search advertised by the
    // hidden built-in catalog. This value remains internal and is never surfaced in UI.
    var searchURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case allInOne
        case batchRowsURL
        case defaultItemsPerRow
        case searchURL
        case searchUrl
        case searchEndpoint
        case databaseSearchURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allInOne = try container.decodeIfPresent(Bool.self, forKey: .allInOne)
        batchRowsURL = try container.decodeIfPresent(String.self, forKey: .batchRowsURL)
        defaultItemsPerRow = try container.decodeIfPresent(Int.self, forKey: .defaultItemsPerRow)
        if let value = try container.decodeIfPresent(String.self, forKey: .searchURL) {
            searchURL = value
        } else if let value = try container.decodeIfPresent(String.self, forKey: .searchUrl) {
            searchURL = value
        } else if let value = try container.decodeIfPresent(String.self, forKey: .searchEndpoint) {
            searchURL = value
        } else {
            searchURL = try container.decodeIfPresent(String.self, forKey: .databaseSearchURL)
        }
    }
}

struct DebridChannelsBatchCatalogRow: Decodable {
    var id: String
    var type: String
    var name: String
    var debridChannels: CatalogRowPresentation? = nil
    var metas: [StremioMeta]? = nil
}

struct DebridChannelsBatchCatalogResponse: Decodable {
    var rows: [DebridChannelsBatchCatalogRow]
}

private struct UnifiedCatalogSearchEnvelope: Decodable {
    var metas: [StremioMeta]

    enum CodingKeys: String, CodingKey {
        case metas
        case results
        case items
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode([StremioMeta].self, forKey: .metas) {
            metas = value
        } else if let value = try? container.decode([StremioMeta].self, forKey: .results) {
            metas = value
        } else if let value = try? container.decode([StremioMeta].self, forKey: .items) {
            metas = value
        } else if let value = try? container.decode([StremioMeta].self, forKey: .data) {
            metas = value
        } else {
            metas = []
        }
    }
}

private struct UnifiedSearchCacheEntry {
    var createdAt: Date
    var items: [MediaItem]
}

struct StremioManifest: Decodable {
    var name: String?
    var logo: String?
    var icon: String?
    var catalogs: [StremioCatalog]?
    var resources: [StremioResource]?
    var types: [String]?
    var idPrefixes: [String]?
    var debridChannels: DebridChannelsManifestExtension? = nil
}

struct StremioResource: Decodable, Hashable {
    var name: String?
    var types: [String]?
    var idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case types
        case idPrefixes
    }

    init(name: String? = nil, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    // Stremio manifests legally expose resources as either strings:
    //   "resources": ["catalog", "meta", "stream", "subtitles"]
    // or objects:
    //   { "name": "stream", "types": ["movie", "series"] }
    // The old decoder only accepted object form, which could break whole addon/catalog loading.
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            name = value
            types = nil
            idPrefixes = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        types = try container.decodeIfPresent([String].self, forKey: .types)
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
    }
}

struct StremioExtra: Decodable, Hashable {
    var name: String?
    var isRequired: Bool?
    var options: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case isRequired = "isRequired"
        case options
    }

    init(name: String? = nil, isRequired: Bool? = nil, options: [String]? = nil) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
    }

    // Real Stremio addons do not all encode extras perfectly. Some send option values as
    // numbers/bools/nulls instead of strings. A strict decoder made the whole manifest fail.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired)
        if let strings = try? container.decodeIfPresent([String].self, forKey: .options) {
            options = strings
        } else if let values = try? container.decodeIfPresent([LossyJSONValue].self, forKey: .options) {
            options = values.compactMap { $0.stringValue }
        } else {
            options = nil
        }
    }
}

struct StremioCatalog: Decodable, Hashable {
    var type: String?
    var id: String?
    var name: String?
    var extra: [StremioExtra]?
    var extraSupported: [String]?
    var extraRequired: [String]?
    var debridChannels: CatalogRowPresentation? = nil
}

struct StremioMetaResponse: Decodable {
    var meta: StremioMeta?
}

struct CatalogResponse: Decodable {
    var metas: [StremioMeta]?

    enum CodingKeys: String, CodingKey { case metas }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode metas one by one so a single unusual Stremio item cannot break the whole catalog.
        if var nested = try? container.nestedUnkeyedContainer(forKey: .metas) {
            var decoded: [StremioMeta] = []
            while !nested.isAtEnd {
                if let meta = try? nested.decode(StremioMeta.self) {
                    decoded.append(meta)
                } else {
                    _ = try? nested.decode(LossySkipValue.self)
                }
            }
            metas = decoded
        } else {
            metas = nil
        }
    }
}

struct LossySkipValue: Decodable {}

struct StremioTrailer: Decodable {
    var source: String?
    var type: String?
    var title: String?
}

struct StremioVideo: Decodable {
    var id: String?
    var name: String?
    var url: String?
    var src: String?
    var source: String?
    var type: String?
    var title: String?
    var season: Int?
    var episode: Int?
    var overview: String?
    var description: String?
    var released: String?
    var firstAired: String?
    var airDate: String?
    var premiereDate: String?
    var release_date: String?
    var air_date: String?
    var first_aired: String?
    var thumbnail: String?
    var additionalEpisodeDateStrings: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, name, url, src, source, type, title, season, episode, overview, description
        case released, firstAired, airDate, premiereDate, release_date, air_date, first_aired, thumbnail
        case behaviorHints, metadata, meta, additional, raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.decodeString(container, .id)
        name = Self.decodeString(container, .name)
        url = Self.decodeString(container, .url)
        src = Self.decodeString(container, .src)
        source = Self.decodeString(container, .source)
        type = Self.decodeString(container, .type)
        title = Self.decodeString(container, .title)
        season = Self.decodeInt(container, .season)
        episode = Self.decodeInt(container, .episode)
        overview = Self.decodeString(container, .overview)
        description = Self.decodeString(container, .description)
        released = Self.decodeString(container, .released)
        firstAired = Self.decodeString(container, .firstAired)
        airDate = Self.decodeString(container, .airDate)
        premiereDate = Self.decodeString(container, .premiereDate)
        release_date = Self.decodeString(container, .release_date)
        air_date = Self.decodeString(container, .air_date)
        first_aired = Self.decodeString(container, .first_aired)
        thumbnail = Self.decodeString(container, .thumbnail)

        let nestedKeys: [CodingKeys] = [.behaviorHints, .metadata, .meta, .additional, .raw]
        additionalEpisodeDateStrings = nestedKeys.flatMap { Self.decodeNestedEpisodeDateStrings(container, $0) }
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            if value.rounded() == value { return String(Int(value)) }
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func decodeNestedEpisodeDateStrings(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        guard let values = try? container.decodeIfPresent([String: LossyJSONValue].self, forKey: key) else { return [] }
        let dateKeys = ["released", "release_date", "air_date", "firstAired", "first_aired", "premiereDate"]
        return dateKeys.compactMap { values[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum LossyJSONValue: Decodable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value):
            if value.rounded() == value { return String(Int(value)) }
            return String(value)
        case .bool(let value): return String(value)
        case .null: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .null
    }
}

struct StremioMeta: Decodable {
    var id: String?
    var tmdbId: String?
    var imdbId: String?
    var tvdbId: String?
    var name: String?
    var type: String?
    var poster: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var genres: [String]?
    var imdbRating: String?
    var trailers: [StremioTrailer]?
    var videos: [StremioVideo]?
    var trailer: String?
    var preview: String?
    var previewVideo: String?
    var cast: [String]?
    var directors: [String]?

    enum CodingKeys: String, CodingKey {
        case id, tmdbId, tmdb_id, imdbId, imdb_id, tvdbId, tvdb_id, name, type, poster, background, logo, description, releaseInfo, genres, imdbRating, trailers, videos, trailer, preview, previewVideo
        case cast, director, directors, credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = StremioMeta.decodeString(container, .id)
        tmdbId = StremioMeta.decodeString(container, .tmdbId) ?? StremioMeta.decodeString(container, .tmdb_id)
        imdbId = StremioMeta.decodeString(container, .imdbId) ?? StremioMeta.decodeString(container, .imdb_id)
        tvdbId = StremioMeta.decodeString(container, .tvdbId) ?? StremioMeta.decodeString(container, .tvdb_id)
        name = StremioMeta.decodeString(container, .name)
        type = StremioMeta.decodeString(container, .type)
        poster = StremioMeta.decodeString(container, .poster)
        background = StremioMeta.decodeString(container, .background)
        logo = StremioMeta.decodeString(container, .logo)
        description = StremioMeta.decodeString(container, .description)
        releaseInfo = StremioMeta.decodeString(container, .releaseInfo)
        imdbRating = StremioMeta.decodeString(container, .imdbRating)
        trailer = StremioMeta.decodeString(container, .trailer)
        preview = StremioMeta.decodeString(container, .preview)
        previewVideo = StremioMeta.decodeString(container, .previewVideo)

        if let castArray = try? container.decodeIfPresent([String].self, forKey: .cast) {
            cast = castArray
        } else if let castString = StremioMeta.decodeString(container, .cast) {
            cast = castString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            cast = nil
        }

        if let directorArray = try? container.decodeIfPresent([String].self, forKey: .directors) {
            directors = directorArray
        } else if let directorString = StremioMeta.decodeString(container, .director) ?? StremioMeta.decodeString(container, .directors) {
            directors = directorString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            directors = nil
        }

        if let genreArray = try? container.decodeIfPresent([String].self, forKey: .genres) {
            genres = genreArray
        } else if let singleGenre = try? container.decodeIfPresent(String.self, forKey: .genres) {
            genres = [singleGenre]
        } else if let mixedGenres = try? container.decodeIfPresent([LossyJSONValue].self, forKey: .genres) {
            genres = mixedGenres.compactMap { $0.stringValue }
        } else {
            genres = nil
        }

        // Trailer/video objects vary by addon. Do not let optional media decorations break the whole catalog row.
        trailers = (try? container.decodeIfPresent([StremioTrailer].self, forKey: .trailers)) ?? nil
        videos = (try? container.decodeIfPresent([StremioVideo].self, forKey: .videos)) ?? nil
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            if value.rounded() == value { return String(Int(value)) }
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case movies = "Movies"
    case shows = "Shows"
    case sports = "Sports"
    case favorites = "Favorites"
    case live = "Live TV"
    case membership = "Membership"
    case settings = "Settings"
    var id: String { rawValue }
}

struct LiveTVFocusSnapshot: Equatable {
    // v977 Phase 5: lightweight Live TV navigation state only. Stable channel
    // identity strings let the rebuilt grid find the exact played card even when
    // a provider refresh regenerates numeric IDs or reorders the lineup.
    var playedChannelID: Int
    var playedChannelStreamURL: String
    var playedChannelTVGID: String
    var playedChannelNumber: String
    var playedChannelName: String
    var playedChannelSource: String
    var focusedChannelID: Int
    var channelIndex: Int
    var categoryID: String
    var renderedWindowStart: Int
    var origin: String
    var showGuide: Bool
    var capturedAt: Date
}

// v1072: records where the currently presented media-information stage originated.
// Search results use the darker Search-owned presentation backdrop without a connector;
// nested episode/related navigation preserves the same origin until dismissal.
enum DetailPresentationOrigin: String {
    case catalog
    case search
    // v1088: Favorites keeps its own background/rail mounted and presents the
    // existing media-information popup locally without the catalog connector.
    case favorites
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published var rows: [MediaRow] = [] { didSet { catalogRowsRevision &+= 1 } }
    // vBRDC325: rows already emits objectWillChange. Publishing a second revision for the
    // same assignment invalidated every CatalogStore observer twice for one catalog commit.
    private(set) var catalogRowsRevision: UInt64 = 0
    @Published private(set) var builtInCatalogRowDescriptors: [BuiltInCatalogRowDescriptor] = []
    @Published var selectedTab: AppTab = .live {
        didSet {
            guard selectedTab != oldValue else { return }
            UnityAppCore.shared.observeLegacyTabMutation(
                from: oldValue,
                to: selectedTab,
                reason: "CatalogStore compatibility bridge"
            )
        }
    }
    // vBRDC090: operational/debug status is intentionally NOT @Published.
    // It changes hundreds of times across provider discovery, source resolution, playback
    // preparation, catalog enrichment and background services. No rendered view reads it
    // directly; it is consumed synchronously to build user-facing dedicated state. Publishing
    // it used to invalidate every @EnvironmentObject CatalogStore subscriber — dozens of
    // catalog, Live TV and settings views — for text that was not on screen.
    var status: String = "Loading catalogs…"
    @Published var addonIdentities: [String: StremioAddonIdentity] = [:]
    // vBRDC182: this compatibility counter no longer publishes through CatalogStore.
    // Its only job is to bridge legacy focus requests into the persistent UNITY shell;
    // publishing it used to invalidate every CatalogStore subscriber for a navigation-only event.
    var menuFocusToken: Int = 0 {
        didSet {
            guard menuFocusToken != oldValue else { return }
            UnityAppCore.shared.requestTopNavigationFocus(
                origin: selectedTab,
                reason: "CatalogStore menuFocusToken compatibility bridge"
            )
        }
    }
    @Published var contentFocusToken: Int = 0
    @Published var topMenuFocusLocked: Bool = false
    // vBRDC131: selected navigation and catalog presentation are separate state.
    // Home / Movies / TV Shows can remain the selected top-menu category while Back
    // dismisses their persistent catalog branch to the UNITY root. Selecting/Down into
    // that same category presents the already-mounted rows again without changing tabs.
    @Published var catalogRowsPresented: Bool = false
    // vBRDC132: transient top-menu focus hold. This never changes the tvOS focus graph.
    // It is active after catalog Back so the selected category stays highlighted while
    // focus returns to its top-menu item. Select/tap opens that category normally; Down is
    // intentionally independent and always returns to the persistent Live TV grid.
    var topMenuSelectionHoldTab: AppTab? = nil
    // Explicit Down-edge token for Live TV. Unlike vBRDC127 this does not make grid cards
    // conditionally focusable; it simply asks the already-mounted native grid to accept
    // focus after the top menu voluntarily yields it.
    @Published var liveTVMenuFocusEntryToken: Int = 0
    @Published var liveQuickPanelOpen: Bool = false
    @Published var liveTVFocusSnapshot: LiveTVFocusSnapshot? = nil
    @Published var liveTVFocusRestoreToken: Int = 0
    // vBRDC142: full-screen VOD removes the persistent LiveTVScreen from the render tree.
    // These non-published generations let the newly mounted root consume exactly one bounded
    // artwork rehydration pass after a movie/show closes, even when Movies/Shows still covers
    // Live TV. They deliberately do not invalidate CatalogStore observers themselves.
    var liveTVPostVODArtworkRecoveryGeneration: UInt64 = 0
    var liveTVPostVODArtworkRecoveryConsumedGeneration: UInt64 = 0
    @Published var isLoading: Bool = false
    @Published var manifestURLs: [String] = []
    @Published var selectedDetail: MediaItem? = nil
    // v1061: immutable row-to-detail presentation identity. The catalog hero keeps this
    // exact item pinned while Details mounts and while focus is restored after Back, so a
    // transient FocusState jump cannot expose the previous/first-row logo for one frame.
    @Published private(set) var detailPresentationAnchorItem: MediaItem? = nil
    // vBRDC040: the catalog row/focused-card backdrop and the clicked-detail backdrop
    // are deliberately separate presentation layers again. The row anchor remains immutable;
    // only this detail-only URL may upgrade after the popup opens.
    @Published private(set) var detailPremiumBackdropURL: String? = nil
    @Published private(set) var detailPresentationRevision: UInt64 = 0
    @Published private(set) var detailPresentationOrigin: DetailPresentationOrigin = .catalog
    @Published var playbackURL: URL? = nil
    // Phase 0: the user-selected stable source is retained for the entire playback
    // session. Future experimental bridge/handoff phases may replace playbackURL,
    // but emergency rollback always has an immutable source to restore immediately.
    @Published private(set) var originalPlaybackURL: URL? = nil
    @Published private(set) var experimentalPlaybackURL: URL? = nil
    @Published private(set) var activeExperimentalPlaybackFeature: StableFeatureGateManager.Feature? = nil
    @Published private(set) var experimentalPlaybackHandoffID: UUID? = nil
    // Phase 4: an in-place KSPlayer bridge keeps the root VOD presentation identity
    // stable. The owner UUID lets callbacks from the outgoing render generation be
    // rejected without replacing the whole VOD screen.
    @Published private(set) var experimentalPlaybackOwnerPresentationID: UUID? = nil
    @Published var playbackItem: MediaItem? = nil
    // vBRDC229: one launch cover is published before playbackURL. The root keeps this
    // artwork mounted across Media Information -> player replacement and releases it
    // only after the active renderer reports a genuine first frame.
    @Published private(set) var playbackLaunchCoverItem: MediaItem? = nil
    @Published private(set) var playbackLaunchCoverPresentationID: UUID? = nil
    @Published private(set) var playbackLaunchCoverActive: Bool = false
    // v1054: every full-screen playback launch receives a fresh immutable identity.
    // URL alone is not a safe SwiftUI/session key because the same source can be reopened,
    // and a fallback can overlap the departing representable for one render turn.
    @Published private(set) var playbackPresentationID: UUID = UUID()
    @Published var playbackFallbackURLs: [URL] = []
    // vBRDC089: HTTP request context is session-scoped exactly like the selected URL.
    // Fallbacks keep their own header sets because two providers can require different
    // cookies/referers even when they resolve the same title.
    @Published private(set) var playbackHTTPHeaders: [String: String] = [:]
    private var playbackFallbackHTTPHeaders: [String: [String: String]] = [:]
    // Phase 6: startup failover is owned by the exact replacement presentation.
    // The context survives the root VOD screen remount long enough to show the brief
    // user notice and re-queue the saved resume point on the next ranked source.
    @Published private(set) var automaticSourceFailoverContext: AutomaticSourceFailoverContext? = nil
    @Published var playbackSubtitleURLs: [URL] = []
    @Published var playbackLinkLabel: String = ""
    // vBRDC168: transport-only metadata for adaptive VOD cache planning. Kept out of
    // playbackLinkLabel so the user-facing status/chips remain clean.
    @Published private(set) var playbackAdaptiveCacheHint: String = ""
    @Published var playbackSourceTrackSummary: RealMediaTrackSummary? = nil
    @Published var streamLinks: [StreamLink] = [] {
        didSet { rebuildReadyPlaybackSources(from: streamLinks) }
    }
    @Published var selectedSourceProvider: String = "All Providers"
    @Published var sourceProviderStatuses: [SourceProviderRequestStatus] = []
    @Published var sourceIntelligenceBatchStatus: String = ""
    // v1099 Phase 5 Catalog Health is updated only at provider/page boundaries. It
    // does not poll or invalidate catalog rails while the diagnostics page is closed.
    @Published private(set) var catalogHealthProviderStatuses: [CatalogProviderHealth] = []
    @Published private(set) var catalogHealthFailedPages: [CatalogPageFailure] = []
    @Published private(set) var catalogHealthLastSuccessfulRefresh: Date? = nil
    @Published private(set) var catalogHealthLastFullPaginationRefresh: Date? = nil
    @Published private(set) var catalogHealthRefreshInProgress: Bool = false
    @Published private(set) var catalogHealthRevision: UInt64 = 0
    // vBRDC223 Phase 5: Catalog Health becomes a lightweight view into the shared
    // backend artwork cache. Heavy bulk preload/maintenance remains server-owned.
    @Published private(set) var sharedArtworkCacheReachable: Bool = false
    @Published private(set) var sharedArtworkCacheFiles: Int = 0
    @Published private(set) var sharedArtworkCacheBytes: Int64 = 0
    @Published private(set) var sharedArtworkCacheInflight: Int = 0
    @Published private(set) var sharedArtworkCachePreloadPercent: Double = 0
    @Published private(set) var sharedArtworkCachePreloadRunning: Bool = false
    @Published private(set) var sharedArtworkCacheFailed: Int = 0
    @Published private(set) var sharedArtworkCachePredictiveQueued: Int = 0
    @Published private(set) var sharedArtworkCachePredictiveActive: Int = 0
    @Published private(set) var sharedArtworkCacheMessage: String = "Not checked"
    @Published private(set) var sharedArtworkCacheLastChecked: Date? = nil
    private var catalogHealthRowPaginationStates: [String: String] = [:]
    private var catalogHealthPaginationFailureBuffer: [CatalogPageFailure] = []
    @Published var alternateAudioSources: [AlternateAudioSource] = []
    @Published var selectedAlternateAudioSource: AlternateAudioSource? = nil
    @Published var alternateAudioSyncOffsetMS: Int = 0
    @Published private(set) var alternateAudioDiscoveryState: AlternateAudioDiscoveryState = .idle
    @Published private(set) var alternateAudioDiscoveryMessage: String = "Not scanned"
    private var alternateAudioDiscoveryGeneration: UInt64 = 0
    private var alternateAudioDiscoveryRequestID: UUID? = nil
    @Published private(set) var alternateAudioBridgeState: AlternateAudioBridgeState = .idle
    @Published private(set) var alternateAudioBridgeMessage: String = "Bridge not prepared"
    @Published private(set) var preparedAlternateAudioBridge: AlternateAudioBridgeSession? = nil
    @Published private(set) var alternateAudioFailedHandoffs: [String] = []
    private var alternateAudioBridgeGeneration: UInt64 = 0
    private var alternateAudioBridgeRequestID: UUID? = nil
    @Published var lastStreamMessage: String = ""
    @Published private(set) var vodExclusivePlaybackActive: Bool = false
    // vBRDC184: user-invoked Home/Movies/TV Shows browsing may intentionally coexist
    // with an active player. This is NOT a global exclusive-playback bypass: only the
    // detail/source methods below consult it, so catalog refresh/prefetch/background work
    // remains suspended while the decoder owns the frame budget.
    @Published private(set) var playbackUnityBrowseActive: Bool = false

    private var playbackUnityBrowseInteractionAllowed: Bool {
        playbackUnityBrowseActive || (!vodExclusivePlaybackActive && !VODExclusivePlaybackGate.isActive)
    }

    func setPlaybackUnityBrowseActive(_ active: Bool, reason: String) {
        guard playbackUnityBrowseActive != active else { return }
        playbackUnityBrowseActive = active
        print("[PlaybackUnity][vBRDC184] browse=\(active) reason=\(reason)")
    }

    // v462: Track which detail item owns the current link-search results.
    // This prevents Movie A / Show A links from staying visible after the user
    // opens Movie B / Show B, and also blocks older async searches from
    // writing stale links back into the picker after navigation.
    private var activeStreamSearchItemID: String? = nil
    private var activeStreamSearchGeneration: Int = 0
    // vBRDC040: In-S providers now resolve independently and publish as each provider
    // completes, matching Nuvio's streaming provider fan-out. Keep these links separate
    // from durable addon/debrid results because the opaque playback sessions are short-lived.
    private var activeInSProviderTasks: [Task<Void, Never>] = []
    private var activeInSResolverTask: Task<MediaItem, Never>? = nil
    private var activeInSIncrementalLinks: [StreamLink] = []
    // vBRDC073: TorBox Usenet runs beside the ordinary addon fan-out, so keep an explicit
    // handle for it. vBRDC072 invalidated the shared URLSession while this detached search
    // task could still retain it and retry, which Foundation reports as an Objective-C
    // exception from __NSURLSessionLocal taskForClassInfo instead of a catchable Swift error.
    private var activeTorBoxUsenetTask: Task<([TorBoxUsenetSearchResult], String?), Never>? = nil
    private var sourceIntelligenceURLSession: URLSession = CatalogStore.makeSourceIntelligenceURLSession()
    // vBRDC212: official catalog fallback can fan out a dozen same-host row requests.
    // URLSession.shared is conservatively connection-limited; give catalog recovery its own
    // session so the bounded 12-lane client fan-out is not silently re-serialized underneath.
    private static let catalogFastURLSession: URLSession = CatalogStore.makeCatalogFastURLSession()
    // vBRDC212: Source Intelligence is cache-first inside the running app. Provider stream
    // URLs can be short lived, so this is deliberately a bounded process-memory cache rather
    // than a disk cache. Reopening the same title/episode is instant while a fresh provider
    // wave continues in parallel. Manifests are much more stable and receive a longer TTL so
    // every Find Links tap does not pay another DNS/TLS/manifest round trip.
    private struct SourceLinkMemoryCacheEntry {
        var createdAt: Date
        var links: [StreamLink]
    }
    private struct SourceManifestMemoryCacheEntry {
        var createdAt: Date
        var resolvedManifestURL: String
        var manifest: StremioManifest
    }
    // vBRDC229 Nuvio-style ready-source cache. Source Intelligence pays the small
    // URL/header/fallback shaping cost while links are visible, so selecting a resolved
    // source no longer walks every provider row on the first-frame critical path.
    private struct ReadyPlaybackSource {
        let primaryURL: URL
        let fallbackURLs: [URL]
        let fallbackHeaders: [String: [String: String]]
        let primaryHeaders: [String: String]
        let subtitles: [URL]
        let adaptiveCacheHint: String
        let sourceTrackSummary: RealMediaTrackSummary?
        let preparedAt: Date
    }
    private var readyPlaybackSourcesByURL: [String: ReadyPlaybackSource] = [:]
    private var readyPlaybackSourceGeneration: UInt64 = 0

    private var sourceLinkMemoryCache: [String: SourceLinkMemoryCacheEntry] = [:]
    private var sourceLinkMemoryCacheOrder: [String] = []
    private let sourceLinkMemoryCacheTTL: TimeInterval = 240
    private let sourceLinkMemoryCacheLimit = 48
    private var sourceManifestMemoryCache: [String: SourceManifestMemoryCacheEntry] = [:]
    private var sourceManifestMemoryCacheOrder: [String] = []
    private let sourceManifestMemoryCacheTTL: TimeInterval = 900
    private let sourceManifestMemoryCacheLimit = 32
    // vBRDC097: the very first Source Intelligence wave can race tvOS network bring-up,
    // DNS/TLS establishment, restored settings, and catalog bootstrap. A process restart
    // used to fix it only because that created a fresh URLSession after connectivity had
    // settled. Keep that recovery inside the app: exactly one automatic fresh-session
    // retry is permitted until any source search succeeds.
    private var sourceSearchHasSucceededThisSession = false
    private var sourceStartupRecoveryUsed = false
    // vBRDC212: Source Intelligence cache state above is intentionally independent of the
    // visible `streamLinks` array. It is bounded and expires quickly, so it accelerates repeat
    // opens without allowing stale signed playback URLs to survive indefinitely.
    private var detailCreditsTask: Task<Void, Never>? = nil
    private var detailPremiumArtworkTask: Task<Void, Never>? = nil
    // vBRDC075: cache the full alternate-artwork pool, not one frozen URL. Reopening a
    // title advances through Fanart/TVDB/backend/TMDB candidates instead of showing the
    // same detail image for the whole app session.
    private var detailPremiumBackdropSessionCache: [String: [String]] = [:]
    private var detailPremiumBackdropRotationCursor: [String: Int] = [:]
    private var detailOpenGeneration: UInt64 = 0
    // vBRDC092: Back can pre-stage the catalog focus while Media Information performs
    // its reverse animation. The final close consumes this flag so the same focus token
    // is not fired twice on adjacent frames.
    private var catalogDetailDismissalFocusHandoffPrepared = false
    // v996: lightweight, session-safe metadata cache used by the VOD overlay. This is
    // intentionally separate from Source Intelligence and remains available while the
    // catalog render tree is suspended for exclusive playback.
    private var playbackMetadataCache: [String: MediaItem] = [:]
    private var playbackMetadataCacheOrder: [String] = []
    private let playbackMetadataCacheLimit = 48
    // v1062: credits are cached by the full canonical identity, including S/E suffixes.
    // Anthology/guest-heavy episodes therefore never share cast results with the parent
    // series or a neighboring episode during the current app session.
    private var exactCreditsCache: [String: (castMembers: [CastMember], cast: [String], directors: [String])] = [:]
    private var exactCreditsCacheOrder: [String] = []
    private let exactCreditsCacheLimit = 72
    @Published var resolvedTrailerAudioURL: URL? = nil
    @Published var resolvedTrailerHTTPHeaders: [String: String] = [:]
    @Published var detailBackStack: [MediaItem] = []
    // v616: exact quick-panel focus restoration after closing Details Stage.
    @Published var quickPanelRestoreItemID: String? = nil
    // v1034 Phase 6: stable identity survives provider/id remapping after refresh.
    @Published var quickPanelRestoreCanonicalKey: String? = nil
    @Published var quickPanelRestoreIdentityItem: MediaItem? = nil
    @Published var quickPanelRestoreRowID: String? = nil
    @Published var quickPanelRestoreRowIndex: Int = 0
    @Published var quickPanelRestoreItemIndex: Int = 0
    @Published var quickPanelRestoreSection: String? = nil
    @Published var quickPanelRestoreFocusedCardID: String? = nil
    @Published var searchActive: Bool = false
    @Published var onboardingTourActive: Bool = false
    @Published var onboardingForceFullGuide: Bool = false
    // v1082: one process-local request opens the existing guide only on a true app launch.
    // Scene resume, tab changes, and playback return do not increment this token.
    @Published var guideStartupRequestToken: Int = 0

    private let manifestsKey = "stremioManifestURLs"
    private let allInOneCatalogsEnabledKey = "allInOneCatalogsEnabled"
    private let builtInCatalogHiddenRowIDsKey = "builtInCatalogHiddenRowIDs.v1009"
    private let builtInCatalogCustomRowOrderKey = "builtInCatalogCustomRowOrder.v1009"
    // vBRDC196: Trakt and local resume shelves participate in the same row customization
    // without ever entering the protected official catalog snapshot.
    // vBRDC197: account/external fast-launch caches must survive app updates. Versioned
    // keys caused every new build to look like a cold install and made Trakt shelves
    // disappear until the network refresh completed. Migrate the vBRDC196 keys once.
    private let traktCatalogRowsCacheKey = "traktCatalogRowsCache.v1"
    private let externalCatalogRowsCacheKey = "externalCatalogRowsCache.v1"
    private let legacyTraktCatalogRowsCacheKey = "traktCatalogRowsCache.vBRDC196"
    private let legacyExternalCatalogRowsCacheKey = "externalCatalogRowsCache.vBRDC196"
    // vBRDC198: one-time repair for vBRDC195-v197 saved orders that appended Trakt
    // after every built-in row. A verified Trakt account should surface its account
    // shelves first by default; once migrated, the normal customizer owns all later moves.
    private let traktRowsTopOrderMigrationKey = "catalogCustomization.traktRowsTop.vBRDC198"
    private let catalogHealthLastSuccessfulRefreshKey = "catalogHealthLastSuccessfulRefresh.v1099"
    private let catalogHealthLastFullPaginationRefreshKey = "catalogHealthLastFullPaginationRefresh.v1099"
    // v1008: the official all-in-one catalog remains an internal app service, not a
    // user-visible or removable saved manifest. The fixed HTTPS endpoint works both
    // inside and outside the home network while the toggle remains the only UI control.
    private let builtInAllInOneManifestURL = "https://catalog.skylinejay187.it.com/manifest.json"
    private let coreMetadataManifestURL = "https://v3-cinemeta.strem.io/manifest.json"
    private let trailerResolveCacheKey = "resolvedTrailerPlaybackURLCache.vBRDC008.v677-fast-hd-remux.v1"
    private let finalizedTrailerCacheDirectoryName = "DebridChannelsFinalizedTrailersV1162"
    private let finalizedTrailerCacheLimit = 8
    private let followedShowSnapshotsKey = "followedShowSnapshots.v659"
    private var trailerResolveMemoryCache: [String: String] = [:]
    private var trailerResolveMemoryOrder: [String] = []
    private let trailerResolveMemoryLimit = 128
    private var trailerResolveInflightTasks: [String: Task<URL?, Never>] = [:]
    // v1011 Phase 4C: focused-card previews use an isolated, memory-only 720p
    // resolver cache. They never alter the normal trailer popup cache or audio state.
    private var focusedCardPreviewMemoryCache: [String: URL] = [:]
    private var focusedCardPreviewMemoryOrder: [String] = []
    private let focusedCardPreviewMemoryLimit = 24
    private var focusedCardPreviewDiskStageTask: Task<Void, Never>? = nil
    private var focusedCardPreviewDiskStageGeneration: UInt64 = 0
    private var catalogRowRefreshDebounceTasks: [String: Task<Void, Never>] = [:]
    private var catalogRowRefreshLastAttempt: [String: Date] = [:]
    private var catalogRowRefreshInFlight = Set<String>()
    private let catalogRowRefreshCooldown: TimeInterval = 95
    private let catalogRowRefreshMaxConcurrent = 2
    private let catalogRowsCacheKey = "stremioCatalogRowsCache.v1009.hiddenPublicBuiltInCatalogCustomization"
    // v1032 Phase 5: cache schema is kept out of UserDefaults so a malformed/partial
    // server response can never replace the complete official catalog snapshot.
    private let officialCatalogSnapshotSchemaVersion = 1
    // Phase 12B: 83 remains the durable/full catalog target, but a healthy provisional
    // response may be displayed on a first install instead of leaving the UI blank. Only
    // a complete 83-row result is promoted to the protected current/rollback snapshot.
    private let officialCatalogFullPublishedRows = 83
    private let officialCatalogMinimumProvisionalRows = 24
    private let officialCatalogMaximumSnapshotBytes = 24_000_000
    // vBRDC327: CatalogStore is MainActor-isolated; avoid repeatedly reading/decoding
    // the same protected multi-megabyte snapshot during validation/recovery.
    private var officialCatalogDecodedSnapshotCache: [String: [MediaRow]] = [:]
    private let metadataArtworkCacheKey = "metadataArtworkCache.v753.tmdbPrimary"
    private let addonSearchCacheKey = "addonSearchResultCache.v755.progressive"
    // v1010 Phase 4B: a memory-only flattened copy of the already downloaded official
    // rows. It includes rows hidden by Phase 4A preferences and is never persisted as a
    // second catalog payload. Recent merged searches are cached briefly in memory only.
    private var builtInUnifiedSearchIndex: [MediaItem] = []
    private var builtInUnifiedSearchURL: String? = nil
    private var builtInUnifiedBatchRowsURL: String? = nil
    private var unifiedSearchCache: [String: UnifiedSearchCacheEntry] = [:]
    private let unifiedSearchCacheTTL: TimeInterval = 90
    private let catalogFetchMaxConcurrent = 3
    private let catalogArtworkEnrichmentMaxConcurrent = 3
    private var catalogArtworkEnrichmentTask: Task<Void, Never>? = nil
    private var tmdbDefaultRowsRefreshTask: Task<Void, Never>? = nil
    // vBRDC196: Trakt remains an account layer above the protected official snapshot, but
    // its last-known-good shelves are cached separately so relaunch never makes them blink
    // away while the network refresh is running.
    private var traktCatalogRefreshTask: Task<Void, Never>? = nil
    private var traktPostPlaybackRefreshTask: Task<Void, Never>? = nil
    // vBRDC202: account shelf JSON encoding/UserDefaults persistence must not run on the
    // MainActor at the same moment a newly published row mounts and starts artwork decode.
    private let catalogPersistenceQueue = DispatchQueue(label: "DebridChannels.CatalogStore.persistence", qos: .utility)
    private var traktCatalogLastRefreshAt: Date? = nil
    private var traktCatalogRefreshPending = false
    private let traktCatalogRefreshTTL: TimeInterval = 300
    // vBRDC210: cold-launch Resume rows can exist before any normal catalog surface has
    // donated artwork. Keep a tiny process-local visual overlay while TMDB hydration is
    // persisted asynchronously, so first paint does not depend on visiting another tab.
    private struct ResumeColdArtworkOverride {
        let posterURL: String?
        let landscapeURL: String?
        let logoURL: String?
    }
    private struct ResumeColdArtworkSeed: Sendable {
        let key: String
        let itemID: String
        let tmdbID: String?
        let imdbID: String?
        let title: String
        let year: String
        let type: String
    }
    private var resumeColdArtworkOverrides: [String: ResumeColdArtworkOverride] = [:]
    private var resumeColdArtworkHydrationTask: Task<Void, Never>? = nil
    private var resumeColdArtworkHydrationLastAttempt: Date? = nil
    private var catalogLoadInProgress = false
    // vBRDC196: identifies which catalog-mode generation owns the shared loading flag. A
    // toggle may supersede an old network request immediately without letting that old
    // request's defer block or clear the new mode's load state.
    private var catalogLoadOwnerGeneration: UInt64 = 0
    // v1040: only successful catalog publications satisfy duplicate refresh callers.
    // A failed/partial request must never suppress the next retry and force the user to
    // toggle All-in-One repeatedly before the complete row set appears.
    private var catalogLoadLastSuccessfulCompletionAt: Date? = nil
    private var catalogRefreshRequestedAfterActivation = false
    private var catalogLifecycleGeneration: UInt64 = 0
    // Phase 12A: failed official refreshes keep the durable rows visible and retry
    // quietly forever. The delay tops out at five minutes so recovery is persistent
    // without hammering the service or blocking catalog interaction.
    private var catalogRecoveryRetryTask: Task<Void, Never>? = nil
    private var catalogRecoveryRetryAttempt: Int = 0
    private var catalogRecoveryRetryGeneration: UInt64 = 0
    private var catalogSceneActive: Bool = true
    // vBRDC004: OS scene-active is not enough to decide whether catalog repair/enrichment
    // work may run. Live TV playback keeps the app scene active, so background catalog work
    // previously remained eligible to wake while the full-screen decoder owned the frame.
    private var fullScreenPlaybackResourceSuspended: Bool = false
    // vBRDC212: first-load recovery should feel active, not abandoned. Back off quickly
    // after the first two retries, then settle into the existing low-frequency repair lane.
    private let catalogRecoveryRetryDelays: [TimeInterval] = [1, 3, 8, 20, 45, 90, 180]

    private func rememberFocusedCardPreviewURL(_ url: URL, forKey key: String) {
        focusedCardPreviewMemoryOrder.removeAll { $0 == key }
        focusedCardPreviewMemoryOrder.append(key)
        focusedCardPreviewMemoryCache[key] = url
        while focusedCardPreviewMemoryOrder.count > focusedCardPreviewMemoryLimit {
            let removed = focusedCardPreviewMemoryOrder.removeFirst()
            focusedCardPreviewMemoryCache.removeValue(forKey: removed)
        }
    }

    private func rememberPlaybackMetadata(_ item: MediaItem, forKey key: String) {
        playbackMetadataCacheOrder.removeAll { $0 == key }
        playbackMetadataCacheOrder.append(key)
        playbackMetadataCache[key] = item
        while playbackMetadataCacheOrder.count > playbackMetadataCacheLimit {
            let removed = playbackMetadataCacheOrder.removeFirst()
            playbackMetadataCache.removeValue(forKey: removed)
        }
    }

    private func rememberExactCredits(
        _ credits: (castMembers: [CastMember], cast: [String], directors: [String]),
        forKey key: String
    ) {
        exactCreditsCacheOrder.removeAll { $0 == key }
        exactCreditsCacheOrder.append(key)
        exactCreditsCache[key] = credits
        while exactCreditsCacheOrder.count > exactCreditsCacheLimit {
            let removed = exactCreditsCacheOrder.removeFirst()
            exactCreditsCache.removeValue(forKey: removed)
        }
    }

    private func cancelCatalogRecoveryRetry(resetAttempt: Bool) {
        catalogRecoveryRetryGeneration &+= 1
        catalogRecoveryRetryTask?.cancel()
        catalogRecoveryRetryTask = nil
        if resetAttempt { catalogRecoveryRetryAttempt = 0 }
    }

    private func scheduleCatalogRecoveryRetry(reason: String) {
        guard allInOneCatalogsEnabled else {
            cancelCatalogRecoveryRetry(resetAttempt: true)
            return
        }
        guard catalogSceneActive,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else {
            catalogRefreshRequestedAfterActivation = true
            return
        }

        catalogRecoveryRetryGeneration &+= 1
        let generation = catalogRecoveryRetryGeneration
        catalogRecoveryRetryTask?.cancel()
        let delayIndex = min(catalogRecoveryRetryAttempt, catalogRecoveryRetryDelays.count - 1)
        let delay = catalogRecoveryRetryDelays[delayIndex]
        catalogRecoveryRetryAttempt = min(catalogRecoveryRetryAttempt + 1, catalogRecoveryRetryDelays.count - 1)
        print("[CatalogPermanence][v1050] retry scheduled delay=\(Int(delay))s reason=\(reason)")

        catalogRecoveryRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == self.catalogRecoveryRetryGeneration,
                  self.allInOneCatalogsEnabled else { return }
            guard self.catalogSceneActive,
                  !self.fullScreenPlaybackResourceSuspended,
                  !self.vodExclusivePlaybackActive,
                  !VODExclusivePlaybackGate.isActive else {
                self.catalogRefreshRequestedAfterActivation = true
                return
            }
            self.catalogRecoveryRetryTask = nil
            await self.loadAllManifests()
        }
    }

    func setFullScreenPlaybackResourceSuspended(_ suspended: Bool, reason: String) {
        if fullScreenPlaybackResourceSuspended == suspended {
            if !suspended,
               catalogSceneActive,
               catalogRefreshRequestedAfterActivation,
               (allInOneCatalogsEnabled),
               !vodExclusivePlaybackActive,
               !VODExclusivePlaybackGate.isActive {
                scheduleCatalogRecoveryRetry(reason: "playback gates fully released")
            }
            return
        }
        fullScreenPlaybackResourceSuspended = suspended

        if suspended {
            // Cancel only catalog/decorative work. Playback-owned source intelligence,
            // trailer state, resume/source identity, and player sessions are deliberately
            // outside this gate.
            if catalogLoadInProgress || catalogRecoveryRetryTask != nil || !catalogRowRefreshDebounceTasks.isEmpty {
                catalogRefreshRequestedAfterActivation = true
            }
            cancelFocusedCardPreviewDiskStage()
            cancelCatalogRecoveryRetry(resetAttempt: false)
            catalogLifecycleGeneration &+= 1
            for task in catalogRowRefreshDebounceTasks.values { task.cancel() }
            catalogRowRefreshDebounceTasks.removeAll()
            catalogRowRefreshInFlight.removeAll()
            catalogArtworkEnrichmentTask?.cancel()
            catalogArtworkEnrichmentTask = nil
            tmdbDefaultRowsRefreshTask?.cancel()
            tmdbDefaultRowsRefreshTask = nil
            traktCatalogRefreshTask?.cancel()
            traktCatalogRefreshTask = nil
            resumeColdArtworkHydrationTask?.cancel()
            resumeColdArtworkHydrationTask = nil
            detailCreditsTask?.cancel()
            detailCreditsTask = nil
            detailPremiumArtworkTask?.cancel()
            detailPremiumArtworkTask = nil
            print("[FrameBudget][vBRDC004] suspended catalog repair/enrichment for full-screen playback reason=\(reason)")
            return
        }

        // Do not burst a full catalog reload on the first frame after playback closes.
        // If a repair was interrupted, reuse the existing bounded retry/backoff lane.
        if !catalogLoadInProgress { isLoading = false }
        if catalogSceneActive,
           catalogRefreshRequestedAfterActivation,
           (allInOneCatalogsEnabled) {
            scheduleCatalogRecoveryRetry(reason: "playback ended after deferred catalog work")
        }
        print("[FrameBudget][vBRDC004] catalog repair/enrichment eligible after playback reason=\(reason)")
    }

    func handlePhase7SceneBecameInactive() {
        catalogSceneActive = false
        cancelFocusedCardPreviewDiskStage()
        // v1040/Phase 12A: remember interrupted refresh and retry work. Foreground
        // activation republishes the durable catalog first, then resumes network repair.
        if catalogLoadInProgress || catalogRecoveryRetryTask != nil {
            catalogRefreshRequestedAfterActivation = true
        }
        cancelCatalogRecoveryRetry(resetAttempt: false)
        catalogLifecycleGeneration &+= 1
        detailOpenGeneration &+= 1
        for task in catalogRowRefreshDebounceTasks.values { task.cancel() }
        catalogRowRefreshDebounceTasks.removeAll()
        catalogRowRefreshInFlight.removeAll()
        catalogArtworkEnrichmentTask?.cancel()
        catalogArtworkEnrichmentTask = nil
        tmdbDefaultRowsRefreshTask?.cancel()
        tmdbDefaultRowsRefreshTask = nil
        traktCatalogRefreshTask?.cancel()
        traktCatalogRefreshTask = nil
        resumeColdArtworkHydrationTask?.cancel()
        resumeColdArtworkHydrationTask = nil
        detailCreditsTask?.cancel()
        detailCreditsTask = nil
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        detailPremiumBackdropURL = nil
        for task in trailerResolveInflightTasks.values { task.cancel() }
        trailerResolveInflightTasks.removeAll()
        activeStreamSearchGeneration &+= 1
        cancelActiveSourceProviderTasks()
        rotateSourceIntelligenceURLSession()
        PremiumRemoteImageLoader.suspendForBackground()
        isLoading = false
        Task {
            await CatalogHeroMetadataCache.shared.suspendNetworkWork()
            await FocusedCardPreviewDiskCache.shared.performMaintenance(aggressive: false)
        }
        print("[ReleaseLifecycle][Phase7] suspended catalog/search/preview work")
    }

    func handlePhase7SceneBecameActive() {
        catalogSceneActive = true
        if let detail = selectedDetail {
            if detailPremiumBackdropURL == nil {
                schedulePremiumDetailArtwork(for: detailPresentationAnchorItem ?? detail, generation: detailOpenGeneration)
            }
            hydrateCreditsForOpenDetail(detail, generation: detailOpenGeneration)
        }

        // Phase 12A: foreground never waits for the network to make the catalog usable.
        let restoredDurableCatalog = restoreBestOfficialCatalogCacheIfNeeded(reason: "foreground activation")
        let shouldRepairCatalog = catalogRefreshRequestedAfterActivation
            || restoredDurableCatalog
            || officialCatalogRowsNeedRecovery()
        catalogRefreshRequestedAfterActivation = false
        if shouldRepairCatalog, !vodExclusivePlaybackActive, !VODExclusivePlaybackGate.isActive {
            VODExclusiveWorkRegistry.start { await self.loadAllManifests() }
        }

        Task {
            await CatalogHeroMetadataCache.shared.performMaintenance()
            await FocusedCardPreviewDiskCache.shared.performMaintenance(aggressive: false)
        }
    }

    /// v1055 catalog completeness target. The compact launch cache deliberately stores
    /// only eight rows, so its descriptor list must never be mistaken for the complete
    /// official manifest. The known 83-row publication target remains the floor, while
    /// a newer loaded snapshot/manifest can raise it. Hidden preferences are subtracted
    /// only when their row IDs are present in the currently known descriptor set.
    private func expectedVisibleOfficialCatalogRowCount() -> Int {
        guard allInOneCatalogsEnabled else { return 0 }

        let descriptorIDs = Set(builtInCatalogRowDescriptors.map(\.id))
        let publishedTarget = max(officialCatalogFullPublishedRows, descriptorIDs.count)
        let savedHidden = Set(UserDefaults.standard.stringArray(forKey: builtInCatalogHiddenRowIDsKey) ?? [])
        let validHiddenCount = savedHidden.intersection(descriptorIDs).count
        return max(0, publishedTarget - validHiddenCount)
    }

    // vBRDC091: Root can avoid creating a delayed watchdog task at all when the official
    // catalog is already complete. This is a cheap count-only gate; it does not trigger
    // provider/network work or publish state.
    var catalogCompletenessNeedsRecovery: Bool {
        allInOneCatalogsEnabled && officialCatalogRowsNeedRecovery()
    }

    /// v1055 foreground/watchdog self-healing. This compares the actual visible row
    /// count with the complete official target rather than the compact eight-row cache.
    private func officialCatalogRowsNeedRecovery() -> Bool {
        guard allInOneCatalogsEnabled else { return false }
        let expectedVisible = expectedVisibleOfficialCatalogRowCount()
        guard expectedVisible > 0 else { return false }
        return rows.count < expectedVisible
    }

    var debridChannelsCatalogRowProgressText: String {
        guard allInOneCatalogsEnabled else { return "Debrid Channels catalogs are turned off." }
        let expected = expectedVisibleOfficialCatalogRowCount()
        if expected == 0 { return "All Debrid Channels rows are hidden by customization." }
        return "Showing \(rows.count) of \(expected) Debrid Channels catalog rows."
    }

    // MARK: - v1099 Phase 5 Catalog Health

    var catalogHealthSnapshot: CatalogHealthSnapshot {
        var visibleRowsByID: [String: MediaRow] = [:]
        for row in rows where visibleRowsByID[row.id] == nil { visibleRowsByID[row.id] = row }
        var visibleRowsByTitle: [String: MediaRow] = [:]
        for row in rows where visibleRowsByTitle[normalizedCatalogName(row.title)] == nil {
            visibleRowsByTitle[normalizedCatalogName(row.title)] = row
        }

        let descriptorHealth: [CatalogRowHealth] = builtInCatalogRowDescriptors.map { descriptor in
            let row = visibleRowsByID[descriptor.id] ?? visibleRowsByTitle[normalizedCatalogName(descriptor.title)]
            let count = row?.items.count ?? 0
            return CatalogRowHealth(
                id: descriptor.id,
                title: descriptor.title,
                posterCount: count,
                paginationState: catalogHealthRowPaginationStates[descriptor.id]
                    ?? (catalogHealthLastFullPaginationRefresh == nil ? "Cached / first page" : "Full pagination checked"),
                provider: row?.presentation?.providerName ?? row?.items.first?.addonName ?? "Debrid Channels",
                failed: row == nil || count == 0
            )
        }

        let descriptorIDs = Set(descriptorHealth.map(\.id))
        let extraHealth = rows.filter { !descriptorIDs.contains($0.id) }.map { row in
            CatalogRowHealth(
                id: row.id,
                title: row.title,
                posterCount: row.items.count,
                paginationState: catalogHealthRowPaginationStates[row.id] ?? "Loaded",
                provider: row.presentation?.providerName ?? row.items.first?.addonName ?? "Catalog provider",
                failed: row.items.isEmpty
            )
        }
        let rowHealth = descriptorHealth.isEmpty ? extraHealth : descriptorHealth + extraHealth
        let providers = catalogHealthProviderStatuses.isEmpty
            ? catalogBrowsingManifestURLs().map { url in
                CatalogProviderHealth(
                    id: url,
                    name: catalogHealthProviderName(for: url),
                    endpoint: catalogHealthEndpointLabel(for: url),
                    state: rows.isEmpty ? .checking : .cached,
                    loadedRows: 0,
                    message: rows.isEmpty ? "Waiting for first health check" : "Using the last-known-good catalog"
                )
            }
            : catalogHealthProviderStatuses
        let expected = allInOneCatalogsEnabled
            ? expectedVisibleOfficialCatalogRowCount()
            : max(rows.count, builtInCatalogRowDescriptors.count)

        return CatalogHealthSnapshot(
            configuredProviders: providers,
            expectedRows: expected,
            loadedRows: rows.count,
            totalPosters: rows.reduce(0) { $0 + $1.items.count },
            rows: rowHealth,
            lastSuccessfulRefresh: catalogHealthLastSuccessfulRefresh
                ?? catalogLoadLastSuccessfulCompletionAt
                ?? (UserDefaults.standard.object(forKey: catalogHealthLastSuccessfulRefreshKey) as? Date),
            lastFullPaginationRefresh: catalogHealthLastFullPaginationRefresh
                ?? (UserDefaults.standard.object(forKey: catalogHealthLastFullPaginationRefreshKey) as? Date),
            failedProviders: providers.filter { $0.state == .failed || $0.state == .noRows },
            timedOutProviders: providers.filter { $0.state == .timedOut },
            failedPages: catalogHealthFailedPages,
            refreshInProgress: catalogHealthRefreshInProgress || catalogLoadInProgress
        )
    }

    private func catalogHealthProviderName(for url: String) -> String {
        if isAllInOneManifestURL(url) { return "Debrid Channels" }
        if isCinemetaManifest(url) { return "Cinemeta" }
        if let name = addonIdentities[url]?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return URL(string: url)?.host ?? "Catalog provider"
    }

    private func catalogHealthEndpointLabel(for url: String) -> String {
        guard let parsed = URL(string: url) else { return "Configured manifest" }
        let host = parsed.host ?? "configured endpoint"
        return parsed.scheme.map { "\($0)://\(host)" } ?? host
    }

    private func catalogHealthTimedOut(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out") || lower.contains("timeout")
    }

    private func recordCatalogProviderHealth(
        url: String,
        name: String? = nil,
        state: CatalogProviderHealthState,
        loadedRows: Int,
        message: String
    ) {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entry = CatalogProviderHealth(
            id: url,
            name: cleanName.isEmpty ? catalogHealthProviderName(for: url) : cleanName,
            endpoint: catalogHealthEndpointLabel(for: url),
            state: state,
            loadedRows: loadedRows,
            message: message
        )
        if let index = catalogHealthProviderStatuses.firstIndex(where: { $0.id == url }) {
            catalogHealthProviderStatuses[index] = entry
        } else {
            catalogHealthProviderStatuses.append(entry)
        }
        catalogHealthRevision &+= 1
    }

    @MainActor
    func refreshSharedArtworkCacheHealth() async {
        let configuredBase = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: configuredBase + "/api/artwork/shared-cache/status") else {
            sharedArtworkCacheReachable = false
            sharedArtworkCacheMessage = "Backend URL is invalid."
            sharedArtworkCacheLastChecked = Date()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            sharedArtworkCacheReachable = (root["ok"] as? Bool) ?? true
            sharedArtworkCacheFiles = root["files"] as? Int ?? Int((root["files"] as? NSNumber)?.intValue ?? 0)
            sharedArtworkCacheBytes = (root["bytes"] as? NSNumber)?.int64Value ?? 0
            sharedArtworkCacheInflight = (root["inflightDownloads"] as? NSNumber)?.intValue ?? 0
            if let preload = root["preload"] as? [String: Any] {
                sharedArtworkCachePreloadRunning = (preload["running"] as? Bool) ?? false
                sharedArtworkCacheMessage = (preload["message"] as? String) ?? (sharedArtworkCachePreloadRunning ? "Backend preload running." : "Backend cache ready.")
                if let totals = preload["totals"] as? [String: Any] {
                    sharedArtworkCacheFailed = (totals["failed"] as? NSNumber)?.intValue ?? 0
                    let discovered = (totals["discovered"] as? NSNumber)?.doubleValue ?? 0
                    let processed = (totals["processed"] as? NSNumber)?.doubleValue ?? 0
                    sharedArtworkCachePreloadPercent = discovered > 0 ? min(100, max(0, processed * 100 / discovered)) : 0
                } else { sharedArtworkCachePreloadPercent = 0 }
            }
            if let predictive = root["predictive"] as? [String: Any] {
                sharedArtworkCachePredictiveQueued = (predictive["queued"] as? NSNumber)?.intValue ?? 0
                sharedArtworkCachePredictiveActive = (predictive["active"] as? NSNumber)?.intValue ?? 0
            }
            sharedArtworkCacheLastChecked = Date()
        } catch {
            sharedArtworkCacheReachable = false
            sharedArtworkCacheMessage = "Shared artwork backend unavailable: \(error.localizedDescription)"
            sharedArtworkCacheLastChecked = Date()
        }
        catalogHealthRevision &+= 1
    }

    @MainActor
    func retryFailedSharedArtwork() async {
        let configuredBase = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: configuredBase + "/api/artwork/shared-cache/retry-failed") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        do {
            _ = try await URLSession.shared.data(for: request)
            status = "Backend artwork retry requested."
        } catch {
            status = "Artwork retry failed: \(error.localizedDescription)"
        }
        await refreshSharedArtworkCacheHealth()
    }

    func refreshCatalogHealthSnapshot() {
        catalogHealthRevision &+= 1
        status = "Catalog Health snapshot refreshed."
    }

    func reloadCatalogHealthRow(rowID: String) async {
        guard let row = rows.first(where: { $0.id == rowID })
            ?? builtInCatalogRowDescriptors.first(where: { $0.id == rowID }).flatMap({ descriptor in
                rows.first(where: { normalizedCatalogName($0.title) == normalizedCatalogName(descriptor.title) })
            }) else {
            status = "The requested catalog row is not mounted. Reloading all catalogs instead…"
            await reloadDebridChannelsCatalogs()
            return
        }
        let key = canonicalCatalogRowRefreshKey(row)
        catalogRowRefreshLastAttempt.removeValue(forKey: key)
        await refreshCatalogRowIfNeeded(row: row, selectedItem: row.items.first, reason: "Catalog Health reload one row")
        catalogHealthRowPaginationStates[row.id] = row.items.isEmpty ? "Reload failed" : "Single-row reload checked"
        catalogHealthRevision &+= 1
    }

    func clearCatalogCachePreservingUserData() async {
        UserDefaults.standard.removeObject(forKey: catalogRowsCacheKey)
        UserDefaults.standard.removeObject(forKey: addonSearchCacheKey)
        UserDefaults.standard.removeObject(forKey: metadataArtworkCacheKey)
        for url in [officialCatalogSnapshotURL(), officialCatalogSnapshotURL(previous: true), officialCatalogProvisionalSnapshotURL()].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        catalogHealthFailedPages = []
        catalogHealthPaginationFailureBuffer = []
        catalogHealthRowPaginationStates = [:]
        catalogHealthLastSuccessfulRefresh = nil
        catalogHealthLastFullPaginationRefresh = nil
        UserDefaults.standard.removeObject(forKey: catalogHealthLastSuccessfulRefreshKey)
        UserDefaults.standard.removeObject(forKey: catalogHealthLastFullPaginationRefreshKey)
        catalogHealthRevision &+= 1
        status = "Catalog caches cleared. Accounts, providers, favorites, watch progress, and episode alerts were preserved. Reloading catalogs…"
        await loadAllManifests(forceOfficialRefresh: allInOneCatalogsEnabled)
    }

    /// vBRDC099 visible-surface bootstrap. Before Home/Movies/Shows paints an empty
    /// snapshot, synchronously republish the best durable official rows already on disk.
    /// This performs no network work; the bounded completeness lane may repair afterward.
    @discardableResult
    func forceVisibleCatalogReadiness(reason: String) -> Bool {
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return false }
        let restored = restoreBestOfficialCatalogCacheIfNeeded(reason: reason)
        if rows.isEmpty, allInOneCatalogsEnabled {
            catalogRefreshRequestedAfterActivation = true
        }
        return restored
    }

    /// Called by the app-level watchdog. It is intentionally quiet when an official
    /// refresh or its backoff retry is already active, preventing duplicate network work.
    func ensureDebridChannelsCatalogCompleteness(reason: String) async {
        guard allInOneCatalogsEnabled,
              catalogSceneActive,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive,
              officialCatalogRowsNeedRecovery() else { return }
        guard !catalogLoadInProgress, catalogRecoveryRetryTask == nil else { return }

        catalogRefreshRequestedAfterActivation = false
        status = "Only \(rows.count) Debrid Channels rows are available. Reloading the complete catalog automatically…"
        print("[CatalogCompleteness][v1055] automatic repair reason=\(reason) visible=\(rows.count) expected=\(expectedVisibleOfficialCatalogRowCount())")
        await loadAllManifests()
    }

    /// Dedicated manual command for the built-in Debrid Channels catalog. Unlike the
    /// generic personal-addon loader, this cancels a delayed recovery timer and requests
    /// an immediate official refresh while preserving the fullest durable rows on screen.
    func reloadDebridChannelsCatalogs() async {
        guard allInOneCatalogsEnabled else {
            status = "Turn on All-in-One Catalogs before reloading Debrid Channels catalogs."
            return
        }
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else {
            catalogRefreshRequestedAfterActivation = true
            status = "Debrid Channels catalog reload is queued until playback closes."
            return
        }

        cancelCatalogRecoveryRetry(resetAttempt: true)
        catalogRefreshRequestedAfterActivation = false
        catalogLoadLastSuccessfulCompletionAt = nil
        status = "Forcing Debrid Channels catalogs now…"
        print("[CatalogFastLoad][vBRDC213] manual official foreground reload requested")
        // First make rows visible using the manifest/batch/first-page path. Full pagination
        // is intentionally a second background pass so a long shelf can never make the
        // Reload button look stuck or hold Home/Movies/TV Shows empty.
        await loadAllManifests(forceOfficialRefresh: true, forceCompleteRows: false)
        if !Task.isCancelled,
           catalogLoadLastSuccessfulCompletionAt != nil,
           !fullScreenPlaybackResourceSuspended,
           !vodExclusivePlaybackActive,
           !VODExclusivePlaybackGate.isActive {
            let posterCount = rows.reduce(0) { $0 + $1.items.count }
            status = "Catalogs ready: \(rows.count) rows / \(posterCount) posters. Completing long shelves in the background…"
            VODExclusiveWorkRegistry.start { @MainActor [weak self] in
                guard let self else { return }
                await self.loadAllManifests(forceOfficialRefresh: true, forceCompleteRows: true)
            }
        }
    }

    func handlePhase7MemoryPressure() {
        cancelFocusedCardPreviewDiskStage()
        if allInOneCatalogsEnabled {
            catalogRefreshRequestedAfterActivation = true
        }
        cancelCatalogRecoveryRetry(resetAttempt: false)
        catalogLifecycleGeneration &+= 1
        activeStreamSearchGeneration &+= 1
        cancelActiveSourceProviderTasks()
        for task in catalogRowRefreshDebounceTasks.values { task.cancel() }
        catalogRowRefreshDebounceTasks.removeAll()
        catalogRowRefreshInFlight.removeAll()
        catalogArtworkEnrichmentTask?.cancel()
        catalogArtworkEnrichmentTask = nil
        tmdbDefaultRowsRefreshTask?.cancel()
        tmdbDefaultRowsRefreshTask = nil
        traktCatalogRefreshTask?.cancel()
        traktCatalogRefreshTask = nil
        for task in trailerResolveInflightTasks.values { task.cancel() }
        trailerResolveInflightTasks.removeAll()
        rotateSourceIntelligenceURLSession()
        sourceLinkMemoryCache.removeAll(keepingCapacity: false)
        sourceLinkMemoryCacheOrder.removeAll(keepingCapacity: false)
        sourceManifestMemoryCache.removeAll(keepingCapacity: false)
        sourceManifestMemoryCacheOrder.removeAll(keepingCapacity: false)
        unifiedSearchCache.removeAll(keepingCapacity: false)
        focusedCardPreviewMemoryCache.removeAll(keepingCapacity: false)
        focusedCardPreviewMemoryOrder.removeAll(keepingCapacity: false)
        playbackMetadataCache.removeAll(keepingCapacity: false)
        playbackMetadataCacheOrder.removeAll(keepingCapacity: false)
        exactCreditsCache.removeAll(keepingCapacity: false)
        exactCreditsCacheOrder.removeAll(keepingCapacity: false)
        PremiumRemoteImageLoader.handleMemoryPressure()
        Task {
            await CatalogHeroMetadataCache.shared.handleMemoryPressure()
            await FocusedCardPreviewDiskCache.shared.performMaintenance(aggressive: true)
        }
        print("[ReleaseLifecycle][Phase7] released optional caches for memory pressure")
    }

    private static func makeCatalogFastURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    private static func makeSourceIntelligenceURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // vBRDC212: foreground source discovery is a latency race. One offline/slow addon
        // must fail fast instead of holding every healthy provider behind a 35-60 second lane.
        // Provider fan-out is bounded separately, so raising the HTTP/1.1 per-host allowance
        // gives configured multi-account addons room to answer concurrently without a queue.
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }

    // vBRDC073 crash fix: never invalidate a URLSession that an in-flight async search may
    // still retain. Apple Foundation can throw an Objective-C exception (not a Swift Error)
    // when session.data(for:) is asked to create a task after invalidateAndCancel(). Rotate
    // to a fresh session for new work and cancel the old session's current tasks without
    // invalidating the old session object. Any already-retained reference therefore remains
    // legal to call, while generation + Task cancellation prevents stale results publishing.
    private func rotateSourceIntelligenceURLSession() {
        let retiringSession = sourceIntelligenceURLSession
        sourceIntelligenceURLSession = Self.makeSourceIntelligenceURLSession()
        retiringSession.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    private func cancelActiveSourceProviderTasks() {
        for task in activeInSProviderTasks { task.cancel() }
        activeInSProviderTasks.removeAll()
        activeInSResolverTask?.cancel()
        activeInSResolverTask = nil
        activeTorBoxUsenetTask?.cancel()
        activeTorBoxUsenetTask = nil
        activeInSIncrementalLinks.removeAll()
    }

    private func isOnDemandPlaybackItem(_ item: MediaItem) -> Bool {
        let markers = [item.type, item.catalog, item.year, item.addonName ?? ""]
            .joined(separator: " ")
            .lowercased()
        let explicitlyLive = markers.contains("live") || markers.contains("iptv") || markers.contains("channel")
        return !explicitlyLive
    }

    private func beginVODExclusivePlaybackIfNeeded(for item: MediaItem) {
        guard isOnDemandPlaybackItem(item), !vodExclusivePlaybackActive else { return }
        vodExclusivePlaybackActive = true
        ReleaseStabilityMemoryAuditManager.shared.beginVODCycle(title: item.title)
        VODExclusivePlaybackGate.begin()

        // Cancel every CatalogStore-owned operation that is not required by the active player.
        activeStreamSearchGeneration &+= 1
        activeStreamSearchItemID = nil
        cancelActiveSourceProviderTasks()
        rotateSourceIntelligenceURLSession()

        detailOpenGeneration &+= 1
        detailCreditsTask?.cancel()
        detailCreditsTask = nil
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        detailPremiumBackdropURL = nil
        for task in trailerResolveInflightTasks.values { task.cancel() }
        trailerResolveInflightTasks.removeAll()
        for task in catalogRowRefreshDebounceTasks.values { task.cancel() }
        catalogRowRefreshDebounceTasks.removeAll()
        catalogRowRefreshInFlight.removeAll()
        catalogArtworkEnrichmentTask?.cancel()
        catalogArtworkEnrichmentTask = nil
        tmdbDefaultRowsRefreshTask?.cancel()
        tmdbDefaultRowsRefreshTask = nil
        resumeColdArtworkHydrationTask?.cancel()
        resumeColdArtworkHydrationTask = nil
        isLoading = false
        resolvedTrailerAudioURL = nil

        PremiumRemoteImageLoader.beginExclusivePlayback()
        print("[VODExclusive][vBRDC210] entered: resolver/catalog/trailer/artwork work cancelled; the single playback-visible Episode Alert heartbeat remains eligible")
    }

    private func endVODExclusivePlaybackIfNeeded() {
        guard vodExclusivePlaybackActive else { return }
        VODExclusivePlaybackGate.end()
        // The session was already rotated when exclusive playback began. Do not invalidate
        // or replace a session that a just-cancelled resolver may still retain.
        PremiumRemoteImageLoader.endExclusivePlayback()
        vodExclusivePlaybackActive = false
        print("[VODExclusive][v964] exited: normal app work may resume")
        if allInOneCatalogsEnabled,
           catalogRefreshRequestedAfterActivation || officialCatalogRowsNeedRecovery() {
            catalogRefreshRequestedAfterActivation = false
            scheduleCatalogRecoveryRetry(reason: "VOD exclusive playback ended")
        }
        // vBRDC196: the moment playback releases the resource gate, republish the local
        // Continue Watching row and refresh Trakt so the title just watched is visible on return.
        refreshPlaybackDerivedCatalogRows()
    }

    private static let localContinueRowID = "dc-local-continue"
    private static let traktCustomizationDescriptors: [BuiltInCatalogRowDescriptor] = [
        .init(id: "dc-local-continue", title: "Continue Watching"),
        .init(id: "trakt-movie-continue", title: "Movies • Continue Watching • Trakt"),
        .init(id: "trakt-show-continue", title: "TV Shows • Continue Watching • Trakt"),
        .init(id: "trakt-movie-watchlist", title: "Movies • Trakt Watchlist"),
        .init(id: "trakt-show-watchlist", title: "TV Shows • Trakt Watchlist"),
        .init(id: "trakt-movie-history", title: "Movies • Watch History • Trakt"),
        .init(id: "trakt-show-history", title: "TV Shows • Watch History • Trakt"),
        .init(id: "trakt-movie-favorites", title: "Movies • Trakt Favorites"),
        .init(id: "trakt-show-favorites", title: "TV Shows • Trakt Favorites"),
        .init(id: "trakt-movie-recommended", title: "Movies • Recommended • Trakt"),
        .init(id: "trakt-show-recommended", title: "TV Shows • Recommended • Trakt"),
        .init(id: "trakt-movie-trending", title: "Movies • Trending on Trakt"),
        .init(id: "trakt-show-trending", title: "TV Shows • Trending on Trakt"),
        .init(id: "trakt-movie-popular", title: "Movies • Popular on Trakt"),
        .init(id: "trakt-show-popular", title: "TV Shows • Popular on Trakt"),
        .init(id: "trakt-movie-anticipated", title: "Movies • Anticipated on Trakt"),
        .init(id: "trakt-show-anticipated", title: "TV Shows • Anticipated on Trakt")
    ]

    private func isTraktCatalogRow(_ row: MediaRow) -> Bool {
        row.id.hasPrefix("trakt-") || row.presentation?.providerName?.caseInsensitiveCompare("Trakt") == .orderedSame
    }

    private func isPlaybackDerivedCatalogRow(_ row: MediaRow) -> Bool {
        row.id == Self.localContinueRowID
    }

    /// vBRDC196: classify official rows from row identity/provider metadata only.
    /// A poster URL is artwork, never a manifest identity; using it as the manifest
    /// argument let external/account rows contaminate recovery and mode switching.
    private func isOfficialCatalogRow(_ row: MediaRow) -> Bool {
        guard !isTraktCatalogRow(row), !isPlaybackDerivedCatalogRow(row) else { return false }
        if builtInCatalogRowDescriptors.contains(where: { $0.id == row.id }) { return true }
        if let provider = row.presentation?.providerName,
           isDebridChannelsCatalog(name: provider, manifestURL: "") { return true }
        for item in row.items.prefix(3) {
            if let addonName = item.addonName,
               isDebridChannelsCatalog(name: addonName, manifestURL: "") { return true }
        }
        // Protected/cached rows can predate provider presentation metadata. Their stable
        // row identity still embeds the official manifest name, so use that as a final
        // fallback rather than unrelated artwork URLs.
        return isDebridChannelsCatalog(name: "\(row.id) \(row.title)", manifestURL: "")
    }

    private func catalogCustomizationDescriptors() -> [BuiltInCatalogRowDescriptor] {
        // vBRDC202: Resume is the app's unified local + Trakt-backed progress shelf, so it
        // is the first account row by default. A saved custom order remains authoritative.
        let account = Self.traktCustomizationDescriptors
        let base = TraktSyncManager.shared.isConnected ? account + builtInCatalogRowDescriptors : builtInCatalogRowDescriptors + account
        var output: [BuiltInCatalogRowDescriptor] = []
        var seen = Set<String>()
        for row in base where seen.insert(row.id).inserted { output.append(row) }
        return output
    }

    private func migrateConnectedTraktRowsToTopIfNeeded() {
        guard TraktSyncManager.shared.isConnected else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: builtInCatalogCustomRowOrderKey) ?? []
        let accountIDs = Self.traktCustomizationDescriptors.map(\.id)
        let accountIDSet = Set(accountIDs)
        let savedAccountIDs = saved.filter { accountIDSet.contains($0) }
        let hasSavedTraktOrder = saved.contains(where: { $0.hasPrefix("trakt-") })
        guard !defaults.bool(forKey: traktRowsTopOrderMigrationKey) || !hasSavedTraktOrder else { return }

        var seen = Set<String>()
        var next: [String] = []

        // vBRDC202: preserve the person's complete account-row relative order, including
        // an explicitly moved Resume row. vBRDC198/200 preserved only Trakt-relative order
        // and then forced Resume behind every Trakt shelf, making Move to Top appear broken.
        for id in savedAccountIDs where seen.insert(id).inserted { next.append(id) }
        for id in accountIDs where seen.insert(id).inserted { next.append(id) }
        for id in saved where !accountIDSet.contains(id) && seen.insert(id).inserted { next.append(id) }

        defaults.set(next, forKey: builtInCatalogCustomRowOrderKey)
        defaults.set(true, forKey: traktRowsTopOrderMigrationKey)
        print("[TraktCatalog][vBRDC202] preserved account custom order while repairing connected shelf placement")
    }

    private func hiddenCustomizedRowIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: builtInCatalogHiddenRowIDsKey) ?? [])
    }

    private func savedCustomizedRowOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: builtInCatalogCustomRowOrderKey) ?? []
    }

    private var shouldPresentPersistedTraktRows: Bool {
        if TraktSyncManager.shared.isConnected { return true }
        return !TraktSyncManager.shared.connectedAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func cachedRows(forKey key: String) -> [MediaRow] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MediaRow].self, from: data) else { return [] }
        return canonicalizedCatalogRows(decoded)
    }

    private func persistRows(_ sourceRows: [MediaRow], forKey key: String, maxRows: Int = 40, maxItemsPerRow: Int = 32) {
        let compact = sourceRows.prefix(maxRows).map { row in
            MediaRow(id: row.id, title: row.title, items: Array(row.items.prefix(maxItemsPerRow)), presentation: row.presentation)
        }
        guard let data = try? JSONEncoder().encode(compact), data.count < 2_500_000 else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistRowsOffMain(_ sourceRows: [MediaRow], forKey key: String, maxRows: Int = 40, maxItemsPerRow: Int = 32) {
        let compact = sourceRows.prefix(maxRows).map { row in
            MediaRow(id: row.id, title: row.title, items: Array(row.items.prefix(maxItemsPerRow)), presentation: row.presentation)
        }
        catalogPersistenceQueue.async {
            guard let data = try? JSONEncoder().encode(compact), data.count < 2_500_000 else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func sanitizedTraktRows(_ sourceRows: [MediaRow]) -> [MediaRow] {
        // vBRDC197: sanitize type AND row identity. Old/current cache snapshots can both
        // contain the same logical shelf, so never let duplicate ids escape this boundary.
        var output: [MediaRow] = []
        var seenRowIDs = Set<String>()
        for row in sourceRows {
            guard isTraktCatalogRow(row), seenRowIDs.insert(row.id).inserted else { continue }
            let expectsMovie = row.id.hasPrefix("trakt-movie-")
            let expectsShow = row.id.hasPrefix("trakt-show-")
            let filtered = row.items.filter { item in
                if expectsMovie { return item.type.lowercased() == "movie" && item.seasonNumber == nil && item.episodeNumber == nil }
                if expectsShow {
                    let type = item.type.lowercased()
                    return type == "series" || type == "show" || type == "tv" || item.seasonNumber != nil || item.episodeNumber != nil
                }
                return true
            }
            guard !filtered.isEmpty else { continue }
            output.append(MediaRow(id: row.id, title: row.title, items: filtered, presentation: row.presentation))
        }
        return output
    }

    private func mergeLastKnownGoodTraktRows(fresh: [MediaRow], previous: [MediaRow]) -> [MediaRow] {
        let cleanFresh = sanitizedTraktRows(fresh)
        let cleanPrevious = sanitizedTraktRows(previous)

        // vBRDC197 crash fix: current rows and the last-known-good cache intentionally
        // overlap. A unique-key dictionary initializer traps when both contain the same
        // Trakt row id (the Sync Resume IPS faulted exactly here). Keep the first current
        // previous row, then let a non-empty fresh row replace it explicitly.
        var byID: [String: MediaRow] = [:]
        for row in cleanPrevious where !row.items.isEmpty && byID[row.id] == nil {
            byID[row.id] = row
        }
        for row in cleanFresh where !row.items.isEmpty {
            byID[row.id] = row
        }
        let preferredOrder = Self.traktCustomizationDescriptors.map(\.id)
        let ordered = preferredOrder.compactMap { byID[$0] }
        let preferredSet = Set(preferredOrder)
        let leftovers = byID.values.filter { !preferredSet.contains($0.id) }.sorted { $0.id < $1.id }
        return ordered + leftovers
    }

    private func localContinueWatchingRow(existingItems: [MediaItem]) -> MediaRow? {
        let hidden = hiddenCustomizedRowIDs()
        guard !hidden.contains(Self.localContinueRowID) else { return nil }
        let entries = PlaybackResumeCacheManager.shared.recentEntries()
            .filter { $0.seconds >= 8 && ($0.duration <= 0 || $0.dcProgressFraction < 0.95) }
        guard !entries.isEmpty else { return nil }

        var output: [MediaItem] = []
        var seen = Set<String>()
        var artworkBackfills: [PlaybackResumeCacheManager.ArtworkBackfillUpdate] = []
        for entry in entries {
            let lowerType = entry.type.lowercased()
            let entryIsShow = entry.season != nil || entry.episode != nil || lowerType.contains("series") || lowerType.contains("show") || lowerType.contains("episode")
            let match = existingItems.first { item in
                let itemType = item.type.lowercased()
                let itemIsShow = item.seasonNumber != nil || item.episodeNumber != nil || itemType.contains("series") || itemType.contains("show") || itemType.contains("episode")
                guard itemIsShow == entryIsShow else { return false }
                guard item.title.caseInsensitiveCompare(entry.title) == .orderedSame else { return false }
                if let year = entry.year, !year.isEmpty, !item.year.isEmpty, year != item.year { return false }
                if entryIsShow {
                    // Catalogs usually contain the parent show card, not every episode.
                    // A synced Trakt episode is allowed to hydrate that parent card with
                    // the saved S/E identity below so Continue Watching can appear at once.
                    if item.seasonNumber == nil && item.episodeNumber == nil { return true }
                    return (entry.season ?? 0) == (item.seasonNumber ?? 0) && (entry.episode ?? 0) == (item.episodeNumber ?? 0)
                }
                return true
            }
            let coldOverride = resumeColdArtworkOverrides[entry.key]
            var candidate = match.map { matched -> MediaItem in
                // vBRDC202/vBRDC210: collect artwork repairs and commit the whole visible
                // Resume shelf once. A cold-launch TMDB result can also fill any visual
                // field the base catalog has not resolved yet.
                var hydrated = matched
                if hydrated.posterURL?.isEmpty ?? true { hydrated.posterURL = coldOverride?.posterURL }
                if hydrated.landscapeURL?.isEmpty ?? true { hydrated.landscapeURL = coldOverride?.landscapeURL }
                if hydrated.logoURL?.isEmpty ?? true { hydrated.logoURL = coldOverride?.logoURL }
                artworkBackfills.append(.init(
                    entry: entry,
                    posterURL: hydrated.posterURL,
                    landscapeURL: hydrated.landscapeURL,
                    logoURL: hydrated.logoURL
                ))
                guard entryIsShow else { return hydrated }
                hydrated.seasonNumber = entry.season
                hydrated.episodeNumber = entry.episode
                return hydrated
            }
            if candidate == nil {
                // vBRDC197: a newly linked device can have valid Trakt resume state before
                // the base catalog/artwork has finished loading. Publish the row identity
                // immediately with a placeholder-capable card, then let the normal catalog
                // enrichment replace artwork as soon as the title is available.
                let posterArtwork = (coldOverride?.posterURL ?? entry.posterArtworkURL ?? entry.artworkURL).flatMap { PremiumArtworkURL.url($0) != nil ? $0 : nil }
                let landscapeArtwork = (coldOverride?.landscapeURL ?? entry.landscapeArtworkURL ?? entry.artworkURL).flatMap { PremiumArtworkURL.url($0) != nil ? $0 : nil }
                candidate = MediaItem(
                    id: entry.mediaID ?? "resume-\(entry.key)",
                    tmdbId: entry.tmdbId,
                    imdbId: entry.imdbId,
                    tvdbId: entry.tvdbId,
                    title: entry.title,
                    year: entry.year ?? "",
                    type: entryIsShow ? "series" : "movie",
                    catalog: entry.catalog,
                    description: "",
                    genres: [],
                    rating: "",
                    posterURL: posterArtwork,
                    landscapeURL: landscapeArtwork,
                    logoURL: coldOverride?.logoURL ?? entry.logoArtworkURL,
                    addonName: "Debrid Channels",
                    seasonNumber: entry.season,
                    episodeNumber: entry.episode
                )
            }
            if let item = candidate, seen.insert(item.id).inserted {
                // The row itself identifies Continue Watching. Keep the item's original
                // catalog/id so fallback resume aliases remain byte-for-byte compatible.
                output.append(item)
            }
        }
        guard !output.isEmpty else { return nil }
        PlaybackResumeCacheManager.shared.backfillArtworkBatch(artworkBackfills)
        return MediaRow(
            id: Self.localContinueRowID,
            title: "Continue Watching",
            items: Array(output.prefix(24)),
            presentation: CatalogRowPresentation(
                shortName: "Resume",
                description: "Local and Trakt-backed playback progress",
                rowKind: "resume",
                providerName: "Debrid Channels",
                theme: CatalogRowVisualTheme(style: "resume", accentHex: "#36C5F0", secondaryHex: "#155C74", symbol: "play.circle.fill", labelStyle: "provider")
            )
        )
    }

    /// vBRDC197: publish the connected account's unfinished playback shelf from the
    /// already-synchronized cloud snapshot without waiting for Watchlist/History/Trending
    /// or TMDB enrichment. This is the manual-sync/return-from-playback fast path.
    private func immediateTraktContinueRows(existingItems: [MediaItem]) -> [MediaRow] {
        guard TraktSyncManager.shared.isConnected else { return [] }
        let points = TraktSyncManager.shared.cloudResumePointsSnapshot()
            .filter { $0.progress >= 0.2 && $0.progress < 95 }
            .sorted { $0.pausedAt > $1.pausedAt }

        func normalized(_ value: String) -> String {
            value.lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func movieMatches(_ item: MediaItem, _ point: TraktCloudResumePoint) -> Bool {
            let lower = item.type.lowercased()
            guard item.seasonNumber == nil, item.episodeNumber == nil, !lower.contains("series"), !lower.contains("show"), !lower.contains("episode") else { return false }
            if let p = point.tmdbID, Int(item.tmdbId ?? "") == p { return true }
            if let p = point.imdbID?.lowercased(), item.imdbId?.lowercased() == p { return true }
            guard normalized(item.title) == normalized(point.title) else { return false }
            return point.year == nil || Int(item.year) == nil || Int(item.year) == point.year
        }
        func showMatches(_ item: MediaItem, _ point: TraktCloudResumePoint) -> Bool {
            let lower = item.type.lowercased()
            guard item.seasonNumber != nil || item.episodeNumber != nil || lower.contains("series") || lower.contains("show") || lower.contains("tv") else { return false }
            if let p = point.showTMDBID ?? point.tmdbID, Int(item.tmdbId ?? "") == p { return true }
            if let p = (point.showIMDbID ?? point.imdbID)?.lowercased(), item.imdbId?.lowercased() == p { return true }
            return normalized(item.title) == normalized(point.showTitle ?? point.title)
        }

        var movieItems: [MediaItem] = []
        var showItems: [MediaItem] = []
        var seenMovies = Set<String>()
        var seenShows = Set<String>()
        for point in points {
            if point.kind == "movie" {
                var item = existingItems.first(where: { movieMatches($0, point) }) ?? MediaItem(
                    id: point.tmdbID.map { "trakt-cloud-movie-tmdb-\($0)" } ?? point.imdbID.map { "trakt-cloud-movie-imdb-\($0)" } ?? "trakt-cloud-movie-\(normalized(point.title))",
                    tmdbId: point.tmdbID.map(String.init),
                    imdbId: point.imdbID,
                    title: point.title,
                    year: point.year.map(String.init) ?? "",
                    type: "movie",
                    catalog: "Continue Watching • Trakt",
                    description: "",
                    genres: [],
                    rating: "",
                    posterURL: nil,
                    landscapeURL: nil,
                    logoURL: nil,
                    addonName: "Trakt"
                )
                item.type = "movie"
                item.seasonNumber = nil
                item.episodeNumber = nil
                item.catalog = "Continue Watching • Trakt"
                item.addonName = "Trakt"
                if seenMovies.insert(item.id).inserted { movieItems.append(item) }
            } else {
                let showTitle = point.showTitle ?? point.title
                let showTMDB = point.showTMDBID ?? point.tmdbID
                let showIMDb = point.showIMDbID ?? point.imdbID
                var item = existingItems.first(where: { showMatches($0, point) }) ?? MediaItem(
                    id: showTMDB.map { "trakt-cloud-show-tmdb-\($0)" } ?? showIMDb.map { "trakt-cloud-show-imdb-\($0)" } ?? "trakt-cloud-show-\(normalized(showTitle))",
                    tmdbId: showTMDB.map(String.init),
                    imdbId: showIMDb,
                    title: showTitle,
                    year: (point.showYear ?? point.year).map(String.init) ?? "",
                    type: "series",
                    catalog: "Continue Watching • Trakt",
                    description: "",
                    genres: [],
                    rating: "",
                    posterURL: nil,
                    landscapeURL: nil,
                    logoURL: nil,
                    addonName: "Trakt",
                    seasonNumber: point.season,
                    episodeNumber: point.episode
                )
                item.type = "series"
                item.seasonNumber = point.season
                item.episodeNumber = point.episode
                item.catalog = "Continue Watching • Trakt"
                item.addonName = "Trakt"
                let key = "\(item.id)|s\(point.season ?? 0)|e\(point.episode ?? 0)"
                if seenShows.insert(key).inserted { showItems.append(item) }
            }
        }

        func makeRow(id: String, items: [MediaItem], symbol: String) -> MediaRow? {
            guard !items.isEmpty else { return nil }
            return MediaRow(
                id: id,
                title: "Continue Watching • Trakt",
                items: Array(items.prefix(24)),
                presentation: CatalogRowPresentation(
                    shortName: "Continue Watching • Trakt",
                    description: "Unfinished playback synced from Trakt",
                    rowKind: "trakt",
                    providerName: "Trakt",
                    theme: CatalogRowVisualTheme(style: "trakt", accentHex: "#ED1C24", secondaryHex: "#8A1018", symbol: symbol, labelStyle: "provider")
                )
            )
        }
        return [
            makeRow(id: "trakt-movie-continue", items: movieItems, symbol: "film.fill"),
            makeRow(id: "trakt-show-continue", items: showItems, symbol: "tv.fill")
        ].compactMap { $0 }
    }

    /// vBRDC210: repair first-install / restored Resume visual identity without waiting
    /// for the user to browse another catalog. The work is intentionally bounded, disabled
    /// during full-screen playback, and uses the existing TMDB hero cache rather than a new
    /// provider-wide scan.
    func hydrateResumeArtworkOnColdLaunchIfNeeded(force: Bool = false) {
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }
        if !force, let last = resumeColdArtworkHydrationLastAttempt, Date().timeIntervalSince(last) < 300 { return }
        guard resumeColdArtworkHydrationTask == nil else { return }

        // First re-project against whatever official/Trakt cards are already resident. In
        // many launches this repairs the row with zero networking.
        refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()

        let key = (UserDefaults.standard.string(forKey: "tmdbApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let entries = PlaybackResumeCacheManager.shared.recentEntries()
            .filter { entry in
                entry.seconds >= 8 &&
                (entry.duration <= 0 || entry.dcProgressFraction < 0.95) &&
                ((entry.posterArtworkURL?.isEmpty ?? true) ||
                 (entry.landscapeArtworkURL?.isEmpty ?? true) ||
                 (entry.logoArtworkURL?.isEmpty ?? true))
            }
        let seeds = Array(entries.prefix(12)).map { entry in
            ResumeColdArtworkSeed(
                key: entry.key,
                itemID: entry.mediaID ?? "resume-\(entry.key)",
                tmdbID: entry.tmdbId,
                imdbID: entry.imdbId,
                title: entry.title,
                year: entry.year ?? "",
                type: entry.type
            )
        }
        guard !seeds.isEmpty else { return }
        resumeColdArtworkHydrationLastAttempt = Date()

        resumeColdArtworkHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var resolved: [String: CatalogHeroMetadataSnapshot] = [:]
            let batchSize = 3
            var start = 0
            while start < seeds.count, !Task.isCancelled {
                let end = min(start + batchSize, seeds.count)
                let batch = Array(seeds[start..<end])
                let results = await withTaskGroup(of: (String, CatalogHeroMetadataSnapshot?).self, returning: [(String, CatalogHeroMetadataSnapshot?)].self) { group in
                    for seed in batch {
                        group.addTask {
                            let snapshot = await CatalogHeroMetadataCache.shared.metadata(
                                itemID: seed.itemID,
                                tmdbID: seed.tmdbID,
                                imdbID: seed.imdbID,
                                title: seed.title,
                                year: seed.year,
                                type: seed.type,
                                apiKey: key
                            )
                            return (seed.key, snapshot)
                        }
                    }
                    var values: [(String, CatalogHeroMetadataSnapshot?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                for (entryKey, snapshot) in results {
                    guard let snapshot else { continue }
                    if snapshot.posterURL != nil || snapshot.landscapeURL != nil || snapshot.logoURL != nil {
                        resolved[entryKey] = snapshot
                        self.resumeColdArtworkOverrides[entryKey] = ResumeColdArtworkOverride(
                            posterURL: snapshot.posterURL,
                            landscapeURL: snapshot.landscapeURL,
                            logoURL: snapshot.logoURL
                        )
                    }
                }
                // Re-project after each small batch so visible cards repair progressively.
                if !resolved.isEmpty { self.refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork() }
                start = end
            }

            guard !Task.isCancelled else { self.resumeColdArtworkHydrationTask = nil; return }
            let byKey = Dictionary(uniqueKeysWithValues: PlaybackResumeCacheManager.shared.recentEntries().map { ($0.key, $0) })
            let updates = resolved.compactMap { entryKey, snapshot -> PlaybackResumeCacheManager.ArtworkBackfillUpdate? in
                guard let entry = byKey[entryKey] else { return nil }
                return .init(entry: entry, posterURL: snapshot.posterURL, landscapeURL: snapshot.landscapeURL, logoURL: snapshot.logoURL)
            }
            PlaybackResumeCacheManager.shared.backfillArtworkBatch(updates)
            self.resumeColdArtworkHydrationTask = nil
            self.refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()
            print("[ResumeArtwork][vBRDC210] cold hydration resolved=\(resolved.count) requested=\(seeds.count)")
        }
    }

    func refreshPlaybackDerivedCatalogRows(scheduleAccountRefresh: Bool = true) {
        let base = rows.filter { !isPlaybackDerivedCatalogRow($0) }
        let existingItems = base.flatMap(\.items)
        var next = base
        if let local = localContinueWatchingRow(existingItems: existingItems) { next.append(local) }
        if TraktSyncManager.shared.isConnected {
            let fastContinue = immediateTraktContinueRows(existingItems: existingItems)
            let mergedTrakt = mergeLastKnownGoodTraktRows(fresh: fastContinue, previous: next.filter { isTraktCatalogRow($0) })
            next.removeAll(where: isTraktCatalogRow)
            next.append(contentsOf: mergedTrakt)
        }
        next = prioritizedRowsForDisplay(next)
        if next != rows { rows = next }

        guard scheduleAccountRefresh, TraktSyncManager.shared.isConnected else { return }
        // Local resume is visible immediately. Give Trakt's just-issued pause scrobble a
        // short commit window before forcing cloud/history shelves, otherwise the catalog
        // request can beat Trakt's write and publish the pre-playback account snapshot.
        traktCatalogRefreshPending = true
        traktPostPlaybackRefreshTask?.cancel()
        traktPostPlaybackRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.traktPostPlaybackRefreshTask = nil
            self.refreshTraktCatalogRowsIfNeeded(force: true)
        }
    }

    func removeTraktCatalogRows(reason: String) {
        traktCatalogRefreshTask?.cancel()
        traktCatalogRefreshTask = nil
        traktPostPlaybackRefreshTask?.cancel()
        traktPostPlaybackRefreshTask = nil
        traktCatalogLastRefreshAt = nil
        traktCatalogRefreshPending = false
        UserDefaults.standard.removeObject(forKey: traktCatalogRowsCacheKey)
        TraktCatalogService.shared.resetAccountState()
        let baseRows = rows.filter { !isTraktCatalogRow($0) }
        if baseRows != rows {
            rows = baseRows
            print("[TraktCatalog][vBRDC197] removed account shelves reason=\(reason)")
        }
    }

    func refreshTraktCatalogRowsIfNeeded(force: Bool = false, userInitiated: Bool = false, playbackAlreadySynchronized: Bool = false) {
        // vBRDC202: if a previously linked install reached this explicit Sync action after
        // a transient startup Keychain miss, recover the saved token instead of asking the
        // person to perform Device Code authorization again. Normal background calls stay
        // entirely on the in-memory connection state.
        if userInitiated, !TraktSyncManager.shared.isConnected {
            _ = TraktSyncManager.shared.restorePersistedConnectionIfNeeded()
        }
        guard TraktSyncManager.shared.isConnected,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else {
            // vBRDC202: a transient Keychain/token-read or network state is not an account
            // disconnect. Last-known-good rows stay mounted until the user explicitly taps
            // Disconnect Trakt, which is the only path allowed to remove them.
            return
        }

        // vBRDC198: this also covers a first-time account connection that happened after
        // CatalogStore was initialized. Promotion is one-shot; later user customization
        // remains authoritative across disconnect/reconnect and every catalog refresh.
        migrateConnectedTraktRowsToTopIfNeeded()

        // vBRDC197: an explicit Connect/Sync refresh supersedes the delayed post-playback
        // refresh that `refreshPlaybackDerivedCatalogRows()` may have queued moments ago.
        // Cancel it so a manual sync never produces a second forced shelf request 1.5s later.
        if userInitiated {
            traktPostPlaybackRefreshTask?.cancel()
            traktPostPlaybackRefreshTask = nil
        }

        // vBRDC196: never make the account layer compete with first paint of the built-in
        // catalog. Rehydrate last-known-good Trakt shelves immediately, then refresh them
        // once the base catalog has settled.
        if catalogLoadInProgress {
            // Rehydrate the account cache immediately in either case. Background/post-
            // playback refreshes still defer behind base first paint, but an explicit
            // user Sync/Connect action is allowed to proceed rather than appearing stuck.
            if force { traktCatalogLastRefreshAt = nil }
            traktCatalogRefreshPending = true
            let cachedTrakt = sanitizedTraktRows(self.cachedRows(forKey: traktCatalogRowsCacheKey))
            if !cachedTrakt.isEmpty {
                let base = rows.filter { !isTraktCatalogRow($0) }
                let next = prioritizedRowsForDisplay(base + cachedTrakt)
                if next != rows { rows = next }
            }
            if !userInitiated { return }
        }

        if force {
            traktCatalogRefreshTask?.cancel()
            traktCatalogRefreshTask = nil
            traktCatalogLastRefreshAt = nil
        } else if let last = traktCatalogLastRefreshAt, Date().timeIntervalSince(last) < traktCatalogRefreshTTL {
            refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()
            return
        }
        guard traktCatalogRefreshTask == nil else { return }

        let baseRows = rows.filter { !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0) }
        let existingItems = baseRows.flatMap(\.items)
        let tmdbKey = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        let previousTrakt = sanitizedTraktRows(rows.filter { isTraktCatalogRow($0) } + cachedRows(forKey: traktCatalogRowsCacheKey))

        traktCatalogRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched = await TraktCatalogService.shared.fetchCatalogRows(
                existingItems: existingItems,
                tmdbApiKey: tmdbKey,
                forcePlaybackRefresh: force,
                skipPlaybackRefresh: playbackAlreadySynchronized
            )
            guard !Task.isCancelled else { self.traktCatalogRefreshTask = nil; return }
            guard TraktSyncManager.shared.isConnected,
                  !self.fullScreenPlaybackResourceSuspended,
                  !self.vodExclusivePlaybackActive,
                  !VODExclusivePlaybackGate.isActive else {
                self.traktCatalogRefreshTask = nil
                return
            }
            self.traktCatalogRefreshTask = nil
            self.traktCatalogRefreshPending = false

            let mergedTrakt = self.mergeLastKnownGoodTraktRows(fresh: fetched, previous: previousTrakt)
            if !mergedTrakt.isEmpty {
                self.traktCatalogLastRefreshAt = Date()
                self.persistRowsOffMain(mergedTrakt, forKey: self.traktCatalogRowsCacheKey)
            }

            var currentBase = self.rows.filter { !self.isTraktCatalogRow($0) && !self.isPlaybackDerivedCatalogRow($0) }
            // vBRDC202: resolved Trakt cards are also valid artwork donors for the unified
            // Resume row. This is crucial when the official catalog does not contain the
            // resumed title but Trakt/TMDB just resolved its poster.
            let resumeHydrationItems = (currentBase + mergedTrakt).flatMap(\.items)
            if let local = self.localContinueWatchingRow(existingItems: resumeHydrationItems) { currentBase.append(local) }
            let next = self.prioritizedRowsForDisplay(currentBase + mergedTrakt)
            if next != self.rows {
                self.rows = next
                self.unifiedSearchCache.removeAll()
                print("[TraktCatalog][vBRDC197] published stable shelves=\(mergedTrakt.count) baseRows=\(currentBase.count)")
            }
        }
    }

    private func refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork() {
        let base = rows.filter { !isPlaybackDerivedCatalogRow($0) }
        let existingItems = base.flatMap(\.items)
        var next = base
        if let local = localContinueWatchingRow(existingItems: existingItems) { next.append(local) }
        next = prioritizedRowsForDisplay(next)
        if next != rows { rows = next }
    }

    init() {
        // Phase 8: repair legacy public/hidden endpoint configuration before any
        // saved manifest or backend setting is read into the release candidate.
        let releaseMigrationChanges = ReleaseCandidateSecurityManager.performUpgradeMigration()
        if !releaseMigrationChanges.isEmpty {
            print("[ReleaseCandidate] upgrade configuration repaired items=\(releaseMigrationChanges.count)")
        }
        let featureMigrationChanges = StableFeatureGateManager.performSafeMigrations()
        if !featureMigrationChanges.isEmpty {
            print("[StableProtection][Phase0] feature settings migrated items=\(featureMigrationChanges.count)")
        }
        let phase13MigrationChanges = Phase13RolloutManager.performSafeMigration()
        if !phase13MigrationChanges.isEmpty {
            print("[ReleaseGate][Phase13] rollout settings migrated items=\(phase13MigrationChanges.count)")
        }
        let phase13DisabledFeatures = Phase13RolloutManager.applyEmergencyKillSwitchIfNeeded()
        if phase13DisabledFeatures > 0 {
            print("[ReleaseGate][Phase13] emergency kill switch disabled playback features=\(phase13DisabledFeatures)")
        }
        PlaybackSessionTerminationJournal.reportAndResetPreviousAbnormalSession()
        trailerResolveMemoryCache = UserDefaults.standard.dictionary(forKey: trailerResolveCacheKey) as? [String: String] ?? [:]
        trailerResolveMemoryOrder = trailerResolveMemoryCache.keys.sorted()
        while trailerResolveMemoryOrder.count > trailerResolveMemoryLimit {
            trailerResolveMemoryCache.removeValue(forKey: trailerResolveMemoryOrder.removeFirst())
        }
        UserDefaults.standard.set(trailerResolveMemoryCache, forKey: trailerResolveCacheKey)
        let saved = UserDefaults.standard.stringArray(forKey: manifestsKey) ?? []
        // v1007: migrate older builds by removing every official all-in-one endpoint from
        // the user's visible saved-manifest list. The built-in service is selected solely
        // by the All-in-One toggle and cannot be moved or removed as a JSON addon.
        var migrated = dedupedManifestURLs(saved).filter { !isAllInOneManifestURL($0) }
        let cometCleanupKey = "migration.vBRDC053.retiredManagedCometRemoved"
        if !UserDefaults.standard.bool(forKey: cometCleanupKey) {
            migrated.removeAll { isRetiredManagedCometManifest($0) }
            UserDefaults.standard.set(true, forKey: cometCleanupKey)
        }
        migrated.removeAll { isCinemetaManifest($0) }
        migrated.append(coreMetadataManifestURL)
        manifestURLs = dedupedManifestURLs(migrated)
        UserDefaults.standard.set(manifestURLs, forKey: manifestsKey)

        // vBRDC197: preserve last-known-good Trakt/external shelves across app updates.
        // vBRDC196 introduced these caches with build-numbered keys, which guaranteed a
        // cold account/catalog surface on the very next release.
        let defaults = UserDefaults.standard
        if defaults.data(forKey: traktCatalogRowsCacheKey) == nil,
           let legacy = defaults.data(forKey: legacyTraktCatalogRowsCacheKey) {
            defaults.set(legacy, forKey: traktCatalogRowsCacheKey)
        }
        if defaults.data(forKey: externalCatalogRowsCacheKey) == nil,
           let legacy = defaults.data(forKey: legacyExternalCatalogRowsCacheKey) {
            defaults.set(legacy, forKey: externalCatalogRowsCacheKey)
        }

        // vBRDC198: repair the stale built-in-first customization order before any cached
        // rows are projected. This makes connected Trakt shelves top rows on first frame.
        migrateConnectedTraktRowsToTopIfNeeded()

        // v1032 Phase 5: the complete protected snapshot is preferred over the compact
        // fast-launch cache. This keeps Home/Movies/Shows available during an outage and
        // restores hidden-row search/index data before the network refresh begins.
        var cachedRows: [MediaRow]
        var usingProtectedSnapshot = false
        if allInOneCatalogsEnabled {
            let protectedRows = loadOfficialCatalogSnapshotRows() ?? []
            cachedRows = !protectedRows.isEmpty ? protectedRows : bestAvailableOfficialCatalogRows()
            usingProtectedSnapshot = !protectedRows.isEmpty
        } else {
            // vBRDC196: external mode has its own durable fast-launch cache. Never let a
            // prior official compact cache decide what appears after All-in-One is disabled.
            let external = self.cachedRows(forKey: externalCatalogRowsCacheKey)
            cachedRows = !external.isEmpty ? external : cachedCatalogRows()
        }
        cachedRows = canonicalizedCatalogRows(cachedRows)
        if !allInOneCatalogsEnabled {
            cachedRows.removeAll(where: isOfficialCatalogRow)
        }
        // Phase 12B: rows decoded from the protected official snapshot are already
        // cryptographically scoped by their private file location/schema/source marker.
        // Do not run them through a second heuristic name filter during startup.
        if !cachedRows.isEmpty {
            var baseRows = applyBuiltInCatalogRowPreferences(to: cachedRows, captureDescriptors: true)
            if shouldPresentPersistedTraktRows {
                baseRows.append(contentsOf: sanitizedTraktRows(self.cachedRows(forKey: traktCatalogRowsCacheKey)))
            }
            if let local = localContinueWatchingRow(existingItems: baseRows.flatMap(\.items)) { baseRows.append(local) }
            rows = prioritizedRowsForDisplay(baseRows)
            status = usingProtectedSnapshot
                ? "Showing the protected catalog snapshot while refreshing…"
                : "Showing cached real catalogs while refreshing…"
        } else {
            var accountRows: [MediaRow] = []
            if shouldPresentPersistedTraktRows {
                accountRows.append(contentsOf: sanitizedTraktRows(self.cachedRows(forKey: traktCatalogRowsCacheKey)))
            }
            if let local = localContinueWatchingRow(existingItems: accountRows.flatMap(\.items)) { accountRows.append(local) }
            rows = prioritizedRowsForDisplay(accountRows)
            status = rows.isEmpty ? "Loading catalogs…" : "Showing cached Trakt rows while catalogs load…"
        }
    }

    private static func elapsedMS(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func trimmedArtworkCache(_ cache: [String: [String: String]], keeping keyToKeep: String? = nil) -> [String: [String: String]] {
        let maxEntries = 160
        guard cache.count > maxEntries else { return cache }
        var result: [String: [String: String]] = [:]
        if let keyToKeep, let entry = cache[keyToKeep] {
            result[keyToKeep] = entry
        }
        for key in cache.keys.sorted() where result.count < maxEntries {
            if result[key] == nil {
                result[key] = cache[key]
            }
        }
        return result
    }

    private func cachedArtwork(for item: MediaItem) -> (poster: String?, backdrop: String?, logo: String?) {
        // vBRDC159: Search/Favorites items can change identity while they are being hydrated
        // (provider id -> TMDB -> IMDb). Read every stable alias instead of only the strongest
        // current id so artwork learned under an enriched identity remains visible when VOD
        // later receives the original shell identity.
        let cache = UserDefaults.standard.dictionary(forKey: metadataArtworkCacheKey) as? [String: [String: String]] ?? [:]
        var poster: String? = nil
        var backdrop: String? = nil
        var logo: String? = nil
        for key in metadataArtworkCacheIDs(for: item) {
            let entry = cache[key] ?? [:]
            if poster?.isEmpty ?? true, let value = entry["poster"], !value.isEmpty { poster = value }
            if backdrop?.isEmpty ?? true, let value = entry["backdrop"], !value.isEmpty { backdrop = value }
            if logo?.isEmpty ?? true, let value = entry["logo"], !value.isEmpty { logo = value }
            if poster != nil, backdrop != nil, logo != nil { break }
        }
        return (poster, backdrop, logo)
    }

    private func cacheArtwork(for item: MediaItem, poster: String?, backdrop: String?, logo: String?) {
        let cleanPoster = poster?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBackdrop = backdrop?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLogo = logo?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [cleanPoster, cleanBackdrop, cleanLogo].contains(where: { ($0 ?? "").isEmpty == false }) else { return }
        let keys = metadataArtworkCacheIDs(for: item)
        guard !keys.isEmpty else { return }
        var cache = UserDefaults.standard.dictionary(forKey: metadataArtworkCacheKey) as? [String: [String: String]] ?? [:]
        for key in keys {
            var entry = cache[key] ?? [:]
            if let cleanPoster, !cleanPoster.isEmpty { entry["poster"] = cleanPoster }
            if let cleanBackdrop, !cleanBackdrop.isEmpty { entry["backdrop"] = cleanBackdrop }
            if let cleanLogo, !cleanLogo.isEmpty { entry["logo"] = cleanLogo }
            cache[key] = entry
        }
        cache = trimmedArtworkCache(cache, keeping: keys.first)
        if let data = try? JSONSerialization.data(withJSONObject: cache), data.count < 220_000 {
            UserDefaults.standard.set(cache, forKey: metadataArtworkCacheKey)
        } else {
            // Never wipe a working artwork cache because one alias expansion crossed the
            // persistence ceiling. Keep only this title's compact aliases instead.
            var compact: [String: [String: String]] = [:]
            for key in keys {
                if let entry = cache[key] { compact[key] = entry }
            }
            UserDefaults.standard.set(compact, forKey: metadataArtworkCacheKey)
        }
    }

    private func metadataArtworkCacheIDs(for item: MediaItem) -> [String] {
        var keys: [String] = []
        func add(_ value: String) {
            guard !value.isEmpty, !keys.contains(value) else { return }
            keys.append(value)
        }
        let type = normalizedStremioType(item.type)
        if let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tmdb.isEmpty {
            add("tmdb|\(type)|\(tmdb)")
        }
        if let imdb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            add("imdb|\(imdb.lowercased())")
        }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty {
            add("tvdb|\(type)|\(tvdb)")
        }
        let rawID = item.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !rawID.isEmpty { add("media|\(rawID)") }
        let title = normalizedMatchText(item.title)
        let year = item.year.filter(\.isNumber)
        if !title.isEmpty { add("title|\(type)|\(title)|\(year)") }
        return keys
    }

    private func applyBuiltInCatalogRowPreferences(
        to sourceRows: [MediaRow],
        captureDescriptors: Bool = true
    ) -> [MediaRow] {
        guard allInOneCatalogsEnabled, !sourceRows.isEmpty else { return sourceRows }

        // While All-in-One is enabled the hidden built-in manifest is the only browsing
        // source. Capture only its lightweight row identity metadata before filtering;
        // the poster/catalog payload itself is never duplicated or persisted here.
        // Keep one memory-only flattened search index before applying visibility/order.
        // Hidden rows therefore remain searchable without issuing 83 catalog requests.
        builtInUnifiedSearchIndex = normalizedUnifiedSearchItems(
            sourceRows.flatMap(\.items),
            query: nil,
            displayCatalogOverride: nil
        )

        let officialDescriptors = sourceRows.map {
            BuiltInCatalogRowDescriptor(id: $0.id, title: $0.title)
        }
        if captureDescriptors, builtInCatalogRowDescriptors != officialDescriptors {
            builtInCatalogRowDescriptors = officialDescriptors
        }

        let officialIDs = officialDescriptors.map(\.id)
        let officialIDSet = Set(officialIDs)
        let hiddenIDs = Set(
            (UserDefaults.standard.stringArray(forKey: builtInCatalogHiddenRowIDsKey) ?? [])
                .filter { officialIDSet.contains($0) }
        )
        let savedOrder = UserDefaults.standard.stringArray(forKey: builtInCatalogCustomRowOrderKey) ?? []
        let orderedIDs = savedOrder.filter { officialIDSet.contains($0) }
            + officialIDs.filter { !savedOrder.contains($0) }

        var rowsByID: [String: MediaRow] = [:]
        for row in sourceRows where rowsByID[row.id] == nil {
            rowsByID[row.id] = row
        }
        return orderedIDs.compactMap { id in
            guard !hiddenIDs.contains(id) else { return nil }
            return rowsByID[id]
        }
    }

    func builtInCatalogCustomizationSnapshot() -> (
        rows: [BuiltInCatalogRowDescriptor],
        hiddenRowIDs: Set<String>,
        orderedRowIDs: [String]
    ) {
        let availableRows = catalogCustomizationDescriptors()
        let availableIDs = availableRows.map(\.id)
        let availableIDSet = Set(availableIDs)
        let hiddenIDs = Set(
            (UserDefaults.standard.stringArray(forKey: builtInCatalogHiddenRowIDsKey) ?? [])
                .filter { availableIDSet.contains($0) }
        )
        let savedOrder = UserDefaults.standard.stringArray(forKey: builtInCatalogCustomRowOrderKey) ?? []
        let orderedIDs = savedOrder.filter { availableIDSet.contains($0) }
            + availableIDs.filter { !savedOrder.contains($0) }
        var rowsByID: [String: BuiltInCatalogRowDescriptor] = [:]
        for row in availableRows where rowsByID[row.id] == nil { rowsByID[row.id] = row }
        return (
            rows: orderedIDs.compactMap { rowsByID[$0] },
            hiddenRowIDs: hiddenIDs,
            orderedRowIDs: orderedIDs
        )
    }

    func catalogCustomizationDefaultRows() -> [BuiltInCatalogRowDescriptor] {
        catalogCustomizationDescriptors()
    }

    func commitBuiltInCatalogCustomization(hiddenRowIDs: Set<String>, orderedRowIDs: [String]) {
        let available = catalogCustomizationDescriptors()
        let availableIDs = available.map(\.id)
        let availableIDSet = Set(availableIDs)

        var seen = Set<String>()
        let normalizedOrder = orderedRowIDs.filter {
            availableIDSet.contains($0) && seen.insert($0).inserted
        } + availableIDs.filter { !seen.contains($0) }
        let normalizedHidden = availableIDs.filter { hiddenRowIDs.contains($0) }

        UserDefaults.standard.set(normalizedHidden, forKey: builtInCatalogHiddenRowIDsKey)
        UserDefaults.standard.set(normalizedOrder, forKey: builtInCatalogCustomRowOrderKey)

        // vBRDC202: make Move to Top authoritative in the same transaction. Do not wait
        // for a provider/account publication to happen before the mounted main rail adopts
        // the saved order; later publications still pass through the same custom rank.
        let immediateReorderedRows = prioritizedRowsForDisplay(rows)
        if immediateReorderedRows != rows { rows = immediateReorderedRows }

        // vBRDC196: customization is an in-memory reorder/filter first. Do not throw away
        // a healthy 83-row snapshot and wait on the network just because a person moved a row.
        let currentTrakt = rows.filter { isTraktCatalogRow($0) }
        if allInOneCatalogsEnabled {
            let official = bestAvailableOfficialCatalogRows()
            if !official.isEmpty {
                let customized = applyBuiltInCatalogRowPreferences(to: official, captureDescriptors: false)
                var next = customized + currentTrakt
                let existingItems = (customized + currentTrakt).flatMap(\.items)
                if let local = localContinueWatchingRow(existingItems: existingItems) { next.append(local) }
                rows = prioritizedRowsForDisplay(next)
                persistCatalogRowsCache(customized)
                status = "All-in-One row customization applied immediately."
            } else {
                refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()
                status = "Catalog row customization saved. Account rows updated now; built-in ordering will apply as soon as the catalog snapshot finishes loading."
            }
        } else {
            refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()
            status = "Catalog row customization saved. Trakt/resume rows updated immediately; All-in-One ordering will apply when enabled."
        }
    }

    // MARK: - Phase 5 catalog reliability / recovery

    private func officialCatalogSnapshotDirectory() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = root.appendingPathComponent("DebridChannelsCatalogReliability", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            print("[CatalogReliability] application-support directory unavailable")
            return nil
        }
    }

    private func officialCatalogSnapshotURL(previous: Bool = false) -> URL? {
        officialCatalogSnapshotDirectory()?.appendingPathComponent(
            previous ? "official-catalog-previous-v1.json" : "official-catalog-current-v1.json",
            isDirectory: false
        )
    }

    private func officialCatalogProvisionalSnapshotURL() -> URL? {
        officialCatalogSnapshotDirectory()?.appendingPathComponent(
            "official-catalog-provisional-v1.json",
            isDirectory: false
        )
    }

    private func catalogCompletenessScore(_ candidateRows: [MediaRow]) -> (rows: Int, items: Int) {
        (candidateRows.count, candidateRows.reduce(0) { $0 + $1.items.count })
    }

    private func officialRows(from sourceRows: [MediaRow]) -> [MediaRow] {
        sourceRows.filter(isOfficialCatalogRow)
    }

    /// Phase 12A durable baseline. Snapshot files win when complete, but the compact
    /// launch cache and currently visible official rows are also considered so a single
    /// corrupt file can never leave Home/Movies/Shows empty.
    private func bestAvailableOfficialCatalogRows() -> [MediaRow] {
        var candidates: [[MediaRow]] = []
        if let snapshot = loadOfficialCatalogSnapshotRows(), !snapshot.isEmpty {
            candidates.append(snapshot)
        }
        if let provisional = loadOfficialCatalogProvisionalSnapshotRows(), !provisional.isEmpty {
            candidates.append(provisional)
        }
        let compactSource = canonicalizedCatalogRows(cachedCatalogRows())
        let compact = officialRows(from: compactSource)
        if !compact.isEmpty { candidates.append(compact) }
        let visibleSource = canonicalizedCatalogRows(rows)
        let visible = officialRows(from: visibleSource)
        if !visible.isEmpty { candidates.append(visible) }
        return candidates.max { lhs, rhs in
            let left = catalogCompletenessScore(lhs)
            let right = catalogCompletenessScore(rhs)
            if left.rows != right.rows { return left.rows < right.rows }
            return left.items < right.items
        } ?? []
    }

    /// Never regress a healthy official baseline. Fresh rows update matching entries,
    /// but omitted rows and severely truncated rows stay backed by the durable snapshot
    /// until a complete replacement is available.
    private func nonRegressingOfficialCatalogRows(
        _ candidateRows: [MediaRow],
        baseline baselineRows: [MediaRow]
    ) -> [MediaRow] {
        let candidate = canonicalizedCatalogRows(candidateRows)
        let baseline = canonicalizedCatalogRows(baselineRows)
        guard !baseline.isEmpty else { return candidate }
        guard !candidate.isEmpty else { return baseline }

        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.id, $0) })
        var candidateByTitle: [String: MediaRow] = [:]
        for row in candidate where candidateByTitle[normalizedCatalogName(row.title)] == nil {
            candidateByTitle[normalizedCatalogName(row.title)] = row
        }
        var consumedCandidateIDs = Set<String>()
        var merged: [MediaRow] = []

        func declaredRowKind(_ row: MediaRow) -> String? {
            let title = row.title.lowercased()
            let saysMovie = title.contains("movie") || title.contains("film")
            let saysShow = title.contains("tv show") || title.contains("shows") || title.contains("series")
            if saysMovie != saysShow { return saysMovie ? "movie" : "series" }
            let id = row.id.lowercased()
            if id.hasPrefix("movie-") || id.hasPrefix("trakt-movie-") { return "movie" }
            if id.hasPrefix("series-") || id.hasPrefix("show-") || id.hasPrefix("tv-") || id.hasPrefix("trakt-show-") { return "series" }
            return nil
        }

        for oldRow in baseline {
            let fresh = candidateByID[oldRow.id] ?? candidateByTitle[normalizedCatalogName(oldRow.title)]
            if let fresh {
                consumedCandidateIDs.insert(fresh.id)
                let oldKind = declaredRowKind(oldRow)
                let freshKind = declaredRowKind(fresh)
                if let oldKind, let freshKind, oldKind != freshKind {
                    // vBRDC199: a fuller but type-corrupted v198 snapshot must never beat a
                    // fresh manifest-authoritative replacement just because it has more cards.
                    merged.append(fresh)
                } else {
                    let minimumHealthyItems = max(2, Int(ceil(Double(oldRow.items.count) * 0.70)))
                    merged.append(fresh.items.count >= minimumHealthyItems ? fresh : oldRow)
                }
            } else {
                merged.append(oldRow)
            }
        }
        merged.append(contentsOf: candidate.filter { !consumedCandidateIDs.contains($0.id) })
        let canonical = canonicalizedCatalogRows(merged)
        let freshScore = catalogCompletenessScore(candidate)
        let mergedScore = catalogCompletenessScore(canonical)
        if mergedScore.rows > freshScore.rows || mergedScore.items > freshScore.items {
            print("[CatalogPermanence][v1050] prevented catalog regression freshRows=\(freshScore.rows) durableRows=\(mergedScore.rows)")
        }
        return canonical
    }

    @discardableResult
    private func restoreBestOfficialCatalogCacheIfNeeded(reason: String) -> Bool {
        guard allInOneCatalogsEnabled else { return false }
        let durableRows = bestAvailableOfficialCatalogRows()
        guard !durableRows.isEmpty else { return false }
        let expectedVisibleRows = applyBuiltInCatalogRowPreferences(to: durableRows)
        let visibleOfficial = allInOneCatalogsEnabled ? canonicalizedCatalogRows(rows) : officialRows(from: rows)
        let durableScore = catalogCompletenessScore(expectedVisibleRows)
        let visibleScore = catalogCompletenessScore(visibleOfficial)
        guard visibleScore.rows < durableScore.rows || visibleScore.items < durableScore.items else { return false }
        let restored = updateVisibleCatalogRows(durableRows)
        if restored {
            status = "Showing the complete cached catalog while checking for updates…"
            print("[CatalogPermanence][v1050] durable catalog restored visibleRows=\(durableScore.rows) reason=\(reason)")
        }
        return restored
    }

    private func structurallyValidSnapshotRows(_ candidateRows: [MediaRow]) -> [MediaRow] {
        var seenRows = Set<String>()
        var output: [MediaRow] = []
        for row in candidateRows {
            let rowID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rowID.isEmpty, !title.isEmpty, seenRows.insert(rowID).inserted else { continue }
            var seenItems = Set<String>()
            let items = row.items.filter { item in
                let itemID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let itemTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !itemID.isEmpty, !itemTitle.isEmpty, seenItems.insert(itemID).inserted else { return false }
                guard let rawPoster = item.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let posterURL = URL(string: rawPoster),
                      let scheme = posterURL.scheme?.lowercased(),
                      scheme == "https" || scheme == "http",
                      posterURL.host != nil else { return false }
                return true
            }
            guard !items.isEmpty else { continue }
            output.append(MediaRow(id: rowID, title: title, items: items, presentation: row.presentation))
        }
        return output
    }

    private func decodeOfficialCatalogSnapshot(
        at url: URL,
        expectedSource: String = "official-all-in-one"
    ) -> [MediaRow]? {
        let cacheKey = "\(expectedSource)|\(url.path)"
        if let cached = officialCatalogDecodedSnapshotCache[cacheKey] { return cached }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= officialCatalogMaximumSnapshotBytes else { return nil }
            let snapshot = try JSONDecoder().decode(CatalogReliabilitySnapshot.self, from: data)
            guard snapshot.schemaVersion == officialCatalogSnapshotSchemaVersion,
                  snapshot.source == expectedSource else { return nil }
            let rows = structurallyValidSnapshotRows(snapshot.rows)
            guard rows.count == snapshot.rows.count, !rows.isEmpty else { return nil }
            officialCatalogDecodedSnapshotCache[cacheKey] = rows
            return rows
        } catch {
            officialCatalogDecodedSnapshotCache.removeValue(forKey: cacheKey)
            return nil
        }
    }

    private func loadOfficialCatalogProvisionalSnapshotRows() -> [MediaRow]? {
        guard let url = officialCatalogProvisionalSnapshotURL() else { return nil }
        if let rows = decodeOfficialCatalogSnapshot(at: url, expectedSource: "official-all-in-one-provisional") {
            return rows
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            print("[CatalogPermanence][v1050] discarded invalid provisional snapshot")
        }
        return nil
    }

    private func loadOfficialCatalogSnapshotRows() -> [MediaRow]? {
        let fm = FileManager.default
        let currentURL = officialCatalogSnapshotURL()
        let previousURL = officialCatalogSnapshotURL(previous: true)
        var candidates: [(url: URL, rows: [MediaRow], isPrevious: Bool)] = []

        if let currentURL {
            if let rows = decodeOfficialCatalogSnapshot(at: currentURL) {
                candidates.append((currentURL, rows, false))
            } else if fm.fileExists(atPath: currentURL.path) {
                try? fm.removeItem(at: currentURL)
                print("[CatalogReliability] discarded an invalid current protected snapshot")
            }
        }
        if let previousURL, let rows = decodeOfficialCatalogSnapshot(at: previousURL) {
            candidates.append((previousURL, rows, true))
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let left = catalogCompletenessScore(lhs.rows)
            let right = catalogCompletenessScore(rhs.rows)
            if left.rows != right.rows { return left.rows < right.rows }
            return left.items < right.items
        }) else { return nil }

        // Phase 12A: if the rollback snapshot is fuller than current, heal current
        // immediately so every subsequent cold launch starts from the complete set.
        if best.isPrevious, let currentURL, let data = try? Data(contentsOf: best.url) {
            try? data.write(to: currentURL, options: [.atomic])
            print("[CatalogPermanence][v1050] recovered fuller rollback snapshot rows=\(best.rows.count)")
        }
        return best.rows
    }

    /// Phase 12A uses the fuller current/rollback snapshot as the durable baseline.
    /// A network response may refresh it, but a smaller transient response cannot erase
    /// rows that were already verified and cached.
    private func bestOfficialCatalogSnapshotRowsForRepair() -> [MediaRow]? {
        let rows = loadOfficialCatalogSnapshotRows()
        return rows?.isEmpty == false ? rows : nil
    }

    private func catalogSnapshotIdentity(_ rows: [MediaRow]) -> String {
        rows.map { row in
            let itemIdentity = row.items.prefix(4).map(\.id).joined(separator: ",")
            return "\(row.id):\(row.items.count):\(itemIdentity)"
        }.joined(separator: "|")
    }

    @discardableResult
    private func persistOfficialCatalogProvisionalSnapshot(_ rows: [MediaRow]) -> Bool {
        guard let url = officialCatalogProvisionalSnapshotURL() else { return false }
        let canonicalRows = canonicalizedCatalogRows(rows)
        guard canonicalRows.count >= officialCatalogMinimumProvisionalRows else { return false }
        if let existing = decodeOfficialCatalogSnapshot(at: url, expectedSource: "official-all-in-one-provisional"),
           catalogSnapshotIdentity(existing) == catalogSnapshotIdentity(canonicalRows) {
            return true
        }
        do {
            let snapshot = CatalogReliabilitySnapshot(
                schemaVersion: officialCatalogSnapshotSchemaVersion,
                createdAt: Date(),
                source: "official-all-in-one-provisional",
                rows: canonicalRows
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            guard data.count <= officialCatalogMaximumSnapshotBytes else { return false }
            try data.write(to: url, options: [.atomic])
            print("[CatalogPermanence][v1050] provisional snapshot saved rows=\(canonicalRows.count)")
            return true
        } catch {
            print("[CatalogPermanence][v1050] provisional snapshot save failed")
            return false
        }
    }

    @discardableResult
    private func persistOfficialCatalogSnapshot(_ rows: [MediaRow]) -> Bool {
        guard let currentURL = officialCatalogSnapshotURL(),
              let previousURL = officialCatalogSnapshotURL(previous: true) else { return false }
        let existingBaseline = loadOfficialCatalogSnapshotRows() ?? []
        let canonicalRows = nonRegressingOfficialCatalogRows(rows, baseline: existingBaseline)
        guard !canonicalRows.isEmpty else { return false }
        if let existing = decodeOfficialCatalogSnapshot(at: currentURL),
           catalogSnapshotIdentity(existing) == catalogSnapshotIdentity(canonicalRows) {
            return true
        }
        do {
            let snapshot = CatalogReliabilitySnapshot(
                schemaVersion: officialCatalogSnapshotSchemaVersion,
                createdAt: Date(),
                source: "official-all-in-one",
                rows: canonicalRows
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            guard data.count <= officialCatalogMaximumSnapshotBytes else {
                print("[CatalogReliability] verified snapshot exceeded the safe size limit")
                return false
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: currentURL.path) {
                try? fm.removeItem(at: previousURL)
                try fm.copyItem(at: currentURL, to: previousURL)
            }
            try data.write(to: currentURL, options: [.atomic])
            if let provisionalURL = officialCatalogProvisionalSnapshotURL() {
                try? fm.removeItem(at: provisionalURL)
            }
            print("[CatalogReliability] protected snapshot promoted rows=\(canonicalRows.count)")
            return true
        } catch {
            print("[CatalogReliability] protected snapshot promotion failed")
            return false
        }
    }

    private func migrateBuiltInCatalogPreferences(to newRows: [MediaRow], previousRows: [MediaRow]) {
        let newIDs = newRows.map(\.id)
        let newIDSet = Set(newIDs)
        let previousTitleByID = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, normalizedCatalogName($0.title)) })
        var newIDByTitle: [String: String] = [:]
        for row in newRows where newIDByTitle[normalizedCatalogName(row.title)] == nil {
            newIDByTitle[normalizedCatalogName(row.title)] = row.id
        }
        func migratedID(_ oldID: String) -> String? {
            if newIDSet.contains(oldID) { return oldID }
            guard let oldTitle = previousTitleByID[oldID] else { return nil }
            return newIDByTitle[oldTitle]
        }

        let accountDescriptorIDs = Set(Self.traktCustomizationDescriptors.map(\.id))
        let savedHidden = UserDefaults.standard.stringArray(forKey: builtInCatalogHiddenRowIDsKey) ?? []
        var hiddenSeen = Set<String>()
        let migratedHidden = savedHidden.compactMap { oldID -> String? in
            if accountDescriptorIDs.contains(oldID) { return oldID }
            return migratedID(oldID)
        }.filter { hiddenSeen.insert($0).inserted }

        let savedOrder = UserDefaults.standard.stringArray(forKey: builtInCatalogCustomRowOrderKey) ?? []
        var orderSeen = Set<String>()
        var migratedOrder: [String] = []
        // vBRDC199: official-catalog refreshes may migrate changing server row IDs, but they
        // must never delete account/local customization IDs. vBRDC198 accidentally ran every
        // saved ID through the official-row migration map, which stripped all Trakt IDs after
        // the next built-in refresh and made Move to Top appear to reset itself.
        for oldID in savedOrder {
            if accountDescriptorIDs.contains(oldID) {
                if orderSeen.insert(oldID).inserted { migratedOrder.append(oldID) }
            } else if let mapped = migratedID(oldID), orderSeen.insert(mapped).inserted {
                migratedOrder.append(mapped)
            }
        }
        migratedOrder.append(contentsOf: newIDs.filter { orderSeen.insert($0).inserted })
        // Keep account rows discoverable even when this migration runs before Trakt connects.
        migratedOrder.append(contentsOf: Self.traktCustomizationDescriptors.map(\.id).filter { orderSeen.insert($0).inserted })

        if migratedHidden != savedHidden {
            UserDefaults.standard.set(migratedHidden, forKey: builtInCatalogHiddenRowIDsKey)
        }
        if migratedOrder != savedOrder {
            UserDefaults.standard.set(migratedOrder, forKey: builtInCatalogCustomRowOrderKey)
        }
    }

    /// v1040 repairs a transiently incomplete official batch using only rows that are
    /// still declared by the current manifest. Missing rows and severely truncated rows
    /// are recovered from the protected snapshot; rows removed from the manifest are not
    /// resurrected. This keeps all published rows visible without preserving obsolete ones.
    private func repairedOfficialCatalogRows(
        _ candidateRows: [MediaRow],
        catalogs: [StremioCatalog],
        manifestName: String
    ) -> [MediaRow] {
        guard !catalogs.isEmpty,
              let previousRows = bestOfficialCatalogSnapshotRowsForRepair(),
              !previousRows.isEmpty else { return candidateRows }

        var freshByID: [String: MediaRow] = [:]
        var previousByID: [String: MediaRow] = [:]
        var freshByTitle: [String: MediaRow] = [:]
        var previousByTitle: [String: MediaRow] = [:]
        for row in candidateRows {
            if freshByID[row.id] == nil { freshByID[row.id] = row }
            let titleKey = normalizedCatalogName(row.title)
            if freshByTitle[titleKey] == nil { freshByTitle[titleKey] = row }
        }
        for row in previousRows {
            if previousByID[row.id] == nil { previousByID[row.id] = row }
            let titleKey = normalizedCatalogName(row.title)
            if previousByTitle[titleKey] == nil { previousByTitle[titleKey] = row }
        }

        var repaired: [MediaRow] = []
        var consumedFreshIDs = Set<String>()
        for catalog in catalogs {
            let type = (catalog.type ?? "movie").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (catalog.id ?? "popular").trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedID = "\(type)-\(id)-\(manifestName)"
            let expectedTitle = cleanAllInOneRowTitle(catalog.name ?? id.capitalized)
            let titleKey = normalizedCatalogName(expectedTitle)
            let fresh = freshByID[expectedID] ?? freshByTitle[titleKey]
            let previousCandidate = previousByID[expectedID] ?? previousByTitle[titleKey]
            let normalizedExpectedType = type.lowercased() == "show" || type.lowercased() == "tv" ? "series" : type.lowercased()
            let previous: MediaRow? = {
                guard let previousCandidate else { return nil }
                let previousID = previousCandidate.id.lowercased()
                if normalizedExpectedType == "movie", previousID.hasPrefix("series-") || previousID.hasPrefix("show-") || previousID.hasPrefix("tv-") { return nil }
                if normalizedExpectedType == "series", previousID.hasPrefix("movie-") { return nil }
                return previousCandidate
            }()

            if let fresh {
                consumedFreshIDs.insert(fresh.id)
                if let previous {
                    let minimumHealthyItems = max(2, Int(ceil(Double(previous.items.count) * 0.55)))
                    repaired.append(fresh.items.count >= minimumHealthyItems ? fresh : previous)
                } else {
                    repaired.append(fresh)
                }
            } else if let previous {
                repaired.append(previous)
            }
        }

        // Preserve legitimate server rows not enumerated in older manifest variants.
        repaired.append(contentsOf: candidateRows.filter { !consumedFreshIDs.contains($0.id) })
        let canonical = canonicalizedCatalogRows(repaired)
        if canonical.count > candidateRows.count {
            print("[CatalogReliability][v1040] repaired official rows fresh=\(candidateRows.count) recovered=\(canonical.count - candidateRows.count) total=\(canonical.count)")
        }
        return canonical
    }

    private func validatedOfficialCatalogRows(
        _ candidateRows: [MediaRow],
        expectedRowCount: Int?
    ) throws -> [MediaRow] {
        let previousRows = bestOfficialCatalogSnapshotRowsForRepair() ?? []
        let structurallyValidRows = structurallyValidSnapshotRows(candidateRows)
        guard structurallyValidRows.count == candidateRows.count else { throw CatalogReliabilityError.malformedCatalog }
        let canonicalCandidate = canonicalizedCatalogRows(structurallyValidRows)
        guard canonicalCandidate.count == structurallyValidRows.count else { throw CatalogReliabilityError.malformedCatalog }

        // Phase 12A: a network response may refresh the durable set, but it may not
        // shrink it. Missing or badly truncated rows remain supplied by the snapshot.
        let rows = nonRegressingOfficialCatalogRows(canonicalCandidate, baseline: previousRows)
        let expected = max(expectedRowCount ?? 0, officialCatalogFullPublishedRows)
        let provisionalFromManifest = max(
            officialCatalogMinimumProvisionalRows,
            Int(ceil(Double(expected) * 0.55))
        )
        let minimumRows = previousRows.isEmpty
            ? min(officialCatalogFullPublishedRows, provisionalFromManifest)
            : previousRows.count
        guard rows.count >= minimumRows else { throw CatalogReliabilityError.incompleteCatalog }

        let totalItems = rows.reduce(0) { $0 + $1.items.count }
        let previousTotalItems = previousRows.reduce(0) { $0 + $1.items.count }
        let minimumItems = max(rows.count * 2, Int(Double(previousTotalItems) * 0.70))
        guard totalItems >= minimumItems else { throw CatalogReliabilityError.incompleteCatalog }

        migrateBuiltInCatalogPreferences(to: rows, previousRows: previousRows)
        if rows.count >= officialCatalogFullPublishedRows {
            _ = persistOfficialCatalogSnapshot(rows)
        } else {
            _ = persistOfficialCatalogProvisionalSnapshot(rows)
            print("[CatalogPermanence][v1050] publishing provisional official rows=\(rows.count); protected snapshot unchanged")
        }
        return rows
    }

    private func trustedOfficialEndpoint(_ raw: String?, relativeTo manifestURL: URL) -> String? {
        guard let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty,
              let resolved = URL(string: clean, relativeTo: manifestURL.deletingLastPathComponent())?.absoluteURL,
              let host = resolved.host?.lowercased(),
              let scheme = resolved.scheme?.lowercased() else { return nil }
        let manifestHost = manifestURL.host?.lowercased()
        let trustedHost = host == manifestHost || host == "catalog.skylinejay187.it.com" || host == "192.168.100.55"
        let trustedScheme = scheme == "https" || (scheme == "http" && host == "192.168.100.55")
        guard trustedHost, trustedScheme else { return nil }
        return resolved.absoluteString
    }

    private func validateAndSanitizeOfficialManifest(_ manifest: inout StremioManifest, manifestURL: URL) throws {
        guard manifest.debridChannels?.allInOne == true else { throw CatalogReliabilityError.invalidManifest }
        let catalogs = manifest.catalogs ?? []
        let batch = trustedOfficialEndpoint(manifest.debridChannels?.batchRowsURL, relativeTo: manifestURL)
        let search = trustedOfficialEndpoint(manifest.debridChannels?.searchURL, relativeTo: manifestURL)
        if manifest.debridChannels?.batchRowsURL != nil, batch == nil { throw CatalogReliabilityError.untrustedEndpoint }
        if manifest.debridChannels?.searchURL != nil, search == nil { throw CatalogReliabilityError.untrustedEndpoint }
        manifest.debridChannels?.batchRowsURL = batch
        manifest.debridChannels?.searchURL = search
        guard batch != nil || !catalogs.isEmpty else { throw CatalogReliabilityError.invalidManifest }
        var seen = Set<String>()
        for catalog in catalogs {
            let id = (catalog.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = (catalog.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !type.isEmpty, seen.insert("\(type)|\(id)").inserted else {
                throw CatalogReliabilityError.invalidManifest
            }
        }
    }

    private func fetchCatalogData(_ request: URLRequest, attempts: Int) async throws -> (Data, URLResponse) {
        var lastError: Error = CatalogReliabilityError.unavailable
        for attempt in 0..<max(1, attempts) {
            do {
                let (data, response) = try await Self.catalogFastURLSession.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let retryable = http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)
                    if !retryable { throw URLError(.badServerResponse) }
                    throw URLError(.cannotLoadFromNetwork)
                }
                guard !data.isEmpty else { throw URLError(.zeroByteResource) }
                guard data.count <= 32_000_000 else { throw CatalogReliabilityError.malformedCatalog }
                return (data, response)
            } catch {
                lastError = error
                guard attempt + 1 < max(1, attempts), !Task.isCancelled else { break }
                let delay: UInt64 = attempt == 0 ? 350_000_000 : 900_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }

    private func safeCatalogFailureDescription(for urlString: String, error: Error) -> String {
        if isAllInOneManifestURL(urlString) {
            return "Official catalog service unavailable"
        }
        let host = URL(string: urlString)?.host ?? "Personal catalog"
        return "\(host): \(error.localizedDescription)"
    }

    private func safeCatalogLogLabel(for urlString: String) -> String {
        isAllInOneManifestURL(urlString) ? "official-catalog" : (URL(string: urlString)?.host ?? "personal-catalog")
    }

    private func cachedCatalogRows() -> [MediaRow] {
        guard let data = UserDefaults.standard.data(forKey: catalogRowsCacheKey) else { return [] }
        guard let cached = try? JSONDecoder().decode([CachedCatalogRow].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: catalogRowsCacheKey)
            print("[CatalogReliability] discarded an incompatible compact cache")
            return []
        }
        return cached.map(\.mediaRow)
    }

    private func persistCatalogRowsCache(_ rows: [MediaRow]) {
        // Phase 12A: never erase a usable launch cache because a refresh produced an
        // empty/transient result. The toggle still controls whether official rows are
        // displayed; preserving bytes here only protects the next enabled cold launch.
        guard !rows.isEmpty else { return }
        let compactRows = rows.prefix(8).map { row in
            MediaRow(id: row.id, title: row.title, items: Array(row.items.prefix(12)), presentation: row.presentation)
        }
        let cached = compactRows.map(CachedCatalogRow.init)
        if let data = try? JSONEncoder().encode(cached), data.count < 300_000 {
            UserDefaults.standard.set(data, forKey: catalogRowsCacheKey)
        }
    }

    @discardableResult
    private func updateVisibleCatalogRows(_ newRows: [MediaRow]) -> Bool {
        guard !newRows.isEmpty else { return false }
        // v1034 Phase 6: publish only canonical, poster-verified row data. Phase 12A
        // additionally prevents an enabled official catalog from regressing below its
        // fullest durable/visible baseline while a network refresh is incomplete.
        var canonicalRows = canonicalizedCatalogRows(newRows)
        guard !canonicalRows.isEmpty else { return false }
        if allInOneCatalogsEnabled {
            // catalogBrowsingManifestURLs() exposes only the hidden official endpoint
            // while this toggle is enabled, so every row reaching this publication path
            // is already official. Avoid the old addon-name heuristic that could turn a
            // successful 83-row response into an empty candidate after a server rename.
            let baseline = bestAvailableOfficialCatalogRows()
            canonicalRows = nonRegressingOfficialCatalogRows(canonicalRows, baseline: baseline)
        }
        let customizedRows = applyBuiltInCatalogRowPreferences(to: canonicalRows)
        // An empty result is valid only when the person intentionally hid every official
        // row. The full canonical set remains in the protected snapshot and Search index.
        let retainedAccountRows = rows.filter { row in
            isPlaybackDerivedCatalogRow(row) || isTraktCatalogRow(row)
        }
        var combinedRows = customizedRows + retainedAccountRows
        if let local = localContinueWatchingRow(existingItems: (customizedRows + retainedAccountRows.filter(isTraktCatalogRow)).flatMap(\.items)) {
            combinedRows.removeAll { isPlaybackDerivedCatalogRow($0) }
            combinedRows.append(local)
        }
        let nextRows = prioritizedRowsForDisplay(combinedRows)

        // vBRDC119: @Published emits before assignment, even when the new Array is value-
        // identical. Provider refreshes frequently return the same canonical rows, so the
        // old unconditional `rows = ...` invalidated every catalog observer, rebuilt the
        // persistent rail projection, cleared Search, and rewrote the launch cache for no
        // visible change. Keep the existing value/identity when the payload is identical.
        guard nextRows != rows else { return false }

        rows = nextRows
        // Recent Search results must never outlive the active catalog identity set.
        unifiedSearchCache.removeAll()
        if allInOneCatalogsEnabled {
            // Official launch bytes remain official forever; external/account rows use
            // their own caches and cannot evict the fast All-in-One snapshot.
            persistCatalogRowsCache(canonicalRows.filter(isOfficialCatalogRow))
        } else {
            persistRows(customizedRows.filter { !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0) },
                        forKey: externalCatalogRowsCacheKey, maxRows: 80, maxItemsPerRow: 48)
        }
        return true
    }

    private func withTimeout<T>(_ seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let value = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return value
        }
    }


    func searchResults(for query: String) -> [MediaItem] {
        // v467: Search must respect the final user catalog priority order even if
        // rows were originally loaded before the user moved a JSON catalog above
        // Cinemeta. The display layer is the last authority.
        let all = prioritizedRowsForDisplay().flatMap { $0.items }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        let q = trimmed.lowercased()
        let matches = all.filter { item in
            let haystack = [item.title, item.year, item.type, item.catalog, item.description, item.rating] + item.genres
            return haystack.joined(separator: " ").lowercased().contains(q)
        }
        return Array(canonicalizedCatalogItems(matches).prefix(40))
    }


    // MARK: - v1010 Phase 4B unified fast Search

    /// Returns the already downloaded official catalog matches synchronously so cards can
    /// appear before the debounce/network providers finish. The index is captured before
    /// Phase 4A row visibility filtering, so hidden rows are included automatically.
    func unifiedSearchImmediateResults(for query: String) -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let local = localUnifiedSearchResults(for: trimmed)
        guard let cached = cachedUnifiedSearchResults(for: trimmed) else { return local }
        return mergeUnifiedSearchSources([local, cached], limit: 96)
    }

    /// Performs one built-in database search plus Cinemeta and TMDB concurrently. This
    /// intentionally does not enumerate the 83 official rows or create provider catalog rows.
    func unifiedSearchResults(for query: String, tmdbApiKey: String) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !Task.isCancelled else { return [] }

        let local = localUnifiedSearchResults(for: trimmed)

        if let cached = cachedUnifiedSearchResults(for: trimmed) {
            return mergeUnifiedSearchSources([local, cached], limit: 96)
        }

        async let builtInTask = searchBuiltInCatalogDatabase(for: trimmed)
        async let cinemetaTask = cinemetaUnifiedSearchResults(for: trimmed)
        async let tmdbTask = tmdbSearchResults(for: trimmed, apiKey: tmdbApiKey)
        let (builtIn, cinemeta, tmdb) = await (builtInTask, cinemetaTask, tmdbTask)
        guard !Task.isCancelled else { return [] }

        // Priority is deliberate: local official/catalog cards win, then the single server
        // database response, then Cinemeta, then TMDB. Lower-priority providers may only fill
        // missing metadata; they never replace a verified local poster/identity.
        let merged = mergeUnifiedSearchSources([local, builtIn, cinemeta, tmdb], limit: 96)
        rememberUnifiedSearchResults(merged, for: trimmed)
        return merged
    }

    private func localUnifiedSearchResults(for query: String) -> [MediaItem] {
        let localItems = builtInUnifiedSearchIndex + rows.flatMap(\.items)
        return normalizedUnifiedSearchItems(localItems, query: query, displayCatalogOverride: nil)
    }

    private func cachedUnifiedSearchResults(for query: String) -> [MediaItem]? {
        let key = normalizedAddonSearchQuery(query)
        guard let entry = unifiedSearchCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) <= unifiedSearchCacheTTL else {
            unifiedSearchCache.removeValue(forKey: key)
            return nil
        }
        return entry.items
    }

    private func rememberUnifiedSearchResults(_ items: [MediaItem], for query: String) {
        guard !items.isEmpty else { return }
        let now = Date()
        unifiedSearchCache = unifiedSearchCache.filter {
            now.timeIntervalSince($0.value.createdAt) <= unifiedSearchCacheTTL
        }
        unifiedSearchCache[normalizedAddonSearchQuery(query)] = UnifiedSearchCacheEntry(
            createdAt: now,
            items: Array(items.prefix(96))
        )
        if unifiedSearchCache.count > 12 {
            let newest = unifiedSearchCache.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(12)
            unifiedSearchCache = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    private func searchBuiltInCatalogDatabase(for query: String) async -> [MediaItem] {
        let endpoints = await builtInUnifiedSearchEndpoints(for: query)
        for endpoint in endpoints {
            guard !Task.isCancelled else { return [] }
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 12)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/1010 UnifiedDatabaseSearch", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return [] }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                let decoded = decodeBuiltInUnifiedSearchPayload(data, query: query)
                guard !decoded.isEmpty else { continue }

                // Remember only discovered items in memory. This improves hidden-row detail
                // hydration without persisting or duplicating the official catalog database.
                builtInUnifiedSearchIndex = mergeUnifiedSearchSources(
                    [builtInUnifiedSearchIndex, decoded],
                    limit: 10_000
                )
                return decoded
            } catch {
                if Task.isCancelled { return [] }
                continue
            }
        }
        return []
    }

    private func builtInUnifiedSearchEndpoints(for query: String) async -> [URL] {
        let manifestBaseString = normalizedStremioBase(from: builtInAllInOneManifestURL)
        let manifestBase = URL(string: manifestBaseString)

        if builtInUnifiedSearchURL == nil && builtInUnifiedBatchRowsURL == nil {
            for candidate in manifestURLCandidates(from: builtInAllInOneManifestURL) {
                guard !Task.isCancelled, let url = URL(string: candidate) else { break }
                do {
                    var request = URLRequest(url: url, timeoutInterval: 8)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/1010 UnifiedSearchManifest", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    let manifest = try JSONDecoder().decode(StremioManifest.self, from: data)
                    builtInUnifiedSearchURL = manifest.debridChannels?.searchURL
                    builtInUnifiedBatchRowsURL = manifest.debridChannels?.batchRowsURL
                    break
                } catch {
                    continue
                }
            }
        }

        var rawEndpoints: [String] = []
        func add(_ raw: String?) {
            let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !clean.isEmpty, !rawEndpoints.contains(clean) else { return }
            rawEndpoints.append(clean)
        }

        // Prefer a server-advertised one-shot database endpoint. Keep the existing
        // Phase 2 batch endpoint as a fallback only; either path is one server request,
        // never an 83-row fan-out. Guessed paths are used only when the manifest exposes
        // neither capability, preserving compatibility with an older hidden manifest.
        add(builtInUnifiedSearchURL)
        add(builtInUnifiedBatchRowsURL)
        if rawEndpoints.isEmpty {
            add("\(manifestBaseString)/search.json")
            add("\(manifestBaseString)/search")
        }

        var output: [URL] = []
        for raw in rawEndpoints {
            let resolved: URL?
            if let absolute = URL(string: raw), absolute.scheme != nil {
                resolved = absolute
            } else if let manifestBase {
                resolved = URL(string: raw, relativeTo: manifestBase)?.absoluteURL
            } else {
                resolved = nil
            }
            guard let resolved,
                  var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { continue }
            var queryItems = components.queryItems ?? []
            let existingNames = Set(queryItems.map { $0.name.lowercased() })
            if !existingNames.contains("q") { queryItems.append(URLQueryItem(name: "q", value: query)) }
            if !existingNames.contains("query") { queryItems.append(URLQueryItem(name: "query", value: query)) }
            if !existingNames.contains("search") { queryItems.append(URLQueryItem(name: "search", value: query)) }
            if !existingNames.contains("limit") { queryItems.append(URLQueryItem(name: "limit", value: "96")) }
            if !existingNames.contains("types") { queryItems.append(URLQueryItem(name: "types", value: "movie,series")) }
            components.queryItems = queryItems
            if let url = components.url, !output.contains(url) { output.append(url) }
        }
        return output
    }

    private func decodeBuiltInUnifiedSearchPayload(_ data: Data, query: String) -> [MediaItem] {
        let decoder = JSONDecoder()
        if let batch = try? decoder.decode(DebridChannelsBatchCatalogResponse.self, from: data) {
            var items: [MediaItem] = []
            for row in batch.rows {
                items.append(contentsOf: mappedUnifiedSearchItems(
                    from: row.metas ?? [],
                    fallbackType: row.type,
                    catalogName: cleanAllInOneRowTitle(row.name),
                    query: query,
                    addonName: "Debrid Channels"
                ))
            }
            return mergeUnifiedSearchSources([items], limit: 96)
        }
        if let response = try? decoder.decode(CatalogResponse.self, from: data) {
            return mappedUnifiedSearchItems(
                from: response.metas ?? [],
                fallbackType: "movie",
                catalogName: "Search",
                query: query,
                addonName: "Debrid Channels"
            )
        }
        if let envelope = try? decoder.decode(UnifiedCatalogSearchEnvelope.self, from: data) {
            return mappedUnifiedSearchItems(
                from: envelope.metas,
                fallbackType: "movie",
                catalogName: "Search",
                query: query,
                addonName: "Debrid Channels"
            )
        }
        if let metas = try? decoder.decode([StremioMeta].self, from: data) {
            return mappedUnifiedSearchItems(
                from: metas,
                fallbackType: "movie",
                catalogName: "Search",
                query: query,
                addonName: "Debrid Channels"
            )
        }
        return []
    }

    private func mappedUnifiedSearchItems(
        from metas: [StremioMeta],
        fallbackType: String,
        catalogName: String,
        query: String,
        addonName: String?
    ) -> [MediaItem] {
        let raw = metas.compactMap { meta -> MediaItem? in
            guard let poster = Self.highest(meta.poster), PremiumArtworkURL.url(poster) != nil else { return nil }
            let title = (meta.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return MediaItem(
                id: meta.id ?? UUID().uuidString,
                tmdbId: meta.tmdbId,
                imdbId: meta.imdbId,
                tvdbId: meta.tvdbId,
                title: title,
                year: Self.firstYear(from: meta.releaseInfo),
                type: meta.type ?? fallbackType,
                catalog: catalogName,
                description: meta.description ?? "No description available yet.",
                genres: Array((meta.genres ?? [fallbackType.capitalized]).prefix(3)),
                rating: meta.imdbRating ?? "—",
                posterURL: poster,
                landscapeURL: Self.highest(meta.background ?? meta.poster) ?? poster,
                logoURL: Self.highest(meta.logo),
                previewURL: Self.previewURL(from: meta),
                addonName: addonName,
                addonIconURL: nil,
                cast: Array((meta.cast ?? []).prefix(8)),
                directors: Array((meta.directors ?? []).prefix(3))
            )
        }
        return normalizedUnifiedSearchItems(raw, query: query, displayCatalogOverride: nil)
    }

    private func cinemetaUnifiedSearchResults(for query: String) async -> [MediaItem] {
        async let movieTask = cinemetaUnifiedSearchResults(for: query, type: "movie")
        async let seriesTask = cinemetaUnifiedSearchResults(for: query, type: "series")
        let (movies, series) = await (movieTask, seriesTask)
        return mergeUnifiedSearchSources([movies, series], limit: 72)
    }

    private func cinemetaUnifiedSearchResults(for query: String, type: String) async -> [MediaItem] {
        guard !Task.isCancelled,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(encoded).json") else { return [] }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/1010 UnifiedMetadataSearch", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return [] }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
            return mappedUnifiedSearchItems(
                from: decoded.metas ?? [],
                fallbackType: type,
                catalogName: "Search",
                query: query,
                addonName: nil
            )
        } catch {
            return []
        }
    }

    private func normalizedUnifiedSearchItems(
        _ items: [MediaItem],
        query: String?,
        displayCatalogOverride: String?
    ) -> [MediaItem] {
        let queryKey = query.map(normalizedMatchText) ?? ""
        var ranked: [(score: Int, index: Int, item: MediaItem)] = []
        for (index, original) in items.enumerated() {
            guard PremiumArtworkURL.url(original.posterURL) != nil else { continue }
            let type = normalizedStremioType(original.type)
            guard type == "movie" || type == "series" else { continue }
            var item = original
            if let displayCatalogOverride { item.catalog = displayCatalogOverride }
            guard !queryKey.isEmpty else {
                ranked.append((0, index, item))
                continue
            }
            let title = normalizedMatchText(item.title)
            let metadata = normalizedMatchText(
                [item.title, item.year, item.description, item.catalog, item.rating]
                    .joined(separator: " ") + " " + item.genres.joined(separator: " ")
            )
            let score: Int
            if title == queryKey { score = 0 }
            else if title.hasPrefix(queryKey) { score = 1 }
            else if title.contains(queryKey) { score = 2 }
            else if metadata.contains(queryKey) { score = 3 }
            else { continue }
            ranked.append((score, index, item))
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.index < $1.index
        }.map(\.item)
    }

    private func mergeUnifiedSearchSources(_ sources: [[MediaItem]], limit: Int) -> [MediaItem] {
        var output: [MediaItem] = []
        var imdbIndex: [String: Int] = [:]
        var externalIndex: [String: Int] = [:]
        var titleYearIndex: [String: Int] = [:]

        func register(_ item: MediaItem, at index: Int) {
            if let imdb = unifiedSearchIMDbKey(item), imdbIndex[imdb] == nil { imdbIndex[imdb] = index }
            for key in unifiedSearchExternalKeys(item) where externalIndex[key] == nil { externalIndex[key] = index }
            if let key = unifiedSearchTitleYearKey(item), titleYearIndex[key] == nil { titleYearIndex[key] = index }
        }

        for original in sources.flatMap({ $0 }) {
            let item = normalizedCatalogIdentityFields(original)
            guard PremiumArtworkURL.url(item.posterURL) != nil else { continue }
            let candidateIndex: Int?
            if let imdb = unifiedSearchIMDbKey(item), let index = imdbIndex[imdb] {
                candidateIndex = index
            } else if let index = unifiedSearchExternalKeys(item).compactMap({ externalIndex[$0] }).first {
                candidateIndex = index
            } else if let key = unifiedSearchTitleYearKey(item), let index = titleYearIndex[key] {
                candidateIndex = index
            } else {
                candidateIndex = nil
            }
            let existingIndex = candidateIndex.flatMap { index in
                output.indices.contains(index) && catalogItemsShareCanonicalIdentity(output[index], item) ? index : nil
            }

            if let existingIndex {
                output[existingIndex] = mergeUnifiedSearchMetadata(
                    preferred: output[existingIndex],
                    fallback: item
                )
                register(output[existingIndex], at: existingIndex)
            } else {
                let index = output.count
                output.append(item)
                register(item, at: index)
            }
            if output.count >= limit { break }
        }
        return output
    }

    private func unifiedSearchIMDbKey(_ item: MediaItem) -> String? {
        guard let imdb = inferredIMDbID(for: item) else { return nil }
        return "imdb|\(normalizedStremioType(item.type))|\(imdb)\(catalogEpisodeIdentitySuffix(for: item))"
    }

    private func unifiedSearchExternalKeys(_ item: MediaItem) -> [String] {
        let type = normalizedStremioType(item.type)
        let suffix = catalogEpisodeIdentitySuffix(for: item)
        var keys: [String] = []
        func add(_ prefix: String, _ raw: String?) {
            guard let clean = normalizedCatalogIdentifier(raw) else { return }
            let key = "\(prefix)|\(type)|\(clean)\(suffix)"
            if !keys.contains(key) { keys.append(key) }
        }
        add("tmdb", inferredTMDBID(for: item))
        add("tvdb", inferredTVDBID(for: item))
        add("id", item.id)
        return keys
    }

    private func unifiedSearchTitleYearKey(_ item: MediaItem) -> String? {
        let title = normalizedMatchText(item.title)
        let year = catalogYear(from: item.year)
        guard !title.isEmpty, let year else { return nil }
        return "title|\(normalizedStremioType(item.type))|\(title)|\(year)\(catalogEpisodeIdentitySuffix(for: item))"
    }

    private func mergeUnifiedSearchMetadata(preferred: MediaItem, fallback: MediaItem) -> MediaItem {
        var merged = preferred
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        func missingText(_ value: String) -> Bool {
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower.isEmpty || lower == "—" || lower.contains("no description")
        }

        if clean(merged.imdbId) == nil { merged.imdbId = clean(fallback.imdbId) }
        if clean(merged.tmdbId) == nil { merged.tmdbId = clean(fallback.tmdbId) }
        if clean(merged.tvdbId) == nil { merged.tvdbId = clean(fallback.tvdbId) }
        if merged.year.filter(\.isNumber).isEmpty { merged.year = fallback.year }
        if missingText(merged.description), !missingText(fallback.description) { merged.description = fallback.description }
        if merged.genres.isEmpty { merged.genres = fallback.genres }
        if missingText(merged.rating), !missingText(fallback.rating) { merged.rating = fallback.rating }
        if PremiumArtworkURL.url(merged.posterURL) == nil { merged.posterURL = fallback.posterURL }
        if PremiumArtworkURL.url(merged.landscapeURL) == nil { merged.landscapeURL = fallback.landscapeURL }
        if clean(merged.logoURL) == nil { merged.logoURL = clean(fallback.logoURL) }
        if clean(merged.previewURL) == nil { merged.previewURL = clean(fallback.previewURL) }
        if clean(merged.addonName) == nil { merged.addonName = clean(fallback.addonName) }
        if clean(merged.addonIconURL) == nil { merged.addonIconURL = clean(fallback.addonIconURL) }
        if merged.cast.isEmpty { merged.cast = fallback.cast }
        if merged.directors.isEmpty { merged.directors = fallback.directors }
        if merged.castMembers.isEmpty { merged.castMembers = fallback.castMembers }
        return merged
    }


    // v470: Universal Search must actively query every configured Stremio/catalog addon,
    // not only the rows already loaded on Home. TMDB is metadata-only and should never
    // become the only playable identity shown in Search.
    func searchConfiguredCatalogAddons(for query: String) async -> [MediaItem] {
        await searchConfiguredCatalogAddons(for: query, limitToCinemeta: false)
    }

    func searchCinemetaCatalog(for query: String) async -> [MediaItem] {
        await searchConfiguredCatalogAddons(for: query, limitToCinemeta: true)
    }

    func searchConfiguredCatalogAddonsProgressively(
        for query: String,
        onStatus: @escaping @MainActor (AddonSearchProviderStatus) -> Void,
        onResults: @escaping @MainActor ([MediaItem]) -> Void
    ) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let manifests = catalogBrowsingManifestURLs()
        let primaryManifest = manifests.first(where: { !isCinemetaManifest($0) })
        let queryKey = normalizedAddonSearchQuery(trimmed)
        var merged: [MediaItem] = []
        var seen = Set<String>()
        var primaryCacheHasResults = false

        func append(_ items: [MediaItem]) {
            for item in items {
                let key = "\(item.id)|\(item.catalog)|\(item.addonName ?? "")"
                if seen.insert(key).inserted { merged.append(item) }
            }
            merged = Array(merged.prefix(120))
        }

        // v1000: publish the local/device-cached catalog first. Cinemeta cache is held
        // back unless the primary catalog has no usable local or network search result.
        for rawManifest in manifests where !isCinemetaManifest(rawManifest) {
            let provider = providerName(from: rawManifest, manifest: nil)
            if let cached = cachedAddonSearchResults(queryKey: queryKey, rawManifest: rawManifest), !cached.isEmpty {
                append(cached)
                if rawManifest == primaryManifest { primaryCacheHasResults = true }
                await onStatus(AddonSearchProviderStatus(provider: provider, state: .results, resultCount: cached.count, message: "cached"))
                await onResults(merged)
            } else {
                await onStatus(AddonSearchProviderStatus(provider: provider, state: .loading, resultCount: 0, message: "Loading..."))
            }
        }

        var primaryNetworkHasResults = false
        var remaining = manifests
        if let primaryManifest {
            remaining.removeAll { $0 == primaryManifest }
            let result = await searchSingleCatalogAddonProvider(rawManifest: primaryManifest, query: trimmed)
            if result.state == .results {
                append(result.items)
                cacheAddonSearchResults(result.items, queryKey: queryKey, rawManifest: result.rawManifest)
                primaryNetworkHasResults = !result.items.isEmpty
                await onResults(merged)
            }
            await onStatus(AddonSearchProviderStatus(provider: result.provider, state: result.state, resultCount: result.items.count, message: result.message))
        }

        let primaryHasResults = primaryCacheHasResults || primaryNetworkHasResults
        if primaryHasResults {
            remaining.removeAll { isCinemetaManifest($0) }
            if let primaryManifest, !isSameManifest(primaryManifest, builtInAllInOneManifestURL) {
                remaining.removeAll { isSameManifest($0, builtInAllInOneManifestURL) }
            }
        } else {
            for rawManifest in remaining where isCinemetaManifest(rawManifest) {
                let provider = providerName(from: rawManifest, manifest: nil)
                if let cached = cachedAddonSearchResults(queryKey: queryKey, rawManifest: rawManifest), !cached.isEmpty {
                    append(cached)
                    await onStatus(AddonSearchProviderStatus(provider: provider, state: .results, resultCount: cached.count, message: "fallback cache"))
                    await onResults(merged)
                } else {
                    await onStatus(AddonSearchProviderStatus(provider: provider, state: .loading, resultCount: 0, message: "Fallback loading..."))
                }
            }
        }

        // Query remaining configured catalogs in bounded batches. Cinemeta participates
        // only when the Debrid Channels primary catalog and its device cache returned none.
        let maxConcurrent = min(6, max(1, remaining.count))
        for chunkStart in stride(from: 0, to: remaining.count, by: maxConcurrent) {
            if Task.isCancelled { break }
            let chunk = Array(remaining[chunkStart..<min(chunkStart + maxConcurrent, remaining.count)])
            let chunkResults = await withTaskGroup(of: AddonCatalogSearchProviderResult.self, returning: [AddonCatalogSearchProviderResult].self) { group in
                for rawManifest in chunk {
                    group.addTask { [weak self] in
                        guard let self else {
                            return AddonCatalogSearchProviderResult(rawManifest: rawManifest, provider: rawManifest, state: .failed, message: "cancelled", items: [])
                        }
                        return await self.searchSingleCatalogAddonProvider(rawManifest: rawManifest, query: trimmed)
                    }
                }
                var results: [AddonCatalogSearchProviderResult] = []
                for await result in group { results.append(result) }
                return results
            }
            for result in chunkResults {
                if Task.isCancelled { break }
                if result.state == .results {
                    append(result.items)
                    cacheAddonSearchResults(result.items, queryKey: queryKey, rawManifest: result.rawManifest)
                }
                await onStatus(AddonSearchProviderStatus(provider: result.provider, state: result.state, resultCount: result.items.count, message: result.message))
                await onResults(merged)
            }
        }

        return merged
    }

    private struct AddonCatalogSearchProviderResult {
        var rawManifest: String
        var provider: String
        var state: AddonSearchProviderState
        var message: String
        var items: [MediaItem]
    }

    private func searchSingleCatalogAddonProvider(rawManifest: String, query: String) async -> AddonCatalogSearchProviderResult {
        let providerFallback = providerName(from: rawManifest, manifest: nil)
        let timeout: TimeInterval = rawManifest.lowercased().contains("mediafusion") ? 14 : 8
        do {
            let items = try await withTimeout(timeout) {
                try await self.searchSingleCatalogAddonProviderNetworkOnly(rawManifest: rawManifest, query: query)
            }
            let provider = items.first?.addonName ?? providerFallback
            if items.isEmpty {
                return AddonCatalogSearchProviderResult(rawManifest: rawManifest, provider: provider, state: .noResults, message: "No results", items: [])
            }
            return AddonCatalogSearchProviderResult(rawManifest: rawManifest, provider: provider, state: .results, message: "\(items.count) result\(items.count == 1 ? "" : "s")", items: items)
        } catch {
            let state: AddonSearchProviderState = (error as? URLError)?.code == .timedOut ? .timedOut : .failed
            return AddonCatalogSearchProviderResult(rawManifest: rawManifest, provider: providerFallback, state: state, message: state.rawValue, items: [])
        }
    }

    private func searchSingleCatalogAddonProviderNetworkOnly(rawManifest: String, query: String) async throws -> [MediaItem] {
        let urlSession = URLSession.shared
        let manifestCandidates = manifestURLCandidates(from: rawManifest)
        var manifestDecoded: StremioManifest? = nil
        var workingManifestURL: URL? = nil

        for candidate in manifestCandidates {
            guard let candidateURL = URL(string: candidate) else { continue }
            var manifestRequest = URLRequest(url: candidateURL, timeoutInterval: 5)
            manifestRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            manifestRequest.setValue("DebridChannels-tvOS/756 InstantAddonSearch", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await urlSession.data(for: manifestRequest)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                let decoded = try JSONDecoder().decode(StremioManifest.self, from: data)
                manifestDecoded = decoded
                workingManifestURL = candidateURL
                let identityName = decoded.name ?? candidateURL.host ?? "Stremio"
                let identityIcon = Self.highest(decoded.logo ?? decoded.icon)
                addonIdentities[rawManifest] = StremioAddonIdentity(name: identityName, iconURL: identityIcon, kind: addonKind(from: decoded))
                break
            } catch {
                continue
            }
        }

        guard let manifest = manifestDecoded, let manifestURL = workingManifestURL else { return [] }
        let kind = addonKind(from: manifest)
        guard kind == "catalog" || kind == "catalog+stream" else { return [] }
        let catalogs = manifest.catalogs ?? []
        guard !catalogs.isEmpty else { return [] }

        let base = URL(string: normalizedStremioBase(from: manifestURL.absoluteString)) ?? manifestURL.deletingLastPathComponent()
        let addonName = manifest.name ?? manifestURL.host ?? "Stremio"
        let addonIconURL = Self.highest(manifest.logo ?? manifest.icon)
        var results: [MediaItem] = []
        var seen = Set<String>()

        for catalog in catalogs {
            if Task.isCancelled { break }
            let type = catalog.type ?? "movie"
            guard type.lowercased().contains("movie") || type.lowercased().contains("series") || type.lowercased().contains("tv") else { continue }
            for searchURL in catalogSearchEndpointCandidates(base: base, catalog: catalog, query: query) {
                var request = URLRequest(url: searchURL, timeoutInterval: rawManifest.lowercased().contains("mediafusion") ? 8 : 5)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/756 InstantAddonSearch", forHTTPHeaderField: "User-Agent")
                do {
                    let (data, response) = try await urlSession.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
                    let metas = decoded.metas ?? []
                    for meta in metas {
                        guard let id = meta.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                        let title = (meta.name ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { continue }
                        let queryKey = normalizedMatchText(query)
                        let titleKey = normalizedMatchText(title)
                        let descKey = normalizedMatchText(meta.description ?? "")
                        let catalogKey = normalizedMatchText("\(catalog.name ?? "") \(catalog.id ?? "") \(addonName)")
                        guard titleKey.contains(queryKey) || descKey.contains(queryKey) || catalogKey.contains(queryKey) else { continue }
                        let uniqueKey = "\(addonName.lowercased())|\(catalog.name ?? catalog.id ?? "catalog")|\(id)"
                        guard seen.insert(uniqueKey).inserted else { continue }
                        results.append(MediaItem(
                            id: id,
                            tmdbId: meta.tmdbId,
                            imdbId: meta.imdbId,
                            tvdbId: meta.tvdbId,
                            title: title,
                            year: Self.firstYear(from: meta.releaseInfo),
                            type: meta.type ?? type,
                            catalog: catalog.name ?? catalog.id ?? addonName,
                            description: meta.description ?? "No description available yet.",
                            genres: Array((meta.genres ?? [type.capitalized]).prefix(3)),
                            rating: meta.imdbRating ?? "-",
                            posterURL: Self.highest(meta.poster),
                            landscapeURL: Self.highest(meta.background ?? meta.poster),
                            logoURL: Self.highest(meta.logo),
                            previewURL: Self.previewURL(from: meta),
                            addonName: addonName,
                            addonIconURL: addonIconURL,
                            seasonNumber: nil,
                            episodeNumber: nil,
                            cast: Array((meta.cast ?? []).prefix(8)),
                            directors: Array((meta.directors ?? []).prefix(3))
                        ))
                    }
                    if !metas.isEmpty { break }
                } catch {
                    continue
                }
            }
        }
        return Array(results.prefix(40))
    }

    private func normalizedAddonSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func addonSearchCacheID(queryKey: String, rawManifest: String) -> String {
        "\(queryKey)|\(rawManifest.lowercased())"
    }

    private func cachedAddonSearchResults(queryKey: String, rawManifest: String) -> [MediaItem]? {
        guard let data = UserDefaults.standard.data(forKey: addonSearchCacheKey),
              let cache = try? JSONDecoder().decode([String: [CachedCatalogItem]].self, from: data) else { return nil }
        return cache[addonSearchCacheID(queryKey: queryKey, rawManifest: rawManifest)]?.map(\.mediaItem)
    }

    private func cacheAddonSearchResults(_ items: [MediaItem], queryKey: String, rawManifest: String) {
        guard !items.isEmpty else { return }
        var cache: [String: [CachedCatalogItem]] = [:]
        if let data = UserDefaults.standard.data(forKey: addonSearchCacheKey),
           let decoded = try? JSONDecoder().decode([String: [CachedCatalogItem]].self, from: data) {
            cache = decoded
        }
        cache[addonSearchCacheID(queryKey: queryKey, rawManifest: rawManifest)] = items.prefix(40).map(CachedCatalogItem.init)
        if cache.count > 160 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.key < $1.key }.suffix(160))
        }
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: addonSearchCacheKey)
        }
    }

    private func searchConfiguredCatalogAddons(for query: String, limitToCinemeta: Bool) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let urlSession = URLSession.shared
        var results: [MediaItem] = []
        var seen = Set<String>()

        for rawManifest in catalogBrowsingManifestURLs() {
            guard !Task.isCancelled else { return [] }
            if limitToCinemeta && !rawManifest.lowercased().contains("cinemeta") { continue }
            let manifestCandidates = manifestURLCandidates(from: rawManifest)
            var manifestDecoded: StremioManifest? = nil
            var workingManifestURL: URL? = nil

            for candidate in manifestCandidates {
                guard !Task.isCancelled else { return [] }
                guard let candidateURL = URL(string: candidate) else { continue }
                do {
                    let manifestTimeout: TimeInterval = rawManifest.lowercased().contains("mediafusion") ? 18 : 9
                    var manifestRequest = URLRequest(url: candidateURL, timeoutInterval: manifestTimeout)
                    manifestRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                    manifestRequest.setValue("DebridChannels-tvOS/576 FastExact", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await urlSession.data(for: manifestRequest)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    let decoded = try JSONDecoder().decode(StremioManifest.self, from: data)
                    manifestDecoded = decoded
                    workingManifestURL = candidateURL
                    let identityName = decoded.name ?? candidateURL.host ?? "Stremio"
                    let identityIcon = Self.highest(decoded.logo ?? decoded.icon)
                    await MainActor.run {
                        self.addonIdentities[rawManifest] = StremioAddonIdentity(name: identityName, iconURL: identityIcon, kind: self.addonKind(from: decoded))
                    }
                    break
                } catch {
                    if Task.isCancelled { return [] }
                    continue
                }
            }

            guard let manifest = manifestDecoded, let manifestURL = workingManifestURL else { continue }
            let catalogs = manifest.catalogs ?? []
            guard !catalogs.isEmpty else { continue }
            let base = URL(string: normalizedStremioBase(from: manifestURL.absoluteString)) ?? manifestURL.deletingLastPathComponent()
            let addonName = manifest.name ?? manifestURL.host ?? "Stremio"
            let addonIconURL = Self.highest(manifest.logo ?? manifest.icon)

            for catalog in catalogs {
                guard !Task.isCancelled else { return [] }
                let type = catalog.type ?? "movie"
                guard type.lowercased().contains("movie") || type.lowercased().contains("series") || type.lowercased().contains("tv") else { continue }
                for searchURL in catalogSearchEndpointCandidates(base: base, catalog: catalog, query: trimmed) {
                    guard !Task.isCancelled else { return [] }
                    do {
                        let (data, response) = try await urlSession.data(from: searchURL)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
                        let metas = decoded.metas ?? []
                        for meta in metas {
                            guard let id = meta.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                            let title = (meta.name ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { continue }
                            let queryKey = normalizedMatchText(trimmed)
                            let titleKey = normalizedMatchText(title)
                            let descKey = normalizedMatchText(meta.description ?? "")
                            let catalogKey = normalizedMatchText("\(catalog.name ?? "") \(catalog.id ?? "") \(addonName)")
                            guard titleKey.contains(queryKey) || descKey.contains(queryKey) || catalogKey.contains(queryKey) else { continue }
                            let uniqueKey = "\(addonName.lowercased())|\(catalog.name ?? catalog.id ?? "catalog")|\(id)"
                            guard !seen.contains(uniqueKey) else { continue }
                            seen.insert(uniqueKey)
                            results.append(MediaItem(
                                id: id,
                                tmdbId: meta.tmdbId,
                                imdbId: meta.imdbId,
                                tvdbId: meta.tvdbId,
                                title: title,
                                year: Self.firstYear(from: meta.releaseInfo),
                                type: meta.type ?? type,
                                catalog: catalog.name ?? catalog.id ?? addonName,
                                description: meta.description ?? "No description available yet.",
                                genres: Array((meta.genres ?? [type.capitalized]).prefix(3)),
                                rating: meta.imdbRating ?? "—",
                                posterURL: Self.highest(meta.poster),
                                landscapeURL: Self.highest(meta.background ?? meta.poster),
                                logoURL: Self.highest(meta.logo),
                                previewURL: Self.previewURL(from: meta),
                                addonName: addonName,
                                addonIconURL: addonIconURL,
                                seasonNumber: nil,
                                episodeNumber: nil,
                                cast: Array((meta.cast ?? []).prefix(8)),
                                directors: Array((meta.directors ?? []).prefix(3))
                            ))
                        }
                        if !metas.isEmpty { break }
                    } catch {
                        continue
                    }
                }
            }
        }

        return Array(results.prefix(120))
    }

    private func addonCatalogSearchMatch(for item: MediaItem, fallbackQuery: String) async -> MediaItem? {
        let query = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackQuery : item.title
        let matches = await searchConfiguredCatalogAddons(for: query)
        let targetTitle = normalizedMatchText(item.title)
        let targetYear = item.year.filter { $0.isNumber }
        let targetType = normalizedStremioType(item.type)
        let ranked = matches.sorted { lhs, rhs in
            let lhsExact = normalizedMatchText(lhs.title) == targetTitle
            let rhsExact = normalizedMatchText(rhs.title) == targetTitle
            if lhsExact != rhsExact { return lhsExact && !rhsExact }
            let lhsType = normalizedStremioType(lhs.type) == targetType
            let rhsType = normalizedStremioType(rhs.type) == targetType
            if lhsType != rhsType { return lhsType && !rhsType }
            let lhsYear = lhs.year.filter { $0.isNumber } == targetYear
            let rhsYear = rhs.year.filter { $0.isNumber } == targetYear
            if !targetYear.isEmpty && lhsYear != rhsYear { return lhsYear && !rhsYear }
            return lhs.title < rhs.title
        }
        return ranked.first { candidate in
            let candidateTitle = normalizedMatchText(candidate.title)
            let titleOK = targetTitle.isEmpty || candidateTitle == targetTitle || candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle)
            let typeOK = normalizedStremioType(candidate.type) == targetType
            let candidateYear = candidate.year.filter { $0.isNumber }
            let yearOK = targetYear.isEmpty || candidateYear.isEmpty || candidateYear == targetYear
            return titleOK && typeOK && yearOK
        }
    }


    // v393: Universal Search cards can be lightweight TMDB/search objects. Before opening
    // Details from Search, hydrate them back into the same resolver-ready identity used by
    // normal rows so the existing Search Links button can query stream addons successfully.
    func searchHydratedDetailItem(for item: MediaItem, query: String, tmdbApiKey: String, publishStatus: Bool = true) async -> MediaItem {
        if let catalogItem = catalogBackedSearchMatch(for: item) {
            if publishStatus { status = "Opened Search result with full catalog resolver metadata." }
            return mergedSearchArtwork(from: item, into: catalogItem)
        }

        // v1010: while All-in-One is enabled, hydrate through the same one-shot database
        // endpoint used by unified Search. Never fan out across the 83 official rows.
        if allInOneCatalogsEnabled {
            _ = await searchBuiltInCatalogDatabase(for: item.title.isEmpty ? query : item.title)
            if let catalogItem = catalogBackedSearchMatch(for: item) {
                if publishStatus { status = "Opened Search result with official catalog resolver metadata." }
                return mergedSearchArtwork(from: item, into: catalogItem)
            }
        } else if let addonItem = await addonCatalogSearchMatch(for: item, fallbackQuery: query) {
            // Personal catalogs remain the active resolver/catalog sources when the
            // All-in-One toggle is off. These are user-saved addons, not the 83 official rows.
            if publishStatus { status = "Opened Search result with personal catalog resolver metadata." }
            return mergedSearchArtwork(from: item, into: addonItem)
        }

        if item.id.lowercased().hasPrefix("tmdb:"),
           let imdbID = await tmdbExternalIMDBID(for: item, apiKey: tmdbApiKey) {
            if publishStatus { status = "Opened TMDB Search result with IMDb resolver id for Search Links." }
            var rebuilt = rebuiltMediaItem(
                from: item,
                id: imdbID,
                catalog: item.catalog,
                addonName: item.addonName
            )
            // vBRDC159: resolving the stronger IMDb identity is not enough for presentation.
            // Search-origin details often gain their clearlogo from TMDB in this same window.
            // Complete that artwork pass before returning so Media Information/Source
            // Intelligence/VOD all inherit the same enriched title object.
            if let tmdb = await tmdbMetadataFallbackForDetail(rebuilt) {
                rebuilt = mergePlaybackMetadata(base: rebuilt, candidate: tmdb)
            }
            cacheArtwork(for: rebuilt, poster: rebuilt.posterURL, backdrop: rebuilt.landscapeURL, logo: rebuilt.logoURL)
            return rebuilt
        }

        if let cinemetaItem = await cinemetaSearchMatch(for: item, fallbackQuery: query) {
            if publishStatus { status = "Opened Search result with Cinemeta resolver metadata." }
            return mergedSearchArtwork(from: item, into: cinemetaItem)
        }

        if publishStatus { status = "Opened Search result; no richer resolver metadata was found, using original search identity." }
        return item
    }

    private func catalogBackedSearchMatch(for item: MediaItem) -> MediaItem? {
        // v1010: include the unfiltered official search index so a result from a row
        // hidden in Phase 4A still hydrates directly without a row-by-row network scan.
        let all = builtInUnifiedSearchIndex + rows.flatMap { $0.items }
        if let exact = all.first(where: { catalogItemsShareCanonicalIdentity($0, item) }) { return exact }

        let targetTitle = normalizedMatchText(item.title)
        let targetYear = item.year.filter { $0.isNumber }
        let targetType = normalizedStremioType(item.type)
        return all.first { candidate in
            guard normalizedMatchText(candidate.title) == targetTitle else { return false }
            if normalizedStremioType(candidate.type) != targetType { return false }
            let candidateYear = candidate.year.filter { $0.isNumber }
            return targetYear.isEmpty || candidateYear.isEmpty || targetYear == candidateYear
        }
    }

    private func tmdbExternalIMDBID(for item: MediaItem, apiKey: String) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let parts = item.id.split(separator: ":").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "tmdb" else { return nil }
        let tmdbKind = parts[1].lowercased() == "tv" || normalizedStremioType(item.type) == "series" ? "tv" : "movie"
        let tmdbID = parts[2]
        guard let url = URL(string: "https://api.themoviedb.org/3/\(tmdbKind)/\(tmdbID)/external_ids?api_key=\(key)") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/393 SearchHydration", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let imdb = (json["imdb_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  imdb.lowercased().hasPrefix("tt") else { return nil }
            return imdb
        } catch {
            return nil
        }
    }

    private func cinemetaSearchMatch(for item: MediaItem, fallbackQuery: String) async -> MediaItem? {
        let cleanQuery = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackQuery : item.title
        guard let encodedSearch = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encodedSearch.isEmpty else { return nil }
        let type = normalizedStremioType(item.type)
        let typeCandidates = type == "series" ? ["series", "movie"] : ["movie", "series"]
        let targetTitle = normalizedMatchText(item.title)
        let targetYear = item.year.filter { $0.isNumber }

        for candidateType in typeCandidates {
            let endpoints = [
                "https://v3-cinemeta.strem.io/catalog/\(candidateType)/top/search=\(encodedSearch).json",
                "https://v3-cinemeta.strem.io/catalog/\(candidateType)/popular/search=\(encodedSearch).json"
            ]
            for endpoint in endpoints {
                guard let url = URL(string: endpoint) else { continue }
                do {
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/393 SearchHydration", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { continue }
                    let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
                    let metas = decoded.metas ?? []
                    let ranked = metas.sorted { lhs, rhs in
                        let lhsExact = normalizedMatchText(lhs.name ?? "") == targetTitle
                        let rhsExact = normalizedMatchText(rhs.name ?? "") == targetTitle
                        if lhsExact != rhsExact { return lhsExact && !rhsExact }
                        let lhsYear = Self.firstYear(from: lhs.releaseInfo).filter { $0.isNumber }
                        let rhsYear = Self.firstYear(from: rhs.releaseInfo).filter { $0.isNumber }
                        if !targetYear.isEmpty && lhsYear != rhsYear { return lhsYear == targetYear }
                        return (lhs.name ?? "") < (rhs.name ?? "")
                    }
                    for meta in ranked {
                        guard let id = meta.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                        let title = meta.name ?? item.title
                        if !targetTitle.isEmpty, normalizedMatchText(title) != targetTitle, !(normalizedMatchText(title).contains(targetTitle) || targetTitle.contains(normalizedMatchText(title))) { continue }
                        return MediaItem(
                            id: id,
                            tmdbId: meta.tmdbId,
                            imdbId: meta.imdbId,
                            tvdbId: meta.tvdbId,
                            title: title,
                            year: Self.firstYear(from: meta.releaseInfo).isEmpty ? item.year : Self.firstYear(from: meta.releaseInfo),
                            type: meta.type ?? candidateType,
                            catalog: "Cinemeta Search",
                            description: meta.description ?? item.description,
                            genres: Array((meta.genres ?? item.genres).prefix(3)),
                            rating: meta.imdbRating ?? item.rating,
                            posterURL: Self.highest(meta.poster) ?? item.posterURL,
                            landscapeURL: Self.highest(meta.background ?? meta.poster) ?? item.landscapeURL,
                            logoURL: Self.highest(meta.logo) ?? item.logoURL,
                            previewURL: Self.previewURL(from: meta) ?? item.previewURL,
                            addonName: "Cinemeta",
                            addonIconURL: nil,
                            seasonNumber: item.seasonNumber,
                            episodeNumber: item.episodeNumber,
                            cast: Array((meta.cast ?? item.cast).prefix(8)),
                            directors: Array((meta.directors ?? item.directors).prefix(3))
                        )
                    }
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private func mergedSearchArtwork(from searchItem: MediaItem, into resolverItem: MediaItem) -> MediaItem {
        rebuiltMediaItem(
            from: resolverItem,
            posterURL: resolverItem.posterURL ?? searchItem.posterURL,
            landscapeURL: resolverItem.landscapeURL ?? searchItem.landscapeURL,
            logoURL: resolverItem.logoURL ?? searchItem.logoURL,
            previewURL: resolverItem.previewURL ?? searchItem.previewURL,
            addonName: resolverItem.addonName ?? searchItem.addonName,
            addonIconURL: resolverItem.addonIconURL ?? searchItem.addonIconURL
        )
    }

    private func rebuiltMediaItem(
        from item: MediaItem,
        id: String? = nil,
        catalog: String? = nil,
        posterURL: String? = nil,
        landscapeURL: String? = nil,
        logoURL: String? = nil,
        previewURL: String? = nil,
        addonName: String? = nil,
        addonIconURL: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id ?? item.id,
            tmdbId: item.tmdbId,
            imdbId: item.imdbId,
            tvdbId: item.tvdbId,
            title: item.title,
            year: item.year,
            type: item.type,
            catalog: catalog ?? item.catalog,
            description: item.description,
            genres: item.genres,
            rating: item.rating,
            posterURL: posterURL ?? item.posterURL,
            landscapeURL: landscapeURL ?? item.landscapeURL,
            logoURL: logoURL ?? item.logoURL,
            previewURL: previewURL ?? item.previewURL,
            addonName: addonName ?? item.addonName,
            addonIconURL: addonIconURL ?? item.addonIconURL,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            cast: item.cast,
            directors: item.directors,
            castMembers: item.castMembers
        )
    }

    private func normalizedMatchText(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedStremioType(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("series") || lower.contains("show") || lower == "tv" || lower.contains("episode") { return "series" }
        return "movie"
    }

    // MARK: - v1034 Phase 6 canonical catalog identity

    private func normalizedCatalogIdentifier(_ raw: String?) -> String? {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return clean.isEmpty ? nil : clean
    }

    private func inferredIMDbID(for item: MediaItem) -> String? {
        if let explicit = normalizedCatalogIdentifier(item.imdbId),
           explicit.hasPrefix("tt"), explicit.dropFirst(2).allSatisfy(\.isNumber) {
            return explicit
        }
        let components = item.id.lowercased().split { !$0.isLetter && !$0.isNumber }
        return components.first(where: { component in
            component.hasPrefix("tt") && component.dropFirst(2).allSatisfy(\.isNumber)
        }).map(String.init)
    }

    private func inferredTMDBID(for item: MediaItem) -> String? {
        if let explicit = normalizedCatalogIdentifier(item.tmdbId) { return explicit }
        let parts = item.id.lowercased().split(separator: ":").map(String.init)
        guard parts.first == "tmdb" else { return nil }
        return parts.reversed().first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    private func inferredTVDBID(for item: MediaItem) -> String? {
        if let explicit = normalizedCatalogIdentifier(item.tvdbId) { return explicit }
        let parts = item.id.lowercased().split(separator: ":").map(String.init)
        guard parts.first == "tvdb" else { return nil }
        return parts.reversed().first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    private func catalogYear(from raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return String(digits.prefix(4))
    }

    private func catalogEpisodeIdentitySuffix(for item: MediaItem) -> String {
        var season = item.seasonNumber
        var episode = item.episodeNumber
        if season == nil || episode == nil {
            let parts = item.id.split(separator: ":").map(String.init)
            if parts.count >= 3,
               let parsedSeason = Int(parts[parts.count - 2]),
               let parsedEpisode = Int(parts[parts.count - 1]) {
                season = season ?? parsedSeason
                episode = episode ?? parsedEpisode
            }
        }
        guard season != nil || episode != nil else { return "" }
        return "|s\(season ?? -1)|e\(episode ?? -1)"
    }

    private func catalogIdentityKeys(for item: MediaItem) -> [String] {
        let normalized = normalizedCatalogIdentityFields(item)
        let type = normalizedStremioType(normalized.type)
        let suffix = catalogEpisodeIdentitySuffix(for: normalized)
        var keys: [String] = []
        func add(_ key: String?) {
            guard let key, !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
        }
        if let imdb = inferredIMDbID(for: normalized) { add("imdb|\(type)|\(imdb)\(suffix)") }
        if let tmdb = inferredTMDBID(for: normalized) { add("tmdb|\(type)|\(tmdb)\(suffix)") }
        if let tvdb = inferredTVDBID(for: normalized) { add("tvdb|\(type)|\(tvdb)\(suffix)") }
        if let exactID = normalizedCatalogIdentifier(normalized.id) { add("id|\(type)|\(exactID)\(suffix)") }
        if let titleYear = unifiedSearchTitleYearKey(normalized) { add(titleYear) }
        return keys
    }

    func canonicalCatalogIdentityKey(for item: MediaItem) -> String {
        catalogIdentityKeys(for: item).first
            ?? "title|\(normalizedStremioType(item.type))|\(normalizedMatchText(item.title))|unknown\(catalogEpisodeIdentitySuffix(for: item))"
    }


    func catalogItemsShareCanonicalIdentity(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let lhsType = normalizedStremioType(lhs.type)
        let rhsType = normalizedStremioType(rhs.type)
        guard lhsType == rhsType,
              catalogEpisodeIdentitySuffix(for: lhs) == catalogEpisodeIdentitySuffix(for: rhs) else { return false }

        // A title/year fallback may bridge providers only when their strong identifiers do
        // not contradict one another. This prevents metadata from a same-title remake or
        // unrelated provider record from attaching to the focused card.
        if let lhsIMDb = inferredIMDbID(for: lhs), let rhsIMDb = inferredIMDbID(for: rhs), lhsIMDb != rhsIMDb { return false }
        if let lhsTMDB = inferredTMDBID(for: lhs), let rhsTMDB = inferredTMDBID(for: rhs), lhsTMDB != rhsTMDB { return false }
        if let lhsTVDB = inferredTVDBID(for: lhs), let rhsTVDB = inferredTVDBID(for: rhs), lhsTVDB != rhsTVDB { return false }

        let lhsKeys = Set(catalogIdentityKeys(for: lhs))
        let rhsKeys = Set(catalogIdentityKeys(for: rhs))
        return !lhsKeys.isDisjoint(with: rhsKeys)
    }

    private func normalizedCatalogIdentityFields(_ original: MediaItem) -> MediaItem {
        var item = original
        if normalizedCatalogIdentifier(item.imdbId) == nil { item.imdbId = inferredIMDbID(for: original) }
        if normalizedCatalogIdentifier(item.tmdbId) == nil { item.tmdbId = inferredTMDBID(for: original) }
        if normalizedCatalogIdentifier(item.tvdbId) == nil { item.tvdbId = inferredTVDBID(for: original) }
        item.posterURL = item.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.landscapeURL = item.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.logoURL = item.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.previewURL = item.previewURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if PremiumArtworkURL.url(item.posterURL) == nil,
           PremiumArtworkURL.url(item.landscapeURL) != nil {
            item.posterURL = item.landscapeURL
        }
        return item
    }

    private func canonicalizedCatalogItems(_ items: [MediaItem]) -> [MediaItem] {
        var output: [MediaItem] = []
        var keyToIndex: [String: Int] = [:]
        for original in items {
            let item = normalizedCatalogIdentityFields(original)
            guard PremiumArtworkURL.url(item.posterURL) != nil else { continue }
            let keys = catalogIdentityKeys(for: item)
            let existingIndex = keys.compactMap { keyToIndex[$0] }.first(where: { index in
                output.indices.contains(index) && catalogItemsShareCanonicalIdentity(output[index], item)
            })
            if let existingIndex {
                output[existingIndex] = mergeUnifiedSearchMetadata(preferred: output[existingIndex], fallback: item)
                for key in catalogIdentityKeys(for: output[existingIndex]) where keyToIndex[key] == nil {
                    keyToIndex[key] = existingIndex
                }
            } else {
                let index = output.count
                output.append(item)
                for key in keys where keyToIndex[key] == nil { keyToIndex[key] = index }
            }
        }
        return output
    }

    private func canonicalizedCatalogRows(_ sourceRows: [MediaRow]) -> [MediaRow] {
        var output: [MediaRow] = []
        var rowIndexByID: [String: Int] = [:]
        for row in sourceRows {
            let rowID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let rowTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rowID.isEmpty, !rowTitle.isEmpty else { continue }
            let items = canonicalizedCatalogItems(row.items)
            guard !items.isEmpty else { continue }
            let normalizedRow = MediaRow(id: rowID, title: rowTitle, items: items, presentation: row.presentation)
            if let index = rowIndexByID[rowID] {
                let mergedItems = canonicalizedCatalogItems(output[index].items + normalizedRow.items)
                output[index] = MediaRow(
                    id: output[index].id,
                    title: output[index].title,
                    items: mergedItems,
                    presentation: output[index].presentation ?? normalizedRow.presentation
                )
            } else {
                rowIndexByID[rowID] = output.count
                output.append(normalizedRow)
            }
        }
        return output
    }


    // vBRDC075: Fanart.tv stays out of catalog startup, but the user-configured key is
    // active again for detail-only artwork. This preserves v711 startup stability while
    // actually using the artwork provider key the Settings UI exposes.
    private func fanartTVApiKey() -> String {
        UserDefaults.standard.string(forKey: "fanartTvApiKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func bestFanartImage(_ groups: [[FanartTVImage]?]) -> String? {
        let images = groups.flatMap { $0 ?? [] }
        let ranked = images.sorted { lhs, rhs in
            let lhsLang = (lhs.lang ?? "").lowercased()
            let rhsLang = (rhs.lang ?? "").lowercased()
            let lhsEnglish = lhsLang == "en" || lhsLang.isEmpty
            let rhsEnglish = rhsLang == "en" || rhsLang.isEmpty
            if lhsEnglish != rhsEnglish { return lhsEnglish && !rhsEnglish }
            return lhs.likeScore > rhs.likeScore
        }
        return Self.highest(ranked.compactMap { $0.url?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }))
    }

    private func fetchFanartArtwork(kind: String, tmdbID: Int, tvdbID: Int? = nil, tmdbApiKey: String) async -> PremiumFanartArtwork? {
        let fanartKey = fanartTVApiKey()
        guard !fanartKey.isEmpty else {
            print("[Fanart][vBRDC075] skipped: Fanart.tv API key missing")
            return nil
        }
        let normalizedKind = kind.lowercased() == "tv" || kind.lowercased() == "series" ? "tv" : "movie"
        var fanartID = String(tmdbID)

        if normalizedKind == "tv" {
            if let tvdbID, tvdbID > 0 {
                fanartID = String(tvdbID)
            } else {
                let key = tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard tmdbID > 0, !key.isEmpty,
                      let externalURL = URL(string: "https://api.themoviedb.org/3/tv/\(tmdbID)/external_ids?api_key=\(key)") else {
                    return nil
                }
                do {
                    var request = URLRequest(url: externalURL, timeoutInterval: 7)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/vBRDC075 FanartExternalIDs", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
                    let external = try JSONDecoder().decode(TMDBExternalIDsResponse.self, from: data)
                    guard let tvdbID = external.tvdb_id, tvdbID > 0 else { return nil }
                    fanartID = String(tvdbID)
                } catch is CancellationError {
                    return nil
                } catch {
                    return nil
                }
            }
        }

        let endpoint = normalizedKind == "tv" ? "tv" : "movies"
        guard let encodedKey = fanartKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://webservice.fanart.tv/v3/\(endpoint)/\(fanartID)?api_key=\(encodedKey)") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 9)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/vBRDC075 DetailFanart", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard data.count <= 4_000_000,
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            if normalizedKind == "tv" {
                let decoded = try JSONDecoder().decode(FanartTVResponse.self, from: data)
                let artwork = PremiumFanartArtwork(
                    backdropURL: bestFanartImage([decoded.showbackground]),
                    logoURL: bestFanartImage([decoded.hdtvlogo, decoded.clearlogo]),
                    posterURL: bestFanartImage([decoded.tvposter])
                )
                return artwork.hasAny ? artwork : nil
            } else {
                let decoded = try JSONDecoder().decode(FanartMovieResponse.self, from: data)
                let artwork = PremiumFanartArtwork(
                    backdropURL: bestFanartImage([decoded.moviebackground]),
                    logoURL: bestFanartImage([decoded.hdmovielogo, decoded.movielogo]),
                    posterURL: bestFanartImage([decoded.movieposter])
                )
                return artwork.hasAny ? artwork : nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            print("[Fanart][vBRDC075] detail lookup failed \(endpoint)/\(fanartID): \(error.localizedDescription)")
            return nil
        }
    }

    private func applyPremiumFanartArtwork(to item: MediaItem, kind: String, tmdbID: Int, tvdbID: Int? = nil, tmdbApiKey: String) async -> MediaItem {
        item
    }

    // v712: Streaming Catalog artwork uses the stable v702 path again: TMDB
    // originals when TMDB owns the row, with Stremio/Cinemeta art left intact as
    // the catalog fallback. Fanart must not participate in catalog startup.
    private func applyTMDBPrimaryArtworkIfResolvable(to item: MediaItem, tmdbApiKey: String) async -> MediaItem {
        let key = tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = cachedArtwork(for: item)
        if cached.poster != nil || cached.backdrop != nil || cached.logo != nil {
            return rebuiltMediaItem(
                from: item,
                posterURL: cached.poster ?? item.posterURL,
                landscapeURL: cached.backdrop ?? item.landscapeURL,
                logoURL: cached.logo ?? item.logoURL
            )
        }
        guard !key.isEmpty else {
            print("[TMDBPrimary] skipped \(item.title): TMDB key missing")
            return item
        }
        let tmdbStart = Date()
        print("[TMDBPrimary] enrichment start item=\(item.title) id=\(item.id)")
        guard let target = await tmdbTargetForCredits(item, apiKey: key), let id = Int(target.id) else {
            print("[TMDBPrimary] enrichment fail item=\(item.title) elapsedMs=\(Self.elapsedMS(since: tmdbStart))")
            return item
        }
        guard let url = URL(string: "https://api.themoviedb.org/3/\(target.kind)/\(id)?api_key=\(key)&language=en-US") else { return item }
        do {
            var request = URLRequest(url: url, timeoutInterval: 7)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/711 TMDBPrimaryArtwork", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return item }
            let decoded = try JSONDecoder().decode(TMDBListItem.self, from: data)
            var copy = item
            if let poster = decoded.poster_path, !poster.isEmpty { copy.posterURL = "https://image.tmdb.org/t/p/original\(poster)" }
            if let backdrop = decoded.backdrop_path, !backdrop.isEmpty { copy.landscapeURL = "https://image.tmdb.org/t/p/original\(backdrop)" }
            if copy.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                copy.logoURL = await tmdbLogoURL(id: id, mediaType: target.kind, apiKey: key)
            }
            if (copy.rating.isEmpty || copy.rating == "—"), let vote = decoded.vote_average, vote > 0 { copy.rating = String(format: "%.1f", vote) }
            let overview = decoded.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !overview.isEmpty && (copy.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || copy.description.localizedCaseInsensitiveContains("No description")) {
                copy.description = overview
            }
            cacheArtwork(for: copy, poster: copy.posterURL, backdrop: copy.landscapeURL, logo: copy.logoURL)
            print("[TMDBPrimary] enrichment end item=\(item.title) source=\(target.source) changed=\(copy.posterURL != item.posterURL || copy.landscapeURL != item.landscapeURL) elapsedMs=\(Self.elapsedMS(since: tmdbStart))")
            return copy
        } catch {
            print("[TMDBPrimary] enrichment fail item=\(item.title) error=\(error.localizedDescription) elapsedMs=\(Self.elapsedMS(since: tmdbStart))")
            return item
        }
    }

    private func applyPremiumFanartArtworkIfResolvable(to item: MediaItem, tmdbApiKey: String) async -> MediaItem {
        item
    }

    func tmdbSearchResults(for query: String, apiKey: String) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !key.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.themoviedb.org/3/search/multi?api_key=\(key)&query=\(encoded)&include_adult=false&page=1") else { return [] }
        do {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/349 UniversalSearch", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return [] }
            let decoded = try JSONDecoder().decode(TMDBMultiSearchResponse.self, from: data)
            var output: [MediaItem] = []
            for result in decoded.results.prefix(30) {
                let mediaType = (result.media_type ?? "").lowercased()
                guard mediaType == "movie" || mediaType == "tv" else { continue }
                let title = (result.title ?? result.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let date = result.release_date ?? result.first_air_date ?? ""
                let year = String(date.prefix(4)).isEmpty ? "TMDB" : String(date.prefix(4))
                guard let posterPath = result.poster_path?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !posterPath.isEmpty else { continue }
                let poster = "https://image.tmdb.org/t/p/original\(posterPath)"
                let backdrop = result.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" }
                let rating = result.vote_average.map { String(format: "%.1f", $0) } ?? ""
                let type = mediaType == "movie" ? "movie" : "series"
                let stremioID = mediaType == "movie" ? "tmdb:movie:\(result.id)" : "tmdb:tv:\(result.id)"
                let item = MediaItem(
                    id: stremioID,
                    tmdbId: String(result.id),
                    title: title,
                    year: year,
                    type: type,
                    catalog: "Search",
                    description: result.overview ?? "",
                    genres: [mediaType == "movie" ? "Movie" : "Show"],
                    rating: rating,
                    posterURL: poster,
                    landscapeURL: backdrop ?? poster,
                    logoURL: nil,
                    previewURL: nil,
                    addonName: nil,
                    addonIconURL: nil
                )
                output.append(item)
            }
            return output
        } catch {
            return []
        }
    }

    func tmdbDefaultCatalogRows(apiKey: String) async -> [MediaRow] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        struct TMDBShelf {
            let id: String
            let title: String
            let path: String
            let type: String
        }

        let shelves: [TMDBShelf] = [
            TMDBShelf(id: "tmdb-trending-movies", title: "TMDB - Trending Movies", path: "/trending/movie/week", type: "movie"),
            TMDBShelf(id: "tmdb-popular-movies", title: "TMDB - Popular Movies", path: "/movie/popular", type: "movie"),
            TMDBShelf(id: "tmdb-top-rated-movies", title: "TMDB - Top Rated Movies", path: "/movie/top_rated", type: "movie"),
            TMDBShelf(id: "tmdb-now-playing", title: "TMDB - Now Playing", path: "/movie/now_playing", type: "movie"),
            TMDBShelf(id: "tmdb-upcoming", title: "TMDB - Upcoming Movies", path: "/movie/upcoming", type: "movie"),
            TMDBShelf(id: "tmdb-trending-shows", title: "TMDB - Trending Shows", path: "/trending/tv/week", type: "series"),
            TMDBShelf(id: "tmdb-popular-shows", title: "TMDB - Popular Shows", path: "/tv/popular", type: "series"),
            TMDBShelf(id: "tmdb-top-rated-shows", title: "TMDB - Top Rated Shows", path: "/tv/top_rated", type: "series")
        ]

        var output: [MediaRow] = []
        for shelf in shelves {
            guard let url = URL(string: "https://api.themoviedb.org/3\(shelf.path)?api_key=\(key)&language=en-US&page=1") else { continue }
            do {
                var request = URLRequest(url: url, timeoutInterval: 12)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/374 UniversalCatalogs", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { continue }
                let decoded = try JSONDecoder().decode(TMDBListResponse.self, from: data)
                var items: [MediaItem] = []
                for result in decoded.results.prefix(24) {
                    let title = (result.title ?? result.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    let date = result.release_date ?? result.first_air_date ?? ""
                    let year = String(date.prefix(4)).isEmpty ? "TMDB" : String(date.prefix(4))
                    let poster = result.poster_path.map { "https://image.tmdb.org/t/p/original\($0)" }
                    let backdrop = result.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" }
                    let rating = result.vote_average.map { String(format: "%.1f", $0) } ?? ""
                    let stremioID = shelf.type == "movie" ? "tmdb:movie:\(result.id)" : "tmdb:tv:\(result.id)"
                    let logo = await tmdbLogoURL(id: result.id, mediaType: shelf.type == "movie" ? "movie" : "tv", apiKey: key)
                    let item = MediaItem(
                        id: stremioID,
                        title: title,
                        year: year,
                        type: shelf.type,
                        catalog: shelf.title,
                        description: result.overview ?? "",
                        genres: [shelf.type == "movie" ? "Movie" : "Show", "TMDB"],
                        rating: rating,
                        posterURL: poster,
                        landscapeURL: backdrop,
                        logoURL: logo,
                        previewURL: nil,
                        addonName: "TMDB",
                        addonIconURL: nil
                    )
                    items.append(item)
                }
                if !items.isEmpty { output.append(MediaRow(id: shelf.id, title: shelf.title, items: items)) }
            } catch {
                continue
            }
        }
        return output
    }

    func resetDemo() {
        UserDefaults.standard.removeObject(forKey: catalogRowsCacheKey)
        if allInOneCatalogsEnabled {
            // Production no longer exposes demo rows. Keep the protected official
            // snapshot visible even if this legacy maintenance action is invoked.
            let durableRows = bestAvailableOfficialCatalogRows()
            if !durableRows.isEmpty { _ = updateVisibleCatalogRows(durableRows) }
            status = "Compact catalog cache cleared. Protected built-in rows remain available."
            VODExclusiveWorkRegistry.start { await self.loadAllManifests() }
        } else {
            UserDefaults.standard.removeObject(forKey: externalCatalogRowsCacheKey)
            let accountRows = rows.filter { isTraktCatalogRow($0) || isPlaybackDerivedCatalogRow($0) }
            rows = prioritizedRowsForDisplay(accountRows)
            status = "Personal catalog cache cleared. Account/resume rows remain available; reload external catalogs to repopulate browsing rows."
        }
    }

    func directPreviewURL(for item: MediaItem) -> URL? {
        TrailerServiceManager.shared.directPreviewURL(for: item)
    }



    func cachedPlayableTrailerURL(for item: MediaItem) -> URL? {
        if let direct = directPreviewURL(for: item) { return direct }
        let cacheKey = trailerCacheKey(for: item)
        if let cached = trailerResolveMemoryCache[cacheKey], let cachedURL = playableTrailerURL(from: cached) {
            return cachedURL
        }
        return nil
    }

    // v1011 Phase 4C: resolve a lightweight, direct media URL exclusively for the
    // muted focused-card background player. This lane is cancellation-aware, requests
    // no 4K media, does not publish trailer status, and does not share the normal
    // trailer popup's player or persisted resolver cache.
    func resolveFocusedCardPreviewURL(for item: MediaItem) async -> URL? {
        guard !vodExclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return nil }

        // vBRDC293: focused catalog previews stay on the lightweight/original preview lane.
        // They never invoke the Nuvio/Innertube HD trailer resolver used by the Trailer button.
        // If metadata already exposes direct preview media, use it immediately with no resolver.
        if let direct = directPreviewURL(for: item) { return direct }

        let cacheKey = TrailerServiceManager.shared.cacheKey(for: item) + "|focused-preview-720p"
        if let cachedFile = await FocusedCardPreviewDiskCache.shared.cachedFileURL(forKey: cacheKey) {
            rememberFocusedCardPreviewURL(cachedFile, forKey: cacheKey)
            return cachedFile
        }
        if let cached = focusedCardPreviewMemoryCache[cacheKey] {
            return cached
        }

        let configuredBase = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = configuredBase.isEmpty ? "https://api.skylinejay187.it.com" : configuredBase
        guard var components = URLComponents(string: "\(base)/trailers/resolve") else { return nil }

        let rawType = item.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaType = rawType.isEmpty ? "movie" : rawType
        let identity = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [
            URLQueryItem(name: "title", value: item.title),
            URLQueryItem(name: "year", value: item.year),
            URLQueryItem(name: "type", value: mediaType),
            URLQueryItem(name: "id", value: identity),
            URLQueryItem(name: "mediaId", value: identity),
            URLQueryItem(name: "prefer4k", value: "false"),
            URLQueryItem(name: "minHeight", value: "360"),
            URLQueryItem(name: "maxHeight", value: "720"),
            URLQueryItem(name: "allow4k", value: "false"),
            URLQueryItem(name: "fast", value: "true"),
            URLQueryItem(name: "reuseCache", value: "true"),
            URLQueryItem(name: "singleFlight", value: "true"),
            URLQueryItem(name: "stremioTrailers", value: "false"),
            URLQueryItem(name: "streailer", value: "false"),
            URLQueryItem(name: "debridioTrailerStreams", value: "false")
        ]

        for attempt in 0..<3 {
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return nil }

            var attemptComponents = components
            if attempt > 0 {
                var items = attemptComponents.queryItems ?? []
                items.append(URLQueryItem(name: "cacheOnly", value: "true"))
                attemptComponents.queryItems = items
            } else {
                var items = attemptComponents.queryItems ?? []
                items.append(URLQueryItem(name: "cacheOnly", value: "false"))
                attemptComponents.queryItems = items
            }
            guard let endpoint = attemptComponents.url else { return nil }

            do {
                var request = URLRequest(url: endpoint, timeoutInterval: attempt == 0 ? 15 : 7)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/1011 FocusedCardPreview720p", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(statusCode), data.count < 1024 * 1024 else { continue }

                var resolved: URL? = nil
                if let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   plain.lowercased().hasPrefix("http") {
                    resolved = playableTrailerURL(from: plain)
                }
                if resolved == nil, let json = try? JSONSerialization.jsonObject(with: data) {
                    resolved = playableTrailerURL(fromJSON: json)
                }

                if let resolved {
                    rememberFocusedCardPreviewURL(resolved, forKey: cacheKey)
                    scheduleFocusedCardPreviewDiskStage(cacheKey: cacheKey, remoteURL: resolved)
                    return resolved
                }
            } catch is CancellationError {
                return nil
            } catch {
                // A focused-card preview is optional. Fail silently and leave the static backdrop.
            }

            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        return nil
    }

    func cancelFocusedCardPreviewDiskStage() {
        focusedCardPreviewDiskStageGeneration &+= 1
        focusedCardPreviewDiskStageTask?.cancel()
        focusedCardPreviewDiskStageTask = nil
    }

    private func scheduleFocusedCardPreviewDiskStage(cacheKey: String, remoteURL: URL) {
        cancelFocusedCardPreviewDiskStage()
        let generation = focusedCardPreviewDiskStageGeneration

        focusedCardPreviewDiskStageTask = Task { [weak self] in
            // Let the one-shot 40-second preview finish before any disk staging begins.
            // This prevents the first preview from streaming and downloading twice at once.
            try? await Task.sleep(nanoseconds: 42_000_000_000)

            if !Task.isCancelled,
               let self,
               !self.vodExclusivePlaybackActive,
               !VODExclusivePlaybackGate.isActive,
               let cachedFile = await FocusedCardPreviewDiskCache.shared.stageProgressivePreview(from: remoteURL, forKey: cacheKey) {
                await MainActor.run {
                    guard self.focusedCardPreviewDiskStageGeneration == generation else { return }
                    self.rememberFocusedCardPreviewURL(cachedFile, forKey: cacheKey)
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.focusedCardPreviewDiskStageGeneration == generation else { return }
                self.focusedCardPreviewDiskStageTask = nil
            }
        }
    }

    func beginTrailerPrewarm(for item: MediaItem) {
        guard !vodExclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return }
        if cachedPlayableTrailerURL(for: item) != nil { return }
        let cacheKey = trailerCacheKey(for: item)
        if trailerResolveInflightTasks[cacheKey] != nil { return }
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.resolvePlayableTrailerURLNetworkOnly(for: item, cacheKey: cacheKey)
        }
        trailerResolveInflightTasks[cacheKey] = task
        Task { [weak self] in
            _ = await task.value
            await MainActor.run { self?.trailerResolveInflightTasks[cacheKey] = nil }
        }
    }

    // v1093 Phase 1: exact v1073 eager trailer resolver lane restored as a
    // trailer-only donor. The active app remains based on v1092; this block keeps
    // v1073's direct/stabilized handoff behavior and intentionally does not wait for
    // the later durable full-file/audio-EOF staging path. Mid-trailer audio cutoff
    // remains an accepted temporary limitation for a later isolated repair.
    func resolvePlayableTrailerURL(for item: MediaItem) async -> URL? {
        guard !vodExclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return nil }
        resolvedTrailerAudioURL = nil
        resolvedTrailerHTTPHeaders = [:]
        let cacheKey = trailerCacheKey(for: item)

        // vBRDC275: Nuvio-style app-native trailer lane. Try direct Trailerio/Innertube
        // resolution before any server-side proxy/backend so every Signal install gets the
        // same fast HD trailer behavior without Docker, cookies, or per-user setup.
        if let native = await SignalYouTubeTrailerResolver.shared.resolve(for: item) {
            resolvedTrailerAudioURL = native.audioURL
            resolvedTrailerHTTPHeaders = native.requestHeaders
            lastStreamMessage = native.qualityLabel.isEmpty ? "Trailer ready." : "Trailer ready • \(native.qualityLabel)"
            rememberTrailerURL(native.videoURL, cacheKey: cacheKey)
            return native.videoURL
        }

        // vBRDC276: the retired per-user Docker/YouTube proxy lane is gone.
        // If native Trailerio/Innertube resolution cannot produce a stream, continue
        // through Signal's existing direct/cached/backend trailer fallback automatically.

        if let direct = directPreviewURL(for: item),
           let complete = await completeTrailerPlaybackURL(direct) {
            lastStreamMessage = "Trailer ready."
            return complete
        }

        if let cached = trailerResolveMemoryCache[cacheKey],
           let cachedURL = playableTrailerURL(from: cached),
           let complete = await completeTrailerPlaybackURL(cachedURL) {
            lastStreamMessage = "Trailer ready."
            return complete
        } else if trailerResolveMemoryCache[cacheKey] != nil {
            trailerResolveMemoryCache.removeValue(forKey: cacheKey)
            trailerResolveMemoryOrder.removeAll { $0 == cacheKey }
            UserDefaults.standard.set(trailerResolveMemoryCache, forKey: trailerResolveCacheKey)
        }

        // v566 rebuild: Stremio-addon trailer scanning is disabled for now.
        // Trailer button must never trigger normal movie/show source scanning.
        // Keep the legacy trailer resolver path only until addon trailer handling is rebuilt safely.

        // v395 trailer-only fix: single-flight duplicate trailer resolving.
        // The v394 log showed the same title spawning repeated backend yt-dlp
        // searches/extracts, often both 2160p and 1080p. Keep one in-flight
        // resolver task per media key; duplicate button presses/detail refreshes
        // await the same task instead of starting more backend jobs.
        if let existingTask = trailerResolveInflightTasks[cacheKey] {
            lastStreamMessage = "Trailer already resolving…"
            return await existingTask.value
        }

        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.resolvePlayableTrailerURLNetworkOnly(for: item, cacheKey: cacheKey)
        }
        trailerResolveInflightTasks[cacheKey] = task
        let result = await task.value
        trailerResolveInflightTasks[cacheKey] = nil
        return result
    }


    private func bestPlayableAddonTrailerURL(for item: MediaItem) async -> URL? {
        let priorLinks = streamLinks
        let priorMessage = lastStreamMessage
        let links = await findStreams(for: item)
        let trailers = links
            .filter { isLikelyTrailerStream($0, for: item) && $0.isDirectPlayable }
            .sorted { lhs, rhs in
                trailerRank(lhs) < trailerRank(rhs)
            }
        if !trailers.isEmpty {
            // Restore the normal movie source list if the user was only pressing Trailer.
            streamLinks = priorLinks
            lastStreamMessage = priorMessage.isEmpty ? "Using Stremio addon trailer source." : priorMessage
        }
        guard let best = trailers.first else { return nil }
        return Self.makePlayableURL(from: best.url)
    }

    private func isLikelyTrailerStream(_ link: StreamLink, for item: MediaItem) -> Bool {
        let title = link.title.lowercased()
        let source = link.source.lowercased()
        let haystack = "\(title) \(link.quality.lowercased()) \(link.size.lowercased()) \(source)"
        let markerHit = ["trailer", "teaser", "preview", "official-trailer", "official trailer", "trailer-1", "trailer-2", "[trailer"].contains { haystack.contains($0) }
        guard markerHit else { return false }
        let mediaTitle = item.title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = title.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        let titleMatch = mediaTitle.isEmpty || cleaned.contains(mediaTitle) || mediaTitle.split(separator: " ").prefix(2).allSatisfy { cleaned.contains($0) }
        return titleMatch || source.contains("streailer") || source.contains("debridio")
    }

    private func trailerRank(_ link: StreamLink) -> Int {
        let h = "\(link.title) \(link.quality)".lowercased()
        if h.contains("1080") { return 0 }
        if h.contains("720") { return 1 }
        if h.contains("4k") || h.contains("2160") { return 2 }
        return 3
    }


    private func resolvePlayableTrailerURLNetworkOnly(for item: MediaItem, cacheKey: String) async -> URL? {
        let configuredBase = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = configuredBase.isEmpty ? "http://192.168.100.55:8181" : configuredBase
        guard let title = item.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let year = item.year.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let type = (item.type.isEmpty ? "movie" : item.type).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "movie"
        lastStreamMessage = "Resolving trailer through backend…"

        // v772: restore the proven v400 trailer lane exactly: one backend endpoint,
        // cache-first, single-flight, 720-1080p, no app-side YouTube/Stremio fanout.
        // The app must receive a direct playable/remux URL and then play it with KSPlayer.
        let fastQuery = "title=\(title)&year=\(year)&type=\(type)&prefer4k=false&minHeight=720&maxHeight=1080&allow4k=false&fast=true&reuseCache=true&singleFlight=true&cacheOnly=false&requireMuxedAudio=true&requireComplete=true&cacheVersion=677-fast-hd-remux&fastNoCookieHD=true&preferProgressiveHD=true"
        let candidates = ["\(base)/trailers/resolve?\(fastQuery)"]

        for urlString in candidates {
            guard let endpoint = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 45)
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/vBRDC008 V677FastHDRemuxTrailerResolver", forHTTPHeaderField: "User-Agent")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(statusCode), data.count < 1024 * 1024 else {
                    lastStreamMessage = "Preparing trailer…"
                    continue
                }

                if let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   plain.lowercased().hasPrefix("http"),
                   let url = playableTrailerURL(from: plain),
                   let stableURL = await completeTrailerPlaybackURL(url) {
                    rememberTrailerURL(stableURL, cacheKey: cacheKey)
                    lastStreamMessage = "Trailer ready."
                    return stableURL
                }

                if let json = try? JSONSerialization.jsonObject(with: data) {
                    if let url = remuxedTrailerPlaybackURL(fromJSON: json),
                       let stableURL = await completeTrailerPlaybackURL(url) {
                        resolvedTrailerAudioURL = nil
                        rememberTrailerURL(stableURL, cacheKey: cacheKey)
                        lastStreamMessage = "Trailer ready."
                        return stableURL
                    }
                    if let body = String(data: data, encoding: .utf8),
                       let url = remuxedTrailerPlaybackURL(fromRawBody: body),
                       let stableURL = await completeTrailerPlaybackURL(url) {
                        resolvedTrailerAudioURL = nil
                        rememberTrailerURL(stableURL, cacheKey: cacheKey)
                        lastStreamMessage = "Trailer ready."
                        return stableURL
                    }
                    // v1064: older/proven backend resolvers may return an already-muxed
                    // direct URL under `url`, `streamUrl`, or `trailerUrl` without the newer
                    // duration-verification fields. Accept that direct media when the response
                    // does not declare a split/remux-pending result. External YouTube watch
                    // pages remain rejected by TrailerServiceManager.
                    if !trailerResponseRequiresRemux(json),
                       let url = playableTrailerURL(fromJSON: json),
                       let stableURL = await completeTrailerPlaybackURL(url) {
                        resolvedTrailerAudioURL = nil
                        rememberTrailerURL(stableURL, cacheKey: cacheKey)
                        lastStreamMessage = "Trailer ready."
                        return stableURL
                    }
                    if let url = await pollPreparedTrailerURL(endpoint: endpoint, cacheKey: cacheKey) {
                        return url
                    }
                    lastStreamMessage = "Trailer is taking longer than usual. Keep this open a moment."
                    return nil
                }
            } catch {
                lastStreamMessage = "Preparing trailer…"
                continue
            }
        }
        lastStreamMessage = "Trailer is taking longer than usual. Keep this open a moment."
        return nil
    }

    private func pollPreparedTrailerURL(endpoint: URL, cacheKey: String) async -> URL? {
        for attempt in 1...40 {
            lastStreamMessage = "Preparing trailer…"
            try? await Task.sleep(nanoseconds: attempt <= 8 ? 1_000_000_000 : 1_500_000_000)
            do {
                var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
                var items = components?.queryItems ?? []
                func upsert(_ name: String, _ value: String) {
                    if let idx = items.firstIndex(where: { $0.name == name }) {
                        items[idx].value = value
                    } else {
                        items.append(URLQueryItem(name: name, value: value))
                    }
                }
                upsert("reuseCache", "true")
                upsert("singleFlight", "true")
                upsert("prefer4k", "false")
                upsert("maxHeight", "1080")
                upsert("fast", "true")
                upsert("requireMuxedAudio", "true")
                upsert("requireComplete", "true")
                upsert("cacheVersion", "677-fast-hd-remux")
                upsert("fastNoCookieHD", "true")
                upsert("preferProgressiveHD", "true")
                upsert("cacheOnly", "true")
                components?.queryItems = items
                guard let pollURL = components?.url else { continue }
                var request = URLRequest(url: pollURL, timeoutInterval: 8)
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/vBRDC008 V677FastHDRemuxTrailerResolverPoll", forHTTPHeaderField: "User-Agent")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(statusCode), data.count < 1024 * 1024 else { continue }

                if let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   plain.lowercased().hasPrefix("http"),
                   let url = playableTrailerURL(from: plain),
                   let stableURL = await completeTrailerPlaybackURL(url) {
                    rememberTrailerURL(stableURL, cacheKey: cacheKey)
                    lastStreamMessage = "Trailer ready."
                    return stableURL
                }
                if let json = try? JSONSerialization.jsonObject(with: data) {
                    if let url = remuxedTrailerPlaybackURL(fromJSON: json),
                       let stableURL = await completeTrailerPlaybackURL(url) {
                        resolvedTrailerAudioURL = nil
                        rememberTrailerURL(stableURL, cacheKey: cacheKey)
                        lastStreamMessage = "Trailer ready."
                        return stableURL
                    }
                    if !trailerResponseRequiresRemux(json),
                       let url = playableTrailerURL(fromJSON: json),
                       let stableURL = await completeTrailerPlaybackURL(url) {
                        resolvedTrailerAudioURL = nil
                        rememberTrailerURL(stableURL, cacheKey: cacheKey)
                        lastStreamMessage = "Trailer ready."
                        return stableURL
                    }
                }
                if let body = String(data: data, encoding: .utf8),
                   let url = remuxedTrailerPlaybackURL(fromRawBody: body),
                   let stableURL = await completeTrailerPlaybackURL(url) {
                    resolvedTrailerAudioURL = nil
                    rememberTrailerURL(stableURL, cacheKey: cacheKey)
                    lastStreamMessage = "Trailer ready."
                    return stableURL
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func trailerCacheKey(for item: MediaItem) -> String {
        TrailerServiceManager.shared.cacheKey(for: item)
    }

    private static func extractedTrailerIMDbId(from raw: String) -> String {
        TrailerServiceManager.shared.extractedIMDbId(from: raw)
    }

    private static func extractedTrailerTMDBId(from raw: String) -> String {
        TrailerServiceManager.shared.extractedTMDBId(from: raw)
    }

    private func rememberTrailerURL(_ url: URL, cacheKey: String) {
        let raw = url.absoluteString
        guard !raw.isEmpty else { return }
        trailerResolveMemoryCache[cacheKey] = raw
        trailerResolveMemoryOrder.removeAll { $0 == cacheKey }
        trailerResolveMemoryOrder.append(cacheKey)
        while trailerResolveMemoryOrder.count > trailerResolveMemoryLimit {
            trailerResolveMemoryCache.removeValue(forKey: trailerResolveMemoryOrder.removeFirst())
        }
        UserDefaults.standard.set(trailerResolveMemoryCache, forKey: trailerResolveCacheKey)
    }

    private func completeTrailerPlaybackURL(_ url: URL) async -> URL? {
        // v1162: keep the proven v1084 direct/progressive admission path so signed muxed
        // trailer URLs are not rejected by AVFoundation preflight. Backend remux-cache
        // outputs are different: the app must never hand KSPlayer a still-growing MP4.
        // Those files are allowed to settle, downloaded completely into the app cache,
        // verified to contain both video and audio through the same endpoint, and only
        // then published as an immutable local file:// URL. This is trailer-only and does
        // not touch movie/episode/Live TV playback.
        guard let stabilized = await stabilizedTrailerPlaybackURL(url) else { return nil }
        if stabilized.isFileURL {
            return await trailerFileHasCompleteAudio(stabilized) ? stabilized : nil
        }
        let lower = stabilized.absoluteString.lowercased()
        guard lower.contains("remux-cache") else { return stabilized }
        return await materializeFinalizedTrailerFile(from: stabilized)
    }

    private func finalizedTrailerCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(finalizedTrailerCacheDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private func finalizedTrailerFileURL(for remoteURL: URL, directory: URL) -> URL {
        let rawName = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = rawName
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let fileName: String
        if safeName.isEmpty {
            fileName = "trailer-\(abs(remoteURL.absoluteString.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) })).mp4"
        } else if safeName.lowercased().hasSuffix(".mp4") {
            fileName = safeName
        } else {
            fileName = safeName + ".mp4"
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func materializeFinalizedTrailerFile(from remoteURL: URL) async -> URL? {
        guard let directory = finalizedTrailerCacheDirectory() else { return nil }
        let finalURL = finalizedTrailerFileURL(for: remoteURL, directory: directory)

        if FileManager.default.fileExists(atPath: finalURL.path),
           await trailerFileHasCompleteAudio(finalURL) {
            touchFinalizedTrailerFile(finalURL)
            trimFinalizedTrailerCache(in: directory, keeping: finalURL)
            return finalURL
        }

        try? FileManager.default.removeItem(at: finalURL)
        let partURL = directory.appendingPathComponent(finalURL.deletingPathExtension().lastPathComponent + ".part.mp4")
        try? FileManager.default.removeItem(at: partURL)

        var request = URLRequest(url: remoteURL, timeoutInterval: 90)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DebridChannels-tvOS/1162 TrailerFinalizer", forHTTPHeaderField: "User-Agent")
        request.setValue("video/mp4,video/*,*/*", forHTTPHeaderField: "Accept")

        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize >= 256 * 1024 else { return nil }

            try FileManager.default.moveItem(at: temporaryURL, to: partURL)
            guard await trailerFileHasCompleteAudio(partURL) else {
                try? FileManager.default.removeItem(at: partURL)
                return nil
            }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
            touchFinalizedTrailerFile(finalURL)
            trimFinalizedTrailerCache(in: directory, keeping: finalURL)
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            return nil
        }
    }

    private func trailerFileHasCompleteAudio(_ fileURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: fileURL)
            guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
                  let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                  !videoTracks.isEmpty, !audioTracks.isEmpty,
                  let duration = try? await asset.load(.duration) else { return false }

            let assetDuration = CMTimeGetSeconds(duration)
            let videoRanges = await withTaskGroup(of: Double?.self) { group in
                for track in videoTracks {
                    group.addTask {
                        guard let range = try? await track.load(.timeRange) else { return nil }
                        return CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    }
                }
                var ends: [Double] = []
                for await end in group { if let end, end.isFinite && end > 0 { ends.append(end) } }
                return ends
            }
            let audioRanges = await withTaskGroup(of: Double?.self) { group in
                for track in audioTracks {
                    group.addTask {
                        guard let range = try? await track.load(.timeRange) else { return nil }
                        return CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    }
                }
                var ends: [Double] = []
                for await end in group { if let end, end.isFinite && end > 0 { ends.append(end) } }
                return ends
            }
            let videoEnd = videoRanges.max() ?? 0
            let audioEnd = audioRanges.max() ?? 0
            let requiredEnd = max(assetDuration.isFinite ? assetDuration : 0, videoEnd)
            guard requiredEnd > 1.0, audioEnd > 0 else { return false }
            let coverage = audioEnd / requiredEnd
            return coverage >= 0.98 && audioEnd >= requiredEnd - 1.25
        }.value
    }

    private func touchFinalizedTrailerFile(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimFinalizedTrailerCache(in directory: URL, keeping current: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let candidates = files.filter { $0.pathExtension.lowercased() == "mp4" && $0 != current }
        let sorted = candidates.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for stale in sorted.dropFirst(max(0, finalizedTrailerCacheLimit - 1)) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func trailerResponseRequiresRemux(_ value: Any) -> Bool {
        func truthy(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String {
                return ["1", "true", "yes", "pending", "required", "processing", "preparing"]
                    .contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return false
        }

        if let dict = value as? [String: Any] {
            for key in ["needsRemux", "needs_remux", "remuxPending", "remux_pending", "requiresRemux", "requires_remux"] {
                if truthy(dict[key]) { return true }
            }
            // A response that exposes separate video/audio inputs but no finalized
            // playback URL must remain in the backend remux lane.
            let hasVideoInput = dict["videoUrl"] != nil || dict["video_url"] != nil
            let hasAudioInput = dict["audioUrl"] != nil || dict["audio_url"] != nil
            let hasFinalPlayback = dict["playbackUrl"] != nil || dict["playback_url"] != nil ||
                dict["remuxedUrl"] != nil || dict["remuxed_url"] != nil ||
                dict["muxedUrl"] != nil || dict["muxed_url"] != nil ||
                dict["remuxUrl"] != nil || dict["remux_url"] != nil
            if hasVideoInput && hasAudioInput && !hasFinalPlayback { return true }
            for nested in dict.values where trailerResponseRequiresRemux(nested) { return true }
        } else if let array = value as? [Any] {
            for nested in array where trailerResponseRequiresRemux(nested) { return true }
        }
        return false
    }

    private func stabilizedTrailerPlaybackURL(_ url: URL) async -> URL? {
        let lower = url.absoluteString.lowercased()
        guard lower.contains("remux-cache") else { return url }

        // The backend can publish the remux URL slightly before FFmpeg closes the MP4.
        // Wait until Content-Length is unchanged across three probes so KSPlayer never
        // opens a partially written file whose audio track ends before the video track.
        var lastLength: Int64? = nil
        var stableSamples = 0
        var successfulResponses = 0

        for attempt in 0..<8 {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("DebridChannels-tvOS/1162 TrailerRemuxSettle", forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    successfulResponses += 1
                    let length = max(response.expectedContentLength, Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1)
                    if length > 0, length == lastLength {
                        stableSamples += 1
                    } else {
                        stableSamples = 0
                    }
                    lastLength = length > 0 ? length : lastLength
                    if stableSamples >= 2, successfulResponses >= 3 { return url }
                    // Some servers omit Content-Length for HEAD. Four successful probes
                    // separated in time are still safer than opening immediately.
                    if length <= 0, successfulResponses >= 4 { return url }
                }
            } catch {
                // Keep probing briefly; resolver polling may have raced final file close.
            }
            let delay = UInt64((attempt < 3 ? 450 : 750) * 1_000_000)
            try? await Task.sleep(nanoseconds: delay)
        }

        // Preserve compatibility with backends that do not implement HEAD. The app has
        // still allowed several seconds for the remux writer to finish before playback.
        return url
    }

    private func remuxedTrailerPlaybackURL(fromJSON value: Any) -> URL? {
        var candidates: [URL] = []

        func truthy(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String {
                return ["1", "true", "yes", "pending", "required"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return false
        }

        func walk(_ node: Any, keyPath: [String] = [], unresolvedSplit: Bool = false) {
            if let string = node as? String, let url = playableTrailerURL(from: string) {
                let joined = keyPath.joined(separator: ".").lowercased()
                let raw = string.lowercased()
                // A resolver may expose a raw video URL under playbackUrl while also
                // reporting needsRemux=true. Never start that incomplete split source.
                if unresolvedSplit && !raw.contains("/remux-cache/") { return }
                if joined.contains("playbackurl") || joined.contains("previewurl") || joined.contains("remux") || raw.contains("/remux-cache/") {
                    candidates.append(url)
                }
                return
            }
            if let dict = node as? [String: Any] {
                let pendingRemux = unresolvedSplit || truthy(dict["needsRemux"]) || truthy(dict["needs_remux"]) || truthy(dict["remuxPending"]) || truthy(dict["remux_pending"])
                // Strict first pass: direct remux/playback fields only, in priority order.
                for key in ["playbackUrl", "remuxedUrl", "muxedUrl", "remuxUrl", "previewUrl", "playback_url", "remuxed_url", "muxed_url", "remux_url", "preview_url"] {
                    if let nested = dict[key] { walk(nested, keyPath: keyPath + [key], unresolvedSplit: pendingRemux) }
                }
                for key in ["preview", "trailer", "data", "result", "stream", "source"] {
                    if let nested = dict[key] { walk(nested, keyPath: keyPath + [key], unresolvedSplit: pendingRemux) }
                }
                for (key, nested) in dict where key.lowercased() != "videourl" && key.lowercased() != "video_url" && key.lowercased() != "audiourl" && key.lowercased() != "audio_url" {
                    walk(nested, keyPath: keyPath + [key], unresolvedSplit: pendingRemux)
                }
            } else if let array = node as? [Any] {
                for nested in array { walk(nested, keyPath: keyPath, unresolvedSplit: unresolvedSplit) }
            }
        }

        walk(value)
        if let remux = candidates.first(where: { $0.absoluteString.lowercased().contains("/remux-cache/") }) { return remux }
        return candidates.first
    }

    private func remuxedTrailerPlaybackURL(fromRawBody body: String) -> URL? {
        // Last-resort extractor for valid backend bodies that include an escaped remux-cache URL.
        let unescaped = body.replacingOccurrences(of: "\\/", with: "/")
        guard let range = unescaped.range(of: #"https?://[^\"\s]+/api/trailers/remux-cache/[^\"\s]+\.mp4"#, options: .regularExpression) else { return nil }
        return playableTrailerURL(from: String(unescaped[range]))
    }


    private func playableTrailerMedia(fromJSON value: Any) -> (video: URL?, audio: URL?) {
        if let dict = value as? [String: Any] {
            let videoKeys = ["playbackUrl", "playback_url", "streamUrl", "stream_url", "trailerUrl", "trailer_url", "url", "src", "videoUrl", "video_url"]
            let audioKeys = ["audioUrl", "audio_url", "audio", "audioSrc", "audio_src"]
            var bestVideo: URL? = nil
            var bestAudio: URL? = nil
            for key in videoKeys where bestVideo == nil {
                if let nested = dict[key], let url = playableTrailerURL(fromJSON: nested) { bestVideo = url }
            }
            for key in audioKeys where bestAudio == nil {
                if let nested = dict[key], let url = playableTrailerURL(fromJSON: nested) { bestAudio = url }
            }
            // Prefer nested objects that expose playbackUrl/previewUrl over bare videoUrl-only
            // siblings, but keep audioUrl when it belongs to the same result object.
            for key in ["trailer", "preview", "data", "result", "stream", "source"] {
                if let nested = dict[key] {
                    let candidate = playableTrailerMedia(fromJSON: nested)
                    if bestVideo == nil { bestVideo = candidate.video }
                    if bestAudio == nil { bestAudio = candidate.audio }
                }
            }
            for nested in dict.values {
                let candidate = playableTrailerMedia(fromJSON: nested)
                if bestVideo == nil { bestVideo = candidate.video }
                if bestAudio == nil { bestAudio = candidate.audio }
                if bestVideo != nil && bestAudio != nil { break }
            }
            return (bestVideo, bestAudio)
        }
        if let array = value as? [Any] {
            for nested in array {
                let candidate = playableTrailerMedia(fromJSON: nested)
                if candidate.video != nil { return candidate }
            }
            return (nil, nil)
        }
        return (playableTrailerURL(fromJSON: value), nil)
    }

    private func playableTrailerURL(fromJSON value: Any) -> URL? {
        let preferred = ["playbackUrl", "remuxedUrl", "muxedUrl", "remuxUrl", "playback_url", "remuxed_url", "muxed_url", "remux_url", "streamUrl", "stream_url", "trailerUrl", "trailer_url", "url", "src", "videoUrl", "video_url"]
        if let string = value as? String { return playableTrailerURL(from: string) }
        if let dict = value as? [String: Any] {
            for key in preferred {
                if let nested = dict[key], let url = playableTrailerURL(fromJSON: nested) { return url }
            }
            for key in ["trailer", "preview", "data", "result", "stream", "source"] {
                if let nested = dict[key], let url = playableTrailerURL(fromJSON: nested) { return url }
            }
            for nested in dict.values {
                if let url = playableTrailerURL(fromJSON: nested) { return url }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let url = playableTrailerURL(fromJSON: nested) { return url }
            }
        }
        return nil
    }

    private func playableTrailerURL(from raw: String) -> URL? {
        TrailerServiceManager.shared.playableTrailerURL(from: raw)
    }

    private func sourceLinkCacheKey(for item: MediaItem, providerFilter: String) -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let provider = providerFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "All Providers" : providerFilter
        let type = normalizedStremioType(item.type)
        let stableID: String
        if let imdb = clean(item.imdbId) { stableID = imdb }
        else if let tmdb = clean(item.tmdbId) { stableID = "tmdb:\(tmdb)" }
        else if let tvdb = clean(item.tvdbId) { stableID = "tvdb:\(tvdb)" }
        else if let id = clean(item.id) { stableID = id }
        else { stableID = "title:\(item.title.lowercased())" }
        let season = item.seasonNumber.map(String.init) ?? "-"
        let episode = item.episodeNumber.map(String.init) ?? "-"
        return [provider.lowercased(), type, stableID.lowercased(), season, episode].joined(separator: "|")
    }

    private func rememberStreamLinks(_ links: [StreamLink], for item: MediaItem, providerFilter: String) {
        // vBRDC212: short-lived stale-while-revalidate memory cache. Do not persist these
        // links to disk because debrid/CDN signatures may expire or contain account context.
        guard !links.isEmpty else { return }
        let key = sourceLinkCacheKey(for: item, providerFilter: providerFilter)
        sourceLinkMemoryCache[key] = SourceLinkMemoryCacheEntry(createdAt: Date(), links: links)
        sourceLinkMemoryCacheOrder.removeAll { $0 == key }
        sourceLinkMemoryCacheOrder.append(key)
        while sourceLinkMemoryCacheOrder.count > sourceLinkMemoryCacheLimit {
            let removed = sourceLinkMemoryCacheOrder.removeFirst()
            sourceLinkMemoryCache.removeValue(forKey: removed)
        }
    }

    private func cachedStreamLinks(for item: MediaItem, providerFilter: String) -> [StreamLink] {
        let key = sourceLinkCacheKey(for: item, providerFilter: providerFilter)
        guard let entry = sourceLinkMemoryCache[key] else { return [] }
        guard Date().timeIntervalSince(entry.createdAt) <= sourceLinkMemoryCacheTTL else {
            sourceLinkMemoryCache.removeValue(forKey: key)
            sourceLinkMemoryCacheOrder.removeAll { $0 == key }
            return []
        }
        sourceLinkMemoryCacheOrder.removeAll { $0 == key }
        sourceLinkMemoryCacheOrder.append(key)
        return entry.links
    }

    private func cachedSourceManifest(for rawManifest: String) -> (URL, StremioManifest)? {
        let key = manifestDeduplicationKey(rawManifest)
        guard let entry = sourceManifestMemoryCache[key],
              Date().timeIntervalSince(entry.createdAt) <= sourceManifestMemoryCacheTTL,
              let resolvedURL = URL(string: entry.resolvedManifestURL) else {
            sourceManifestMemoryCache.removeValue(forKey: key)
            sourceManifestMemoryCacheOrder.removeAll { $0 == key }
            return nil
        }
        sourceManifestMemoryCacheOrder.removeAll { $0 == key }
        sourceManifestMemoryCacheOrder.append(key)
        return (resolvedURL, entry.manifest)
    }

    private func rememberSourceManifest(_ manifest: StremioManifest, resolvedURL: URL, rawManifest: String) {
        let key = manifestDeduplicationKey(rawManifest)
        sourceManifestMemoryCache[key] = SourceManifestMemoryCacheEntry(
            createdAt: Date(),
            resolvedManifestURL: resolvedURL.absoluteString,
            manifest: manifest
        )
        sourceManifestMemoryCacheOrder.removeAll { $0 == key }
        sourceManifestMemoryCacheOrder.append(key)
        while sourceManifestMemoryCacheOrder.count > sourceManifestMemoryCacheLimit {
            let removed = sourceManifestMemoryCacheOrder.removeFirst()
            sourceManifestMemoryCache.removeValue(forKey: removed)
        }
    }


    // vBRDC212: one provider owns one foreground network race. Each configured addon is
    // scanned independently so a dead/slow provider cannot serialize every provider behind it.
    // The result is merged on the CatalogStore actor as soon as that provider finishes.
    private struct SourceAddonScanResult {
        var rawManifest: String
        var provider: String
        var matchedSelection: Bool
        var state: SourceProviderRequestState
        var message: String
        var attempts: Int
        var links: [StreamLink]
        var failure: String?
    }

    private func sourceManifestAllowsStreamRequest(type: String, id: String, manifest: StremioManifest) -> Bool {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let streamResources = (manifest.resources ?? []).filter {
            $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stream"
        }
        guard !streamResources.isEmpty else { return false }
        for resource in streamResources {
            let resourceTypes = (resource.types?.isEmpty == false ? resource.types : manifest.types) ?? []
            if !resourceTypes.isEmpty {
                let typeMatches = resourceTypes.contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedType
                }
                if !typeMatches { continue }
            }
            let prefixes = (resource.idPrefixes?.isEmpty == false ? resource.idPrefixes : manifest.idPrefixes) ?? []
            if prefixes.isEmpty { return true }
            if prefixes.contains(where: { prefix in
                let clean = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty || id.hasPrefix(clean)
            }) {
                return true
            }
        }
        return false
    }

    private func scanSingleSourceAddonProvider(
        rawManifest: String,
        item: MediaItem,
        activeProviderFilter: String,
        typeCandidates: [String],
        idCandidates: [String],
        fallbackIDCandidates: [String],
        batchSize: Int,
        urlSession: URLSession
    ) async -> SourceAddonScanResult {
        var manifestDecoded: StremioManifest?
        var workingManifestURL: URL?
        let rawCanonical = providerCanonical(rawManifest)
        let mediaFusionHint = rawCanonical.contains("mediafusion")

        if let cached = cachedSourceManifest(for: rawManifest) {
            workingManifestURL = cached.0
            manifestDecoded = cached.1
        } else {
            for candidate in manifestURLCandidates(from: rawManifest) {
                guard !Task.isCancelled, let candidateURL = URL(string: candidate) else { continue }
                do {
                    let manifestTimeout: TimeInterval = mediaFusionHint ? 6.0 : 4.0
                    var request = URLRequest(url: candidateURL, timeoutInterval: manifestTimeout)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/923 UniversalInstantSourceFanout", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await urlSession.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    let decoded = try JSONDecoder().decode(StremioManifest.self, from: data)
                    manifestDecoded = decoded
                    workingManifestURL = candidateURL
                    rememberSourceManifest(decoded, resolvedURL: candidateURL, rawManifest: rawManifest)
                    let identityName = decoded.name ?? candidateURL.host ?? "Stremio"
                    let identityIcon = Self.highest(decoded.logo ?? decoded.icon)
                    addonIdentities[rawManifest] = StremioAddonIdentity(name: identityName, iconURL: identityIcon, kind: addonKind(from: decoded))
                    break
                } catch {
                    continue
                }
            }
        }

        guard let manifestURL = workingManifestURL, let manifest = manifestDecoded else {
            let provider = SourceIntelligenceManager.providerDisplayName(
                sourceName: providerName(from: rawManifest, manifest: nil),
                manifestURL: rawManifest
            )
            return SourceAddonScanResult(
                rawManifest: rawManifest,
                provider: provider,
                matchedSelection: sourceProviderMatches(selection: activeProviderFilter, provider: provider, manifestURL: rawManifest),
                state: .failed,
                message: "Manifest failed",
                attempts: 0,
                links: [],
                failure: "Could not load manifest from \(rawManifest). Configure-page URLs must resolve to /manifest.json or a configured addon URL."
            )
        }

        let sourceName = manifest.name ?? manifestURL.host ?? "Stremio"
        let provider = SourceIntelligenceManager.providerDisplayName(sourceName: sourceName, manifestURL: rawManifest)
        let matchedSelection = sourceProviderMatches(selection: activeProviderFilter, provider: provider, manifestURL: rawManifest)
        guard matchedSelection else {
            return SourceAddonScanResult(rawManifest: rawManifest, provider: provider, matchedSelection: false, state: .noLinks, message: "filtered", attempts: 0, links: [], failure: nil)
        }
        guard sourceManifestCanResolvePlayableLinks(rawManifest: rawManifest, manifestURL: manifestURL, manifest: manifest) else {
            let mediaFusion = providerCanonical(sourceName + " " + rawManifest).contains("mediafusion")
            return SourceAddonScanResult(rawManifest: rawManifest, provider: provider, matchedSelection: true, state: .noLinks, message: mediaFusion ? "missing stream endpoint" : "catalog metadata only", attempts: 0, links: [], failure: nil)
        }

        let base = normalizedStremioBase(from: manifestURL.absoluteString)
        let addonTypes = expandedStreamTypes(typeCandidates: typeCandidates, manifest: manifest)
        let passes: [(ids: [String], strict: Bool)] = [
            (idCandidates, false),
            (fallbackIDCandidates, true)
        ].filter { !$0.ids.isEmpty }
        let isMediaFusion = providerCanonical(sourceName + " " + rawManifest).contains("mediafusion")
        let streamTimeout: TimeInterval = isMediaFusion ? 8.0 : 6.0
        var links: [StreamLink] = []
        var localSeen = Set<String>()
        var attempts = 0
        var rawStreamCount = 0
        var titleFilteredCount = 0
        var duplicateFilteredCount = 0
        var sawTimeout = false
        var sawFailure = false

        providerPasses: for pass in passes {
            if pass.strict && !links.isEmpty { break }
            for type in addonTypes {
                for streamID in pass.ids {
                    guard !Task.isCancelled, links.count < batchSize else { break providerPasses }
                    guard sourceManifestAllowsStreamRequest(type: type, id: streamID, manifest: manifest) else { continue }
                    guard let encodedID = streamID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let streamURL = URL(string: "\(base)/stream/\(type)/\(encodedID).json") else { continue }
                    attempts += 1
                    do {
                        var request = URLRequest(url: streamURL, timeoutInterval: streamTimeout)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("DebridChannels-tvOS/923 UniversalInstantSourceFanout", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await urlSession.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        let decoded = try JSONDecoder().decode(StremioStreamResponse.self, from: data)
                        let rawStreams = decoded.streams ?? []
                        rawStreamCount += rawStreams.count
                        var appendedFromEndpoint = 0
                        for stream in prioritizeEnglishStremioStreams(rawStreams) {
                            guard links.count < batchSize else { break }
                            let title = stream.title ?? stream.name ?? stream.behaviorHints?.filename ?? "Stream"
                            if !streamTitleMatchesRequestedEpisode(title, item: item, requireExplicitEpisodeToken: pass.strict) {
                                titleFilteredCount += 1
                                continue
                            }
                            let playableURL = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? stream.url : stream.externalUrl
                            let isExternalOnly = (stream.url == nil && stream.externalUrl != nil && playableURL == stream.externalUrl)
                            let sizeText: String
                            if let bytes = stream.behaviorHints?.videoSize, bytes > 0 {
                                sizeText = String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
                            } else {
                                sizeText = parsedSizeText(from: title) ?? "Unknown size"
                            }
                            let key = "\(playableURL ?? stream.infoHash ?? stream.externalUrl ?? title)|\(stream.fileIdx ?? -1)"
                            guard localSeen.insert(key).inserted else {
                                duplicateFilteredCount += 1
                                continue
                            }
                            let subtitles = (stream.subtitles ?? []).compactMap { subtitle -> String? in
                                guard let raw = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
                                return raw
                            }
                            let providerService = SourceIntelligenceManager.debridServiceLabel(manifestURL: rawManifest, sourceName: sourceName, stream: stream)
                            links.append(StreamLink(
                                title: title,
                                url: playableURL,
                                quality: parsedQuality(from: title),
                                size: sizeText,
                                source: sourceName,
                                providerService: providerService,
                                infoHash: stream.infoHash,
                                fileIndex: stream.fileIdx,
                                subtitleURLs: subtitles,
                                requestHeaders: (stream.behaviorHints?.proxyHeaders?.request ?? [:]).map {
                                    StreamRequestHeader(name: $0.key, value: $0.value)
                                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                                isExternalURL: isExternalOnly
                            ))
                            appendedFromEndpoint += 1
                        }
                        // A valid endpoint for this provider already returned its ranked source
                        // set. Do not keep probing alternate aliases that normally repeat it.
                        if appendedFromEndpoint > 0 { break providerPasses }
                    } catch {
                        if let urlError = error as? URLError, urlError.code == .timedOut { sawTimeout = true }
                        else { sawFailure = true }
                    }
                }
            }
        }

        let state: SourceProviderRequestState
        let message: String
        if !links.isEmpty {
            state = .returnedLinks
            let warnings = (sawTimeout || sawFailure) ? " with endpoint warnings" : ""
            message = "raw \(rawStreamCount) / shown \(links.count) / title \(titleFilteredCount) / dup \(duplicateFilteredCount)\(warnings)"
        } else if sawTimeout {
            state = .timeout
            message = "timeout"
        } else if sawFailure {
            state = .failed
            message = "failed"
        } else {
            state = .noLinks
            message = rawStreamCount == 0 ? "raw 0 / shown 0" : "raw \(rawStreamCount) / shown 0 / title \(titleFilteredCount) / dup \(duplicateFilteredCount)"
        }
        return SourceAddonScanResult(rawManifest: rawManifest, provider: provider, matchedSelection: true, state: state, message: message, attempts: attempts, links: links, failure: nil)
    }

    // v935: Source Intelligence recovery path. Favorites/search/detail hydration can hand
    // the resolver a sparse or alternate identity for the same title. Retry only when the
    // first complete addon scan returns zero links, using richer loaded-row identities.
    // Successful results are published by findStreams immediately and no valid links are hidden.
    func findStreamsForcePopulated(for primaryItem: MediaItem, fallbackItem: MediaItem? = nil, providerFilter: String? = nil) async -> [StreamLink] {
        guard playbackUnityBrowseInteractionAllowed else { return streamLinks }
        var candidates: [MediaItem] = []
        var seen = Set<String>()

        func identityKey(_ item: MediaItem) -> String {
            let type = normalizedStremioType(item.type)
            let imdb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let season = item.seasonNumber.map(String.init) ?? "-"
            let episode = item.episodeNumber.map(String.init) ?? "-"
            return [type, imdb, tmdb, tvdb, id, season, episode].joined(separator: "|")
        }

        func append(_ item: MediaItem?) {
            guard let item else { return }
            let key = identityKey(item)
            if seen.insert(key).inserted { candidates.append(item) }
        }

        append(primaryItem)
        append(fallbackItem)

        let primaryTitle = primaryItem.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primaryType = normalizedStremioType(primaryItem.type)
        for row in rows {
            for candidate in row.items {
                guard normalizedStremioType(candidate.type) == primaryType else { continue }
                let sameStrongID = [
                    (!(primaryItem.imdbId ?? "").isEmpty && primaryItem.imdbId == candidate.imdbId),
                    (!(primaryItem.tmdbId ?? "").isEmpty && primaryItem.tmdbId == candidate.tmdbId),
                    (!(primaryItem.tvdbId ?? "").isEmpty && primaryItem.tvdbId == candidate.tvdbId),
                    (!primaryItem.id.isEmpty && primaryItem.id == candidate.id)
                ].contains(true)
                let sameTitle = !primaryTitle.isEmpty && candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == primaryTitle
                guard sameStrongID || sameTitle else { continue }
                append(candidate)
            }
        }

        var lastResult: [StreamLink] = []
        // vBRDC212: recovery identities are a fallback, not six complete foreground scans.
        // The primary item and at most two richer identities cover the real-world mismatch
        // cases without multiplying a provider timeout into a minute-long wait.
        for candidate in candidates.prefix(3) {
            guard !Task.isCancelled else { return lastResult }
            let result = await findStreams(for: candidate, providerFilter: providerFilter)
            lastResult = result
            if !result.isEmpty {
                if identityKey(candidate) != identityKey(primaryItem) {
                    lastStreamMessage = "Best playable links ready for \(primaryItem.title) using a recovered catalog identity."
                }
                return result
            }
        }
        return lastResult
    }



    func cancelCurrentStreamSearch(reason: String = "Source Intelligence cancelled.", publishState: Bool = true) {
        activeStreamSearchGeneration += 1
        activeStreamSearchItemID = nil
        cancelActiveSourceProviderTasks()
        rotateSourceIntelligenceURLSession()
        if publishState {
            sourceIntelligenceBatchStatus = reason
            lastStreamMessage = reason
        }
    }

    func findStreams(for item: MediaItem, providerFilter: String? = nil, allowStartupConnectionRecovery: Bool = true) async -> [StreamLink] {
        guard playbackUnityBrowseInteractionAllowed else { return streamLinks }
        let optionalFebBoxEnabled = UserDefaults.standard.bool(forKey: BackupStreamingClient.febBoxEnabledKey)
        let febBoxCookieForSearch = optionalFebBoxEnabled ? BackupStreamingCredentialStore.readFebBoxCookie() : ""
        let nuvioProviderNames = NuvioPluginPreferences.enabledProviderNames()
        let nuvioRepositoryNames = NuvioPluginPreferences.enabledRepositoryNames()
        let requestedProviderFilter = providerFilter ?? selectedSourceProvider
        let trimmedProviderFilter = requestedProviderFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let torBoxUsenetAPIKey = effectiveTorBoxAPIKey()
        let torBoxUsenetKeyAvailable = !torBoxUsenetAPIKey.isEmpty
        let requestedCanonicalProvider = providerCanonical(trimmedProviderFilter)
        let requestedTorBoxUsenetWithoutKey = requestedCanonicalProvider.contains("torboxusenet") && !torBoxUsenetKeyAvailable
        let isNuvioProviderFilter = nuvioProviderNames.contains { $0.caseInsensitiveCompare(trimmedProviderFilter) == .orderedSame }
        let isNuvioRepositoryFilter = NuvioPluginPreferences.groupProvidersByRepository()
            && nuvioRepositoryNames.contains { $0.caseInsensitiveCompare(trimmedProviderFilter) == .orderedSame }
        let activeProviderFilter: String = (!requestedTorBoxUsenetWithoutKey && (trimmedProviderFilter.isEmpty || trimmedProviderFilter == "All Providers" || isKnownSourceProvider(trimmedProviderFilter) || isNuvioProviderFilter || isNuvioRepositoryFilter)) ? (trimmedProviderFilter.isEmpty ? "All Providers" : trimmedProviderFilter) : "All Providers"
        selectedSourceProvider = activeProviderFilter
        cancelActiveSourceProviderTasks()
        activeStreamSearchGeneration += 1
        let searchGeneration = activeStreamSearchGeneration
        activeStreamSearchItemID = item.id
        let hasNuvioProviders = !nuvioProviderNames.isEmpty
        lastStreamMessage = activeProviderFilter == "All Providers"
            ? (hasNuvioProviders ? "Searching configured addons, debrid sources, and In-S providers for \(item.title)…" : "Searching every configured Stremio addon for \(item.title)…")
            : "Searching \(activeProviderFilter) for \(item.title)…"
        sourceIntelligenceBatchStatus = hasNuvioProviders && activeProviderFilter == "All Providers" ? "Resolving addons + In-S providers…" : "Resolving best links…"
        // Nuvio playback URLs are opaque short-lived sessions, so only durable addon/debrid
        // and FebBox results are restored from the Source Intelligence cache.
        let cachedLinks = cachedStreamLinks(for: item, providerFilter: activeProviderFilter).filter { link in
            let url = (link.url ?? "").lowercased()
            if link.isTorBoxUsenetCandidate && !torBoxUsenetKeyAvailable { return false }
            return link.providerService?.caseInsensitiveCompare("Nuvio") != .orderedSame && link.providerService?.caseInsensitiveCompare("In-S") != .orderedSame && !url.contains("/api/nuvio/playback/")
        }
        streamLinks = cachedLinks
        sourceProviderStatuses = []
        if !cachedLinks.isEmpty {
            sourceIntelligenceBatchStatus = "Restored \(cachedLinks.count) cached link\(cachedLinks.count == 1 ? "" : "s"). Refreshing addons…"
            lastStreamMessage = "Restored previous Source Intelligence results for \(item.title). Refreshing in the background…"
        }
        alternateAudioSources = []
        selectedAlternateAudioSource = nil
        invalidatePreparedAlternateAudioBridge(message: "Bridge not prepared")
        alternateAudioSyncOffsetMS = 0

        let searchItemID = item.id
        let urlSession = sourceIntelligenceURLSession
        let typeCandidates = streamTypeCandidates(for: item)
        let idCandidates = streamIDCandidates(for: item)
        let fallbackIDCandidates = streamIDFallbackCandidates(for: item)
        var found: [StreamLink] = []
        var seenKeys = Set<String>()
        var attempts = 0
        var addonFailures: [String] = []
        let batchSize = SourceIntelligenceManager.configuredMaximumLinks()

        func searchIsActive() -> Bool {
            !Task.isCancelled && playbackUnityBrowseInteractionAllowed && activeStreamSearchGeneration == searchGeneration && isCurrentStreamSearch(searchItemID)
        }

        func cappedRankedLinks(_ links: [StreamLink]) -> [StreamLink] {
            // vBRDC072: native TorBox Usenet is a discovery lane, not a torrent/debrid
            // ranking lane. Never apply the global Best-Ranked 25/50 pruning cap to it.
            // We still sort valid rows for presentation and deduplicate at discovery time,
            // but every valid Usenet row survives Source Intelligence publication.
            let usenetLinks = sortedStreamLinks(links.filter(\.isTorBoxUsenetCandidate), for: item)
            let ordinaryLinks = sortedStreamLinks(links.filter { !$0.isTorBoxUsenetCandidate }, for: item)
            let usenetOnly = providerCanonical(activeProviderFilter).contains("torboxusenet")
            if usenetOnly {
                return usenetLinks
            }
            if activeProviderFilter == "All Providers" {
                let cappedOrdinary = balancedSourceProviderLinks(ordinaryLinks, limit: batchSize)
                return sortedStreamLinks(cappedOrdinary + usenetLinks, for: item)
            }
            return Array(ordinaryLinks.prefix(batchSize))
        }

        func publishBatch(_ links: [StreamLink], message: String, final: Bool = false) {
            guard searchIsActive() else { return }
            // vBRDC040: a Stremio/Xtream batch must not overwrite In-S links that arrived
            // asynchronously a moment earlier. Merge the two source lanes at the single
            // published-state boundary. The 25/50 cap applies only to ordinary torrent/debrid
            // rows; native TorBox Usenet rows are retained in full.
            var mergedLinks = links
            var mergedKeys = Set(links.map { "\($0.source.lowercased())|\(($0.url ?? "").lowercased())" })
            for inSLink in activeInSIncrementalLinks {
                let key = "\(inSLink.source.lowercased())|\((inSLink.url ?? "").lowercased())"
                if mergedKeys.insert(key).inserted { mergedLinks.append(inSLink) }
            }
            // v984: enforce the selected 25/50 setting at the single published-state
            // boundary. Every incremental update and the final result share the same
            // ordinary-link cap while native TorBox Usenet remains unfiltered.
            let nextVisibleLinks = cappedRankedLinks(mergedLinks)
            // vBRDC256 Phase 5: provider completions frequently produce the same visible
            // top 25/50 set. Republishing an identical Hashable array needlessly invalidates
            // the full Source Intelligence panel and can hitch the Live TV/catalog UI when
            // Aether/KSPlayer is also producing playback callbacks.
            if nextVisibleLinks != streamLinks {
                streamLinks = nextVisibleLinks
            }
            let showing = streamLinks.count
            if showing > 0 {
                let cacheSafeLinks = streamLinks.filter { link in
                    let url = (link.url ?? "").lowercased()
                    return link.providerService?.caseInsensitiveCompare("Nuvio") != .orderedSame && link.providerService?.caseInsensitiveCompare("In-S") != .orderedSame && !url.contains("/api/nuvio/playback/")
                }
                if !cacheSafeLinks.isEmpty {
                    rememberStreamLinks(cacheSafeLinks, for: item, providerFilter: activeProviderFilter)
                }
            }
            let visibleUsenetCount = streamLinks.filter(\.isTorBoxUsenetCandidate).count
            let nextBatchStatus: String
            if visibleUsenetCount > 0 {
                nextBatchStatus = final
                    ? "Best ranked + all Usenet ready (\(showing) total • \(visibleUsenetCount) Usenet unfiltered)."
                    : "Resolving addons… \(showing) shown • all \(visibleUsenetCount) Usenet retained"
            } else {
                nextBatchStatus = final ? "Best ranked links ready (\(showing)/\(batchSize) max)." : "Resolving addons… showing \(showing) of \(batchSize) max"
            }
            // vBRDC257 app-wide stabilization: provider completions may arrive in a burst.
            // Avoid publishing identical status/message strings just as we already avoid
            // publishing identical visible link arrays. This removes two additional global
            // ObservableObject invalidations per no-op provider completion.
            if sourceIntelligenceBatchStatus != nextBatchStatus {
                sourceIntelligenceBatchStatus = nextBatchStatus
            }
            if lastStreamMessage != message {
                lastStreamMessage = message
            }
        }

        // vBRDC040: In-S now mirrors Nuvio's streaming provider fan-out instead of
        // putting every enabled provider behind one all-or-nothing backend request. Each
        // provider receives its own settings + media identity request and publishes as soon
        // as it completes. Slow providers therefore cannot hide links from fast providers.
        let additiveNuvioAllowed = hasNuvioProviders
            && (activeProviderFilter == "All Providers" || isNuvioProviderFilter || isNuvioRepositoryFilter)
        let enabledInSProviderRequests = additiveNuvioAllowed
            ? NuvioPluginPreferences.enabledProviderRequests().filter { request in
                activeProviderFilter == "All Providers"
                    || request.providerName.caseInsensitiveCompare(activeProviderFilter) == .orderedSame
                    || (isNuvioRepositoryFilter && request.repositoryName.caseInsensitiveCompare(activeProviderFilter) == .orderedSame)
            }
            : []
        if additiveNuvioAllowed {
            for providerRequest in enabledInSProviderRequests {
                upsertSourceProviderStatus(provider: providerRequest.providerName, state: .searching, linkCount: 0, message: "In-S • searching")
            }
        }
        // vBRDC212: identity hydration must never sit in front of the Stremio/debrid race.
        // Start it once in parallel; every In-S provider awaits the same task while the regular
        // addon, Xtream, FebBox and TorBox lanes are already free to return usable links.
        let inSResolverTask: Task<MediaItem, Never>? = enabledInSProviderRequests.isEmpty ? nil : Task { @MainActor [weak self] in
            guard let self else { return item }
            return await self.inSResolverReadyItem(item)
        }
        activeInSResolverTask = inSResolverTask
        let backendBaseURLForInS = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
        let launchedInSTasks: [Task<Void, Never>] = enabledInSProviderRequests.enumerated().map { index, providerRequest in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Nuvio staggers scraper starts slightly so a large repository does not
                // stampede the network/runtime all at once. Mirror its 60ms cadence.
                if index > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(index) * 60_000_000)
                }
                guard !Task.isCancelled,
                      self.playbackUnityBrowseInteractionAllowed,
                      self.activeStreamSearchGeneration == searchGeneration,
                      self.isCurrentStreamSearch(searchItemID) else { return }
                guard !Task.isCancelled,
                      self.activeStreamSearchGeneration == searchGeneration,
                      self.isCurrentStreamSearch(searchItemID) else { return }
                do {
                    let providerItem = await inSResolverTask?.value ?? item
                    guard !Task.isCancelled,
                          self.activeStreamSearchGeneration == searchGeneration,
                          self.isCurrentStreamSearch(searchItemID) else { return }
                    let result = try await NuvioPluginClient.resolveProvider(
                        backendBaseURL: backendBaseURLForInS,
                        item: providerItem,
                        providerRequest: providerRequest
                    )
                    guard !Task.isCancelled,
                          self.activeStreamSearchGeneration == searchGeneration,
                          self.isCurrentStreamSearch(searchItemID) else { return }

                    if result.providerStatuses.isEmpty {
                        self.upsertSourceProviderStatus(
                            provider: providerRequest.providerName,
                            state: result.links.isEmpty ? .noLinks : .returnedLinks,
                            linkCount: result.links.count,
                            message: result.links.isEmpty ? "In-S • no links" : "In-S • returned \(result.links.count)"
                        )
                    } else {
                        for providerStatus in result.providerStatuses {
                            let state: SourceProviderRequestState
                            let rawState = providerStatus.state.lowercased()
                            if providerStatus.count > 0 { state = .returnedLinks }
                            else if rawState == "timeout" { state = .timeout }
                            else if rawState == "failed" || rawState == "error" { state = .failed }
                            else { state = .noLinks }
                            self.upsertSourceProviderStatus(
                                provider: providerStatus.provider,
                                state: state,
                                linkCount: providerStatus.count,
                                message: "In-S • \(providerStatus.message)"
                            )
                        }
                    }

                    var incrementalKeys = Set(self.activeInSIncrementalLinks.map { link in
                        "\(link.source.lowercased())|\((link.url ?? "").lowercased())"
                    })
                    var added = 0
                    for link in result.links where link.isDirectPlayable {
                        let matchesRepositoryFilter = isNuvioRepositoryFilter
                            && providerRequest.repositoryName.caseInsensitiveCompare(activeProviderFilter) == .orderedSame
                        guard activeProviderFilter == "All Providers"
                            || link.source.caseInsensitiveCompare(activeProviderFilter) == .orderedSame
                            || matchesRepositoryFilter else { continue }
                        let rawURL = (link.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !rawURL.isEmpty else { continue }
                        let key = "\(link.source.lowercased())|\(rawURL.lowercased())"
                        guard incrementalKeys.insert(key).inserted else { continue }
                        self.activeInSIncrementalLinks.append(link)
                        added += 1
                    }
                    if added > 0 {
                        // Preserve whatever durable/addon links are already visible while replacing
                        // the In-S lane with the complete incremental set collected so far.
                        let durableVisible = self.streamLinks.filter { $0.providerService?.caseInsensitiveCompare("In-S") != .orderedSame }
                        let merged = durableVisible + self.activeInSIncrementalLinks
                        let usenetVisible = self.sortedStreamLinks(merged.filter(\.isTorBoxUsenetCandidate), for: item)
                        let ordinaryVisible = self.sortedStreamLinks(merged.filter { !$0.isTorBoxUsenetCandidate }, for: item)
                        let nextVisibleLinks: [StreamLink]
                        if self.providerCanonical(activeProviderFilter).contains("torboxusenet") {
                            nextVisibleLinks = usenetVisible
                        } else if activeProviderFilter == "All Providers" {
                            let ordinaryCapped = self.balancedSourceProviderLinks(ordinaryVisible, limit: batchSize)
                            nextVisibleLinks = self.sortedStreamLinks(ordinaryCapped + usenetVisible, for: item)
                        } else {
                            nextVisibleLinks = Array(ordinaryVisible.prefix(batchSize))
                        }
                        if nextVisibleLinks != self.streamLinks {
                            self.streamLinks = nextVisibleLinks
                        }
                        let nextBatchStatus = usenetVisible.isEmpty
                            ? "In-S providers are returning links… showing \(self.streamLinks.count) of \(batchSize) ordinary max"
                            : "In-S providers are returning links… \(self.streamLinks.count) shown • all \(usenetVisible.count) Usenet retained"
                        if self.sourceIntelligenceBatchStatus != nextBatchStatus { self.sourceIntelligenceBatchStatus = nextBatchStatus }
                        let nextMessage = "\(providerRequest.providerName) returned \(added) In-S link\(added == 1 ? "" : "s"). Other configured providers are still resolving…"
                        if self.lastStreamMessage != nextMessage { self.lastStreamMessage = nextMessage }
                    } else if !result.message.isEmpty {
                        self.lastStreamMessage = result.message
                    }
                } catch {
                    guard self.activeStreamSearchGeneration == searchGeneration,
                          self.isCurrentStreamSearch(searchItemID) else { return }
                    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    let timedOut = (error as? URLError)?.code == .timedOut || message.lowercased().contains("timed out") || message.lowercased().contains("timeout")
                    self.upsertSourceProviderStatus(
                        provider: providerRequest.providerName,
                        state: timedOut ? .timeout : .failed,
                        linkCount: 0,
                        message: "In-S • \(message.isEmpty ? (timedOut ? "timeout" : "failed") : message)"
                    )
                }
            }
        }
        activeInSProviderTasks = launchedInSTasks

        let additiveFebBoxAllowed = optionalFebBoxEnabled
            && !febBoxCookieForSearch.isEmpty
            && (activeProviderFilter == "All Providers" || activeProviderFilter.localizedCaseInsensitiveContains("febbox"))
        let additiveFebBoxTask: Task<[StreamLink], Never>? = additiveFebBoxAllowed
            ? Task {
                let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
                return (try? await BackupStreamingClient.resolveFebBox(
                    backendBaseURL: backendBaseURL,
                    item: item,
                    febboxCookie: febBoxCookieForSearch
                )) ?? []
            }
            : nil

        // vBRDC060: TorBox Usenet is credential-gated but independent of Torrentio. With no effective TorBox API
        // key, the Usenet lane is absent from Source Intelligence entirely: no provider
        // pill, no no-key placeholder, and no stale Usenet rows. Once a key is present,
        // discovery is attempted directly, then through the backend relay, then against
        // the user's Main-API Usenet library. Torrentio state is never consulted.
        let torBoxUsenetAllowed = torBoxUsenetKeyAvailable
            && (activeProviderFilter == "All Providers" || providerCanonical(activeProviderFilter).contains("torboxusenet"))
        let torBoxUsenetTask: Task<([TorBoxUsenetSearchResult], String?), Never>?
        if torBoxUsenetAllowed {
            // vBRDC073: keep an explicit handle to the native Usenet lane. The vBRDC072
            // task was local-only, so lifecycle/search cancellation could invalidate its
            // retained URLSession while a retry was still running.
            let task = Task { () -> ([TorBoxUsenetSearchResult], String?) in
                do {
                    let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
                    let bridgeManifestURL = UserDefaults.standard.string(forKey: "torBoxUsenetBridgeManifestURLV1")
                    let results = try await TorBoxUsenetClient.search(
                        item: item,
                        apiKey: torBoxUsenetAPIKey,
                        backendBaseURL: backendBaseURL,
                        bridgeManifestURL: bridgeManifestURL,
                        session: urlSession
                    )
                    return (results, nil)
                } catch is CancellationError {
                    return ([], "TorBox Usenet search cancelled.")
                } catch {
                    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ([], message.isEmpty ? "TorBox Usenet unavailable for this account." : message)
                }
            }
            torBoxUsenetTask = task
            activeTorBoxUsenetTask = task
        } else {
            // No API key means no TorBox Usenet surface in Source Intelligence.
            torBoxUsenetTask = nil
        }

        // vBRDC212: Xtream is launched beside the Stremio provider race instead of blocking
        // every addon behind its response. It is merged after the provider wave, while the
        // source panel can already be showing links from whichever Stremio addon finished first.
        let xtreamTask = Task { @MainActor [weak self] in
            guard let self else { return [StreamLink]() }
            return await self.findXtreamVODLinks(for: item)
        }

        let sourceManifests = prioritizedManifestURLsWithMetadataFallback()
        // vBRDC212: sliding bounded concurrency, not fixed chunks. With chunk barriers,
        // one dead provider in the first eight could still delay provider #9 even when seven
        // lanes were already free. Refill a lane immediately whenever any addon completes.
        // vBRDC214: universal Stremio fan-out. Every configured stream addon gets a lane
        // immediately; no addon waits behind an arbitrary 12-provider application queue.
        // URLSession still enforces per-host transport limits, so duplicate endpoints cannot
        // monopolize the process, while independent addons all begin resolving at once.
        let maximumConcurrentProviders = max(1, sourceManifests.count)
        if !sourceManifests.isEmpty {
            await withTaskGroup(of: SourceAddonScanResult?.self) { group in
                var nextProviderIndex = 0
                let initialCount = min(maximumConcurrentProviders, sourceManifests.count)
                for _ in 0..<initialCount {
                    let rawManifest = sourceManifests[nextProviderIndex]
                    nextProviderIndex += 1
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return await self.scanSingleSourceAddonProvider(
                            rawManifest: rawManifest,
                            item: item,
                            activeProviderFilter: activeProviderFilter,
                            typeCandidates: typeCandidates,
                            idCandidates: idCandidates,
                            fallbackIDCandidates: fallbackIDCandidates,
                            batchSize: batchSize,
                            urlSession: urlSession
                        )
                    }
                }

                // Completion order is intentional: the first healthy provider publishes
                // immediately. Every completed lane is refilled before waiting again, so
                // later providers are never trapped behind a slow fixed batch.
                while let optionalResult = await group.next() {
                    guard searchIsActive() else {
                        group.cancelAll()
                        xtreamTask.cancel()
                        return
                    }
                    if let result = optionalResult {
                        attempts += result.attempts
                        if result.matchedSelection {
                            if let failure = result.failure { addonFailures.append(failure) }
                            upsertSourceProviderStatus(
                                provider: result.provider,
                                state: result.state,
                                linkCount: result.links.count,
                                message: result.message
                            )

                            var added = 0
                            for link in result.links {
                                let identity = link.url ?? link.infoHash ?? link.title
                                let key = "\(result.rawManifest)|\(link.source)|\(identity)|\(link.fileIndex ?? -1)"
                                guard seenKeys.insert(key).inserted else { continue }
                                found.append(link)
                                added += 1
                            }
                            if added > 0 {
                                let scopedText = activeProviderFilter == "All Providers" ? "all addons" : activeProviderFilter
                                publishBatch(
                                    found,
                                    message: "\(result.provider) returned \(added) link\(added == 1 ? "" : "s"). Showing results now while \(scopedText) continue in parallel…"
                                )
                            }
                        }
                    }

                    if nextProviderIndex < sourceManifests.count {
                        let rawManifest = sourceManifests[nextProviderIndex]
                        nextProviderIndex += 1
                        group.addTask { [weak self] in
                            guard let self else { return nil }
                            return await self.scanSingleSourceAddonProvider(
                                rawManifest: rawManifest,
                                item: item,
                                activeProviderFilter: activeProviderFilter,
                                typeCandidates: typeCandidates,
                                idCandidates: idCandidates,
                                fallbackIDCandidates: fallbackIDCandidates,
                                batchSize: batchSize,
                                urlSession: urlSession
                            )
                        }
                    }
                }
            }
        }

        var xtreamLinks: [StreamLink] = []
        if searchIsActive() {
            xtreamLinks = await xtreamTask.value
            var xtreamAdded = 0
            for link in xtreamLinks {
                guard sourceProviderMatches(selection: activeProviderFilter, provider: link.providerDisplay, manifestURL: link.source) else { continue }
                let key = "xtream|\(link.source)|\(link.url ?? link.title)"
                guard seenKeys.insert(key).inserted else { continue }
                found.append(link)
                xtreamAdded += 1
            }
            if xtreamAdded > 0 {
                publishBatch(found, message: "Xtream + configured providers are ready and ranked together.")
            }
        } else {
            xtreamTask.cancel()
        }

        if let additiveFebBoxTask {
            let febBoxLinks = await additiveFebBoxTask.value
            if searchIsActive() {
                var added = 0
                for link in febBoxLinks {
                    let rawURL = link.url ?? ""
                    let key = "febbox-additive|\(rawURL)"
                    guard !rawURL.isEmpty, seenKeys.insert(key).inserted else { continue }
                    found.append(link)
                    added += 1
                }
                if added > 0 {
                    upsertSourceProviderStatus(provider: "FebBox", state: .returnedLinks, linkCount: added, message: "personal account • merged with addon/debrid links")
                    publishBatch(found, message: "FebBox + configured addon/debrid sources are being ranked together.")
                } else {
                    upsertSourceProviderStatus(provider: "FebBox", state: .noLinks, linkCount: 0, message: "personal account • no links")
                }
            }
        } else if optionalFebBoxEnabled && febBoxCookieForSearch.isEmpty && activeProviderFilter == "All Providers" {
            upsertSourceProviderStatus(provider: "FebBox", state: .noLinks, linkCount: 0, message: "enabled • verify personal ui cookie")
        }

        if let torBoxUsenetTask {
            let (usenetResults, usenetError) = await torBoxUsenetTask.value
            if activeStreamSearchGeneration == searchGeneration {
                activeTorBoxUsenetTask = nil
            }
            if searchIsActive() {
                var added = 0
                for result in usenetResults {
                    let identity: String
                    if !result.directPlaybackURL.isEmpty {
                        identity = "direct:\(result.directPlaybackURL.lowercased())"
                    } else if !result.hash.isEmpty {
                        identity = "hash:\(result.hash.lowercased())"
                    } else if !result.nzbURL.isEmpty {
                        identity = "nzb:\(result.nzbURL.lowercased())"
                    } else if let downloadID = result.ownedDownloadID, downloadID > 0 {
                        identity = "id:\(downloadID)"
                    } else {
                        identity = ""
                    }
                    let key = "torbox-usenet|\(identity)"
                    guard !identity.isEmpty, seenKeys.insert(key).inserted else { continue }
                    found.append(StreamLink(
                        title: result.rawTitle,
                        url: result.directPlaybackURL.isEmpty ? nil : result.directPlaybackURL,
                        quality: TorBoxUsenetClient.qualityLabel(for: result.rawTitle),
                        size: TorBoxUsenetClient.sizeLabel(bytes: result.sizeBytes),
                        source: "TorBox Usenet",
                        providerService: "TorBox",
                        torBoxUsenetNZBURL: result.nzbURL,
                        torBoxUsenetHash: result.hash,
                        torBoxUsenetCached: result.cached,
                        torBoxUsenetOwned: result.owned,
                        torBoxUsenetDownloadID: result.ownedDownloadID,
                        torBoxUsenetBridgeDirect: !result.directPlaybackURL.isEmpty
                    ))
                    added += 1
                }
                if added > 0 {
                    let cachedCount = usenetResults.filter(\.cached).count
                    let uncachedCount = max(0, usenetResults.count - cachedCount)
                    let ownedLibraryCount = usenetResults.filter { ($0.ownedDownloadID ?? 0) > 0 }.count
                    let bridgedCount = usenetResults.filter { !$0.directPlaybackURL.isEmpty }.count
                    let routeLabel = bridgedCount == usenetResults.count && bridgedCount > 0
                        ? "Whitelisted Search Bridge"
                        : (ownedLibraryCount == usenetResults.count && ownedLibraryCount > 0 ? "Main API library" : "Usenet discovery")
                    upsertSourceProviderStatus(
                        provider: "TorBox Usenet",
                        state: .returnedLinks,
                        linkCount: added,
                        message: "Connected • \(routeLabel) • \(cachedCount) cached • \(uncachedCount) download-required"
                    )
                    publishBatch(found, message: "TorBox Usenet + configured sources are being ranked together.")
                } else if let usenetError, !usenetError.isEmpty {
                    // vBRDC060: once the Main API key is present, TorBox Usenet is a real native
                    // provider independent of Torrentio. Do not silently erase it when Voyager
                    // discovery fails; expose the failure so physical testing can distinguish
                    // "processing connected" from "release search reachable".
                    upsertSourceProviderStatus(
                        provider: "TorBox Usenet",
                        state: .failed,
                        linkCount: 0,
                        message: "Usenet connected • discovery unavailable • \(usenetError)"
                    )
                } else {
                    upsertSourceProviderStatus(provider: "TorBox Usenet", state: .noLinks, linkCount: 0, message: "Connected • TorBox Search API + fallbacks returned 0 NZB links")
                }
            }
        }

        // Keep the source-search operation alive until the current In-S wave finishes,
        // but do not make the UI wait: every child task has already published its links/status
        // independently above. This is the same user-visible streaming behavior Nuvio uses.
        if !launchedInSTasks.isEmpty {
            for task in launchedInSTasks { await task.value }
            if activeStreamSearchGeneration == searchGeneration {
                activeInSProviderTasks.removeAll()
                activeInSResolverTask = nil
            }
        }
        if activeStreamSearchGeneration == searchGeneration {
            activeTorBoxUsenetTask = nil
        }

        let activeFilterIsTorBoxUsenet = providerCanonical(activeProviderFilter).contains("torboxusenet")
        if activeProviderFilter != "All Providers",
           !(activeFilterIsTorBoxUsenet && sourceProviderStatus(for: "TorBox Usenet") == nil),
           sourceProviderStatuses.allSatisfy({ !sourceProviderMatches(selection: activeProviderFilter, provider: $0.provider, manifestURL: $0.provider) }) {
            upsertSourceProviderStatus(provider: activeProviderFilter, state: .noLinks, linkCount: 0, message: "no matching configured provider")
        }

        var visibleSorted = cappedRankedLinks(found + activeInSIncrementalLinks)
        if visibleSorted.isEmpty {
            let restored = cachedStreamLinks(for: item, providerFilter: "All Providers").filter { link in
                torBoxUsenetKeyAvailable || !link.isTorBoxUsenetCandidate
            }
            if !restored.isEmpty {
                visibleSorted = restored
            }
        }

        let hadConfiguredSourceLane = attempts > 0
            || !addonFailures.isEmpty
            || !enabledInSProviderRequests.isEmpty
            || optionalFebBoxEnabled
            || torBoxUsenetKeyAvailable
            || !xtreamLinks.isEmpty

        if !visibleSorted.isEmpty {
            sourceSearchHasSucceededThisSession = true
        } else if allowStartupConnectionRecovery,
                  hadConfiguredSourceLane,
                  !sourceSearchHasSucceededThisSession,
                  !sourceStartupRecoveryUsed,
                  searchIsActive() {
            // Do not make the user force-quit after a fresh install just to get a new
            // networking generation. Retire the first session, reread provider/settings
            // state through a complete second wave, and allow connectivity a short settle
            // window. This is bounded to once per process until a successful search.
            sourceStartupRecoveryUsed = true
            sourceIntelligenceBatchStatus = "Initial provider connection is settling… retrying once with a fresh network lane."
            lastStreamMessage = "Refreshing first-launch provider connections…"
            rotateSourceIntelligenceURLSession()
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard searchIsActive() else { return [] }
            print("[SourceStartup][vBRDC097] zero-link first wave; retrying with fresh URLSession")
            return await findStreams(
                for: item,
                providerFilter: activeProviderFilter,
                allowStartupConnectionRecovery: false
            )
        }

        guard searchIsActive() else { return visibleSorted }
        publishBatch(visibleSorted, message: visibleSorted.isEmpty ? "Source scan complete with no fresh links." : "Source scan complete.", final: true)
        if visibleSorted.isEmpty {
            let failureHint = addonFailures.isEmpty ? "" : " \(addonFailures.prefix(2).joined(separator: " "))"
            if activeProviderFilter != "All Providers" {
                if providerCanonical(activeProviderFilter).contains("torboxusenet"),
                   let torBoxStatus = sourceProviderStatus(for: "TorBox Usenet"),
                   torBoxStatus.state == .failed {
                    // vBRDC074: keep the real Search API error visible during physical testing.
                    // A generic "try All Providers" message hid authentication/plan/endpoint
                    // failures and made every discovery failure look like a legitimate zero.
                    lastStreamMessage = torBoxStatus.message
                    sourceIntelligenceBatchStatus = torBoxStatus.message
                } else {
                    lastStreamMessage = "No links found from \(activeProviderFilter). Try All Providers."
                }
            } else if hasNuvioProviders {
                lastStreamMessage = "No stream links found for \(item.title).\(failureHint) Check the In-S provider status rows for timeout, provider failure, or no-links details."
            } else {
                lastStreamMessage = "No stream links found for \(item.title) after \(attempts) stream endpoint checks.\(failureHint) For Torrentio/TorBox, add the actual configured manifest URL, not only the configure webpage, and make sure the addon returns stream.url/direct links."
            }
        } else if found.isEmpty {
            lastStreamMessage = "Using cached Source Intelligence links for \(item.title) while addons returned no fresh links."
            sourceIntelligenceBatchStatus = "Cached links ready (\(visibleSorted.count))."
        } else {
            let scopedText = activeProviderFilter == "All Providers"
                ? (hasNuvioProviders ? "configured addons/debrid + In-S" : "all configured addons")
                : activeProviderFilter
            lastStreamMessage = "Best playable links ready for \(item.title) from \(scopedText)."
            let visibleUsenetCount = visibleSorted.filter(\.isTorBoxUsenetCandidate).count
            sourceIntelligenceBatchStatus = visibleUsenetCount > 0
                ? "Best ranked + all Usenet ready (\(visibleSorted.count) total • \(visibleUsenetCount) Usenet unfiltered)."
                : "Best ranked links ready (\(visibleSorted.count)/\(batchSize) max)."
        }
        return visibleSorted
    }


    private struct RealDebridAddMagnetResponse: Decodable { var id: String? }
    private struct RealDebridTorrentInfoResponse: Decodable { var id: String?; var links: [String]?; var files: [RealDebridTorrentFile]? }
    private struct RealDebridTorrentFile: Decodable { var id: Int?; var path: String?; var bytes: Int64?; var selected: Int? }
    private struct RealDebridUnrestrictResponse: Decodable { var download: String?; var streamable: Int? }

    private func resolvedDebridURLIfNeeded(stream: StremioStream, title: String, sourceName: String) async -> String? {
        if let direct = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty { return direct }
        guard let hash = stream.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty else { return stream.externalUrl }
        let sourceKey = providerCanonical(sourceName)
        let shouldResolveCometStyleHash = sourceKey.contains("comet") || sourceKey.contains("torrentio")
        guard shouldResolveCometStyleHash else { return stream.externalUrl }
        return await resolveRealDebridInfoHash(hash, fileIndex: stream.fileIdx, displayTitle: title)
    }

    func resolvePlayableURL(for link: StreamLink) async -> URL? {
        if link.isDirectPlayable, let direct = Self.makePlayableURL(from: link.url) { return direct }

        // vBRDC051: TorBox Usenet rows are intentionally unresolved during the
        // Source Intelligence scan. Resolve only the row the user actually chooses,
        // allowing TorBox to reuse/cache/download/repair/unpack before it returns the
        // final CDN URL. This applies to every TorBox account; there is no Pro gate.
        if link.isTorBoxUsenetCandidate {
            let apiKey = effectiveTorBoxAPIKey()
            guard !apiKey.isEmpty else {
                status = "TorBox API key is missing."
                return nil
            }
            let result = TorBoxUsenetSearchResult(
                hash: link.torBoxUsenetHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                rawTitle: link.title,
                normalizedTitle: link.title,
                sizeBytes: 0,
                tracker: "",
                nzbURL: link.torBoxUsenetNZBURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                age: "",
                cached: link.torBoxUsenetCached ?? false,
                owned: link.torBoxUsenetOwned ?? false,
                directPlaybackURL: link.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                ownedDownloadID: link.torBoxUsenetDownloadID
            )
            status = result.cached ? "Opening cached TorBox Usenet source…" : "TorBox is preparing this Usenet source…"
            do {
                let url = try await TorBoxUsenetClient.resolve(result, apiKey: apiKey)
                status = "TorBox Usenet source ready."
                return url
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                status = message.isEmpty ? "TorBox could not prepare this Usenet source." : message
                lastStreamMessage = status
                return nil
            }
        }

        guard let hash = link.infoHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty else { return nil }

        // vBRDC072: never route an explicitly labeled non-RD debrid result through the
        // Real-Debrid magnet resolver. Managed Torrentio should normally hand every
        // debrid provider a direct playable URL. If a third-party addon returns only a
        // hash for Premiumize/AllDebrid/TorBox/etc., leave it unresolved rather than
        // silently consuming the user's Real-Debrid account for another provider.
        if let service = link.providerService?.trimmingCharacters(in: .whitespacesAndNewlines), !service.isEmpty {
            let serviceKey = SourceIntelligenceManager.providerCanonical(service)
            let realDebridKey = SourceIntelligenceManager.providerCanonical(DebridServiceID.realDebrid.displayName)
            if serviceKey != realDebridKey {
                status = "\(service) source did not provide a direct playable link."
                lastStreamMessage = status
                return nil
            }
        }
        let resolved = await resolveRealDebridInfoHash(hash, fileIndex: link.fileIndex, displayTitle: link.title)
        return Self.makePlayableURL(from: resolved)
    }

    private func resolveRealDebridInfoHash(_ hash: String, fileIndex: Int?, displayTitle: String) async -> String? {
        let rdKey = (UserDefaults.standard.string(forKey: "realDebridApiKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rdKey.isEmpty else { return nil }
        let cleanHash = hash.replacingOccurrences(of: "magnet:?xt=urn:btih:", with: "", options: .caseInsensitive)
        let safeTitle = displayTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "DebridChannels"
        let magnet = "magnet:?xt=urn:btih:\(cleanHash)&dn=\(safeTitle)"
        guard let addURL = URL(string: "https://api.real-debrid.com/rest/1.0/torrents/addMagnet") else { return nil }
        var add = URLRequest(url: addURL, timeoutInterval: 12)
        add.httpMethod = "POST"
        add.setValue("Bearer \(rdKey)", forHTTPHeaderField: "Authorization")
        add.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        add.httpBody = "magnet=\((magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? magnet))".data(using: .utf8)
        do {
            guard let networkRequest = MediaFlowProxyRouter.forwardRequestIfAllowed(add) else { return nil }
            let (data, response) = try await URLSession.shared.data(for: networkRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            guard let added = try? JSONDecoder().decode(RealDebridAddMagnetResponse.self, from: data), let id = added.id, !id.isEmpty else { return nil }
            _ = await selectRealDebridTorrentFiles(torrentID: id, apiKey: rdKey, fileIndex: fileIndex)
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let info = await realDebridTorrentInfo(torrentID: id, apiKey: rdKey), let links = info.links, !links.isEmpty else { return nil }
            let selectedIndex: Int
            if let fileIndex, fileIndex >= 0, fileIndex < links.count { selectedIndex = fileIndex } else { selectedIndex = 0 }
            return await unrestrictRealDebridLink(links[selectedIndex], apiKey: rdKey)
        } catch {
            return nil
        }
    }

    private func selectRealDebridTorrentFiles(torrentID: String, apiKey: String, fileIndex: Int?) async -> Bool {
        guard let url = URL(string: "https://api.real-debrid.com/rest/1.0/torrents/selectFiles/\(torrentID)") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let filesValue: String
        if let fileIndex, fileIndex > 0 { filesValue = "\(fileIndex)" } else { filesValue = "all" }
        request.httpBody = "files=\(filesValue)".data(using: .utf8)
        do {
            guard let networkRequest = MediaFlowProxyRouter.forwardRequestIfAllowed(request) else { return false }
            let (_, response) = try await URLSession.shared.data(for: networkRequest)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode) || http.statusCode == 204
        } catch { return false }
    }

    private func realDebridTorrentInfo(torrentID: String, apiKey: String) async -> RealDebridTorrentInfoResponse? {
        guard let url = URL(string: "https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            guard let networkRequest = MediaFlowProxyRouter.forwardRequestIfAllowed(request) else { return nil }
            let (data, response) = try await URLSession.shared.data(for: networkRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return try? JSONDecoder().decode(RealDebridTorrentInfoResponse.self, from: data)
        } catch { return nil }
    }

    private func unrestrictRealDebridLink(_ link: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "link=\((link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link))".data(using: .utf8)
        do {
            guard let networkRequest = MediaFlowProxyRouter.forwardRequestIfAllowed(request) else { return nil }
            let (data, response) = try await URLSession.shared.data(for: networkRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let resolved = try? JSONDecoder().decode(RealDebridUnrestrictResponse.self, from: data)
            return resolved?.download
        } catch { return nil }
    }


    private func prioritizeEnglishStremioStreams(_ streams: [StremioStream]) -> [StremioStream] {
        SourceIntelligenceManager.prioritizedEnglishStreams(streams)
    }

    private func stremioEnglishPriority(_ stream: StremioStream) -> (englishRank: Int, foreignRank: Int) {
        let haystack = [
            stream.title,
            stream.name,
            stream.behaviorHints?.filename,
            stream.url,
            stream.externalUrl
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let englishMarkers = [
            " english", "eng", ".eng", "-eng", "[eng", "(eng",
            " en ", ".en.", "-en-", "[en]", "(en)", "en-us", "en-gb",
            "multi", "dual", "dual-audio", "dual audio", "🇺🇸", "🇬🇧"
        ]
        let foreignMarkers = [
            "hindi", "hin", "spanish", "latino", "castellano", " spa", ".spa", "-spa",
            "french", " fre", " fra", ".fre", ".fra", "german", " ger", " deu", ".ger", ".deu",
            "italian", " ita", ".ita", "portuguese", " por", ".por", "polish", "pldub", "lektor",
            "russian", " rus", ".rus", "ukrainian", "turkish", "japanese", " jpn", "korean", "kor",
            "tamil", "telugu", "malayalam", "arabic", "thai", "viet", "bengali", "punjabi"
        ]

        let hasEnglish = englishMarkers.contains { marker in haystack.contains(marker) }
        let hasForeign = foreignMarkers.contains { marker in haystack.contains(marker) }
        return (hasEnglish ? 0 : (hasForeign ? 2 : 1), hasForeign ? 1 : 0)
    }

    private func providerName(from rawManifest: String, manifest: StremioManifest?) -> String {
        manifest?.name ?? URL(string: rawManifest)?.host ?? rawManifest
    }

    private func providerCanonical(_ value: String) -> String {
        SourceIntelligenceManager.providerCanonical(value)
    }

    private func isKnownSourceProvider(_ value: String) -> Bool {
        SourceIntelligenceManager.isKnownProvider(value)
    }

    private func sourceProviderMatches(selection: String, provider: String, manifestURL: String) -> Bool {
        if NuvioPluginPreferences.groupProvidersByRepository(),
           NuvioPluginPreferences.providerBelongsToRepository(providerName: provider, repositoryName: selection) {
            return true
        }
        return SourceIntelligenceManager.providerMatches(selection: selection, provider: provider, manifestURL: manifestURL)
    }

    private func sourceManifestCanResolvePlayableLinks(rawManifest: String, manifestURL: URL, manifest: StremioManifest?) -> Bool {
        let canonical = providerCanonical([rawManifest, manifestURL.absoluteString, manifest?.name ?? ""].joined(separator: " "))
        if canonical.contains("cinemeta") || canonical.contains("themoviedb") || canonical == "tmdb" {
            return false
        }
        guard let manifest else { return false }
        // v830 Stremio parity: trust the manifest's advertised stream resource directly.
        // Some real addons become catalog+stream after "Load all JSON addons", and the old
        // addonKind gate could classify them as catalog-only even though Play could still resolve
        // a best stream elsewhere. Find Links must query every non-metadata addon that exposes
        // /stream so the UI and Play button use the same resolver surface.
        return (manifest.resources ?? []).contains { resource in
            resource.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stream"
        }
    }

    private func sourceProviderStatus(for provider: String) -> SourceProviderRequestStatus? {
        sourceProviderStatuses.first { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
    }

    private func upsertSourceProviderStatus(provider rawProvider: String, state: SourceProviderRequestState, linkCount: Int, message: String) {
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Provider" : rawProvider
        let status = SourceProviderRequestStatus(provider: provider, state: state, linkCount: linkCount, message: message)
        if let index = sourceProviderStatuses.firstIndex(where: { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }) {
            // vBRDC263: assigning through an @Published array subscript still emits
            // objectWillChange. Provider callbacks often repeat the exact same status while
            // another provider finishes, so reject no-op writes before touching the array.
            guard sourceProviderStatuses[index] != status else { return }
            var next = sourceProviderStatuses
            next[index] = status
            sourceProviderStatuses = next
        } else {
            var next = sourceProviderStatuses
            next.append(status)
            sourceProviderStatuses = next
        }
    }

    private func isCurrentStreamSearch(_ itemID: String) -> Bool {
        // v566 episode exact-link fix: episode rows use ids such as seriesId:season:episode
        // while selectedDetail remains the parent show id. Gating on selectedDetail?.id == itemID
        // blocks every episode stream update, leaving Source Intelligence stuck spinning.
        // activeStreamSearchItemID already prevents stale searches from overwriting newer ones.
        return activeStreamSearchItemID == itemID && selectedDetail != nil
    }

    private func clearStreamLinkState(statusMessage: String = "") {
        activeStreamSearchItemID = nil
        cancelActiveSourceProviderTasks()
        streamLinks = []
        sourceProviderStatuses = []
        alternateAudioSources = []
        selectedAlternateAudioSource = nil
        invalidatePreparedAlternateAudioBridge(message: "Bridge not prepared")
        alternateAudioSyncOffsetMS = 0
        lastStreamMessage = statusMessage
    }

    private func manifestURLCandidates(from raw: String) -> [String] {
        // v96: Accept the real-world formats people paste from Stremio/Torrentio/TorBox:
        // - https://addon/config/manifest.json
        // - https://addon/configure
        // - https://addon/configure?...
        // - stremio://addon/config/manifest.json
        // - stremio://addon/configure
        // - stremio:///addon/config/manifest.json
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var candidates: [String] = []
        func add(_ value: String) {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if trimmed.hasPrefix("stremio:///") { trimmed = "https://" + String(trimmed.dropFirst("stremio:///".count)) }
            if trimmed.hasPrefix("stremio://") { trimmed = "https://" + String(trimmed.dropFirst("stremio://".count)) }
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        let httpsClean: String
        if clean.hasPrefix("stremio:///") {
            httpsClean = "https://" + String(clean.dropFirst("stremio:///".count))
        } else if clean.hasPrefix("stremio://") {
            httpsClean = "https://" + String(clean.dropFirst("stremio://".count))
        } else {
            httpsClean = clean
        }
        let lower = httpsClean.lowercased()

        // vBRDC212: a pasted /configure URL is a human HTML page, not the protocol
        // manifest. Do not waste the first network turn decoding that page as JSON. For
        // every other shape keep the user's exact endpoint first because custom addons may
        // legitimately expose manifest JSON from a non-standard path.
        let isConfigurePage = lower.hasSuffix("/configure") || lower.contains("/configure?") || lower.contains("/configure#")
        if !isConfigurePage { add(clean) }

        // If a configured manifest URL is embedded inside a copied text/link, extract it.
        if let range = httpsClean.range(of: #"https?://[^\s"'<>]+/manifest\.json"#, options: .regularExpression) {
            add(String(httpsClean[range]))
        }

        if lower.contains("/manifest.json?") || lower.contains("/manifest.json#") {
            if let url = URL(string: httpsClean), let scheme = url.scheme, let host = url.host {
                add("\(scheme)://\(host)\(url.path)")
            }
        }

        if lower.hasSuffix("/manifest.json") {
            add(httpsClean)
            if let url = URL(string: httpsClean), let scheme = url.scheme, let host = url.host,
               host.lowercased().contains("comet") || host.lowercased().contains("torrentio") {
                add("\(scheme)://\(host)/manifest.json")
            }
        } else if lower.hasSuffix("/configure") {
            add(String(httpsClean.dropLast("/configure".count)) + "/manifest.json")
        } else if lower.contains("/configure?") || lower.contains("/configure#") {
            if let url = URL(string: httpsClean), let scheme = url.scheme, let host = url.host {
                let pathWithoutConfigure = url.path.replacingOccurrences(of: "/configure", with: "")
                if !pathWithoutConfigure.isEmpty, pathWithoutConfigure != "/" {
                    add("\(scheme)://\(host)\(pathWithoutConfigure)/manifest.json")
                }
                add("\(scheme)://\(host)/manifest.json")
            }
        } else if let url = URL(string: httpsClean), let scheme = url.scheme, let host = url.host {
            // If user pasted the configured addon base without manifest.json, try preserving its path first.
            if !url.path.isEmpty, url.path != "/" {
                add("\(scheme)://\(host)\(url.path)/manifest.json")
            }
            // Root addon fallback for links like https://torrentio.strem.fun/configure.
            add("\(scheme)://\(host)/manifest.json")
        }
        if isConfigurePage { add(clean) }
        return candidates
    }

    private func normalizedStremioBase(from manifest: String) -> String {
        var base = manifest
        if let range = base.range(of: "/manifest.json", options: [.caseInsensitive, .backwards]) {
            base = String(base[..<range.lowerBound])
        } else if let range = base.range(of: "/configure", options: [.caseInsensitive, .backwards]) {
            base = String(base[..<range.lowerBound])
        } else if base.lowercased().hasSuffix("manifest.json") {
            base.removeLast("manifest.json".count)
        }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func catalogEndpointCandidates(base: URL, catalog: StremioCatalog, skip: Int = 0) -> [URL] {
        // Stremio catalog endpoints are:
        //   /catalog/{type}/{id}.json
        //   /catalog/{type}/{id}/{extra}.json
        // where extra is optional but some addons require skip/search/genre. Try only protocol-valid forms.
        let baseString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let type = catalog.type ?? "movie"
        let id = catalog.id ?? "popular"
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        var extraCandidates: [String] = []

        func addExtra(_ extra: String?) {
            guard let extra else { return }
            let clean = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !extraCandidates.contains(clean) else { return }
            extraCandidates.append(clean)
        }

        let normalizedSkip = max(0, skip)
        // v1060: forced official reloads page long rows through the standard Stremio
        // skip extra. Ordinary browsing keeps the exact first-page candidate behavior.
        addExtra("skip=\(normalizedSkip)")
        if normalizedSkip == 0 {
            addExtra("genre=popular")
            addExtra("search=")
        }

        catalog.extraRequired?.forEach { required in
            if required.lowercased() == "skip" { addExtra("skip=\(normalizedSkip)") }
            else if normalizedSkip == 0 && required.lowercased() == "genre" { addExtra("genre=popular") }
            else if normalizedSkip == 0 && required.lowercased() == "search" { addExtra("search=") }
        }
        catalog.extra?.forEach { extra in
            let name = extra.name?.lowercased()
            if name == "skip" { addExtra("skip=\(normalizedSkip)") }
            else if normalizedSkip == 0 && name == "genre" { addExtra("genre=\((extra.options?.first ?? "popular"))") }
            else if normalizedSkip == 0 && name == "search" { addExtra("search=") }
        }

        let baseEndpoint = "\(baseString)/catalog/\(encodedType)/\(encodedID).json"
        var strings: [String] = []
        if normalizedSkip > 0,
           let endpointURL = URL(string: baseEndpoint),
           var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "skip", value: "\(normalizedSkip)")]
            if let queryURL = components.url?.absoluteString { strings.append(queryURL) }
        } else {
            strings.append(baseEndpoint)
        }
        strings.append(contentsOf: extraCandidates.map { extra in
            let encodedExtra = extra.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? extra
            return "\(baseString)/catalog/\(encodedType)/\(encodedID)/\(encodedExtra).json"
        })

        var urls: [URL] = []
        for string in strings {
            if let url = URL(string: string), !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    private func catalogSearchEndpointCandidates(base: URL, catalog: StremioCatalog, query: String) -> [URL] {
        let baseString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let type = catalog.type ?? "movie"
        let id = catalog.id ?? "popular"
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let encodedType = type.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? type
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query

        var extras: [String] = []
        func add(_ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !extras.contains(clean) else { return }
            extras.append(clean)
        }

        // Stremio search extra convention. Try query first so Search does not
        // fall back to only the first/default page of a catalog.
        add("search=\(encodedQuery)")
        add("search=\(encodedQuery)&skip=0")

        catalog.extraRequired?.forEach { required in
            if required.lowercased() == "search" { add("search=\(encodedQuery)") }
            if required.lowercased() == "skip" { add("search=\(encodedQuery)&skip=0") }
        }
        catalog.extra?.forEach { extra in
            let name = extra.name?.lowercased()
            if name == "search" { add("search=\(encodedQuery)") }
            if name == "skip" { add("search=\(encodedQuery)&skip=0") }
        }

        // v1000: support both query-parameter catalogs (our local catalog server) and
        // the Stremio path-extra convention used by Cinemeta and many JSON addons.
        var strings: [String] = []
        if let queryURL = URL(string: "\(baseString)/catalog/\(encodedType)/\(encodedID).json"),
           var components = URLComponents(url: queryURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [
                URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "skip", value: "0")
            ]
            if let value = components.url?.absoluteString { strings.append(value) }
        }
        strings.append(contentsOf: extras.map { extra in
            "\(baseString)/catalog/\(encodedType)/\(encodedID)/\(extra).json"
        })
        // Last fallback: some catalogs expose searchable/default results from the base catalog endpoint.
        strings.append("\(baseString)/catalog/\(encodedType)/\(encodedID).json")

        var urls: [URL] = []
        for string in strings {
            if let url = URL(string: string), !urls.contains(url) { urls.append(url) }
        }
        return urls
    }


    private func addonKind(from manifest: StremioManifest) -> String {
        let hasCatalogs = !(manifest.catalogs ?? []).isEmpty
        let hasStream = (manifest.resources ?? []).contains { $0.name?.lowercased() == "stream" }
        if hasCatalogs && hasStream { return "catalog+stream" }
        if hasCatalogs { return "catalog" }
        if hasStream { return "stream-only" }
        return "metadata-only"
    }

    private func expandedStreamTypes(typeCandidates: [String], manifest: StremioManifest?) -> [String] {
        // vBRDC212: never cross-query movie + series endpoints. The prior helper appended
        // both unconditionally, contradicting streamTypeCandidates(for:) and doubling the
        // foreground request count for most addons. Keep only aliases compatible with the
        // requested media kind while still honoring manifests that advertise `show`/`tv`.
        let wantsSeries = typeCandidates.contains { candidate in
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return clean == "series" || clean == "show" || clean == "tv" || clean == "episode"
        }
        func compatible(_ value: String) -> Bool {
            if wantsSeries { return value == "series" || value == "show" || value == "tv" || value == "episode" }
            return value == "movie" || value == "film"
        }
        var ordered: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty, compatible(clean), !ordered.contains(clean) else { return }
            ordered.append(clean)
        }
        typeCandidates.forEach { add($0) }
        manifest?.types?.forEach { add($0) }
        manifest?.resources?.filter { $0.name?.lowercased() == "stream" }.forEach { resource in
            resource.types?.forEach { add($0) }
        }
        if ordered.isEmpty { ordered.append(wantsSeries ? "series" : "movie") }
        return ordered
    }

    private func parsedQuality(from title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("2160") || lower.contains("4k") || lower.contains("uhd") { return "4K" }
        if lower.contains("1080") { return "1080p" }
        if lower.contains("720") { return "720p" }
        if lower.contains("480") { return "480p" }
        return "Auto"
    }

    private func parsedSizeText(from title: String) -> String? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(GB|MB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(match.range, in: title) else { return nil }
        return String(title[range])
    }

    private func findXtreamVODLinks(for item: MediaItem) async -> [StreamLink] {
        // v318: disabled. Xtream Codes is Live TV channels only for now.
        return []
    }

    private func normalizedXtreamServer(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") { value = "http://" + value }
        if value.lowercased().contains("/player_api.php") {
            value = value.replacingOccurrences(of: "/player_api.php", with: "", options: .caseInsensitive)
        }
        while value.hasSuffix("/") { value.removeLast() }
        guard URL(string: value) != nil else { return nil }
        return value
    }

    private func findXtreamMovieLinks(item: MediaItem, base: String, queryUser: String, queryPass: String, pathUser: String, pathPass: String) async -> [StreamLink] {
        // v318: disabled. Xtream Codes Movies/Shows are removed; Live TV channels only.
        return []
    }

    private func findXtreamSeriesLinks(item: MediaItem, base: String, queryUser: String, queryPass: String, pathUser: String, pathPass: String) async -> [StreamLink] {
        // v318: disabled. Xtream Codes Movies/Shows are removed; Live TV channels only.
        return []
    }

    private func fetchXtreamText(_ raw: String, maxBytes: Int) async -> String? {
        guard let url = URL(string: raw) else { return nil }
        do {
            if url.scheme?.lowercased() == "http" {
                let plain = try await PlainHTTPClient.fetchData(from: url, accept: "application/json,*/*", userAgent: "DebridChannels-tvOS/325", maxBytes: maxBytes, timeout: 45)
                guard (200...299).contains(plain.statusCode) else { return nil }
                return String(data: plain.data, encoding: .utf8)
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            guard data.count <= maxBytes else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func bestXtreamMatches(in array: [[String: Any]], for item: MediaItem, nameKeys: [String]) -> [[String: Any]] {
        let target = normalizedTitleForMatching(item.title)
        let targetYear = item.year.trimmingCharacters(in: .whitespacesAndNewlines)
        var scored: [(Int, [[String: Any]].Element)] = []
        for obj in array {
            let name = stringValue(obj, keys: nameKeys)
            let normalized = normalizedTitleForMatching(name)
            guard !normalized.isEmpty else { continue }
            var score = 0
            if normalized == target { score += 100 }
            if normalized.contains(target) || target.contains(normalized) { score += 45 }
            if !targetYear.isEmpty {
                let year = stringValue(obj, keys: ["year", "releaseDate", "releasedate"])
                if year.contains(targetYear) { score += 20 }
            }
            if score > 0 { scored.append((score, obj)) }
        }
        return scored.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    private func normalizedTitleForMatching(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanXtreamExtension(_ value: String, fallback: String) -> String {
        let clean = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". /\n\r\t"))
        guard !clean.isEmpty, clean.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else { return fallback }
        return clean
    }

    private func stringValue(_ obj: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            if let i = obj[key] as? Int { return String(i) }
        }
        return ""
    }

    private func intValue(_ obj: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let i = obj[key] as? Int { return i }
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let s = obj[key] as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return i }
        }
        return 0
    }

    func discoverAlternateAudioSources(for item: MediaItem, currentURL: URL, preferredLanguage: String = "English") async -> [AlternateAudioSource] {
        alternateAudioDiscoveryGeneration &+= 1
        let generation = alternateAudioDiscoveryGeneration
        let presentationID = playbackPresentationID
        guard StableFeatureGateManager.isEnabled(.alternateAudioMaster),
              StableFeatureGateManager.isEnabled(.alternateAudioDiscovery) else {
            alternateAudioDiscoveryState = .idle
            alternateAudioDiscoveryMessage = "Alternate Audio is Off. Turn it On before scanning."
            status = alternateAudioDiscoveryMessage
            return []
        }

        let requestID = UUID()
        alternateAudioDiscoveryRequestID = requestID
        defer {
            if alternateAudioDiscoveryRequestID == requestID { alternateAudioDiscoveryRequestID = nil }
        }
        alternateAudioSources = []
        selectedAlternateAudioSource = nil
        invalidatePreparedAlternateAudioBridge(message: "Bridge not prepared", cancelBackend: true)
        alternateAudioDiscoveryState = .preparing
        alternateAudioDiscoveryMessage = "Collecting resolved Source Intelligence candidates…"
        status = alternateAudioDiscoveryMessage

        // Preserve all provider metadata already published by Source Intelligence, then add
        // any ranked direct fallback URLs owned by this playback session. This prevents the
        // discovery panel from reporting zero merely because the visible link list was
        // compacted after playback began.
        var candidateLinks = streamLinks
        var knownURLs = Set(candidateLinks.compactMap { $0.url })
        for (index, fallbackURL) in playbackFallbackURLs.enumerated() {
            let raw = fallbackURL.absoluteString
            guard raw != currentURL.absoluteString, knownURLs.insert(raw).inserted else { continue }
            candidateLinks.append(StreamLink(
                title: fallbackURL.lastPathComponent.isEmpty ? "Ranked playback fallback \(index + 1)" : fallbackURL.lastPathComponent,
                url: raw,
                quality: "",
                size: "",
                source: "Source Intelligence playback fallback"
            ))
        }
        let directCandidates = candidateLinks.filter { link in
            guard link.isDirectPlayable, let raw = link.url, let candidate = URL(string: raw) else { return false }
            return candidate.absoluteString != currentURL.absoluteString
        }
        // vBRDC162 Universal Alternate Audio: every resolved copy is a usable on-device
        // candidate, including the copy that is already playing. This means Find English Audio
        // can still inspect/supply an English track when Source Intelligence has only one direct
        // link. Backend ffprobe classification is enrichment only; KSME owns playback selection.
        let currentRequestHeaders = playbackHTTPHeaders.map { StreamRequestHeader(name: $0.key, value: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let currentLocalCandidate = AlternateAudioSource(
            title: "Current playback copy",
            url: currentURL.absoluteString,
            quality: "",
            source: "Current playback source",
            confidence: "Local English auto-detect",
            matchClassification: AlternateAudioMatchClassification.possibleMatch.rawValue,
            audioTrackIndex: nil,
            audioCodec: nil,
            audioLanguage: "English / Auto",
            audioTrackTitle: "On-device track detection",
            durationSeconds: nil,
            startTimeSeconds: nil,
            frameRate: nil,
            edition: nil,
            chapterCount: nil,
            fingerprintSimilarity: nil,
            fingerprintStatus: "Local decoder fallback",
            rejectionReason: nil,
            releaseMetadata: nil,
            isCommentary: false,
            isDescriptiveAudio: false,
            requestHeaders: currentRequestHeaders
        )
        let alternateLocalCandidates: [AlternateAudioSource] = directCandidates.compactMap { link in
            guard let raw = link.url, URL(string: raw) != nil else { return nil }
            let cleanTitle = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanSource = link.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return AlternateAudioSource(
                title: cleanTitle.isEmpty ? "Resolved alternate copy" : link.title,
                url: raw,
                quality: link.quality,
                source: cleanSource.isEmpty ? "Source Intelligence" : link.source,
                confidence: "Local English auto-detect",
                matchClassification: AlternateAudioMatchClassification.possibleMatch.rawValue,
                audioTrackIndex: nil,
                audioCodec: nil,
                audioLanguage: "English / Auto",
                audioTrackTitle: "On-device track detection",
                durationSeconds: nil,
                startTimeSeconds: nil,
                frameRate: nil,
                edition: nil,
                chapterCount: nil,
                fingerprintSimilarity: nil,
                fingerprintStatus: "Local decoder fallback",
                rejectionReason: nil,
                releaseMetadata: nil,
                isCommentary: false,
                isDescriptiveAudio: false,
                requestHeaders: link.requestHeaders
            )
        }
        var localFallbackCandidates: [AlternateAudioSource] = [currentLocalCandidate]
        var localURLs = Set([currentURL.absoluteString])
        localFallbackCandidates.append(contentsOf: alternateLocalCandidates.filter { localURLs.insert($0.url).inserted })

        // Publish the local decoder path immediately. The ffprobe pass only upgrades track
        // labels/indexes; it is never a prerequisite for using a resolved copy.
        alternateAudioSources = localFallbackCandidates
        if let remembered = rememberedAlternateAudioSelection(for: item),
           let restored = localFallbackCandidates.first(where: { $0.url == remembered.url }) {
            selectedAlternateAudioSource = restored
            alternateAudioSyncOffsetMS = storedAlternateAudioSyncOffset(for: item, source: restored)
        }

        // With no separate alternate copy, the currently playing file can still be opened by
        // the hidden audio-only decoder and its English track selected independently.
        guard !directCandidates.isEmpty else {
            alternateAudioDiscoveryRequestID = nil
            alternateAudioDiscoveryState = .complete
            alternateAudioDiscoveryMessage = "Current playback copy ready for on-device English audio detection. No second resolved copy is required."
            status = alternateAudioDiscoveryMessage
            return localFallbackCandidates
        }

        alternateAudioDiscoveryState = .probing
        alternateAudioDiscoveryMessage = "\(localFallbackCandidates.count) resolved copy/copies ready locally • verifying English track metadata…"
        status = alternateAudioDiscoveryMessage
        let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"

        do {
            let discovered = try await AlternateAudioDiscoveryClient.discover(
                backendBaseURL: backendBaseURL,
                item: item,
                currentURL: currentURL,
                currentLabel: playbackLinkLabel,
                links: directCandidates,
                requestUUID: requestID,
                playbackPresentationID: presentationID,
                preferredLanguage: preferredLanguage,
                includeCommentary: false,
                includeDescriptiveAudio: false
            )
            guard generation == alternateAudioDiscoveryGeneration,
                  presentationID == playbackPresentationID,
                  playbackURL == currentURL,
                  StableFeatureGateManager.isEnabled(.alternateAudioMaster) else { return [] }

            // vBRDC160: discovery still validates identity/stream metadata, but playback no longer
            // asks the backend to remux a bridge. Reattach the exact request headers from the
            // Source Intelligence link so KSPlayer/FFmpeg can open the alternate copy locally.
            var enriched = discovered.map { candidate -> AlternateAudioSource in
                var copy = candidate
                if let link = directCandidates.first(where: { $0.url == candidate.url }) {
                    copy.requestHeaders = link.requestHeaders
                }
                return copy
            }
            let discoveredURLs = Set(enriched.map(\.url))
            enriched.append(contentsOf: localFallbackCandidates.filter { !discoveredURLs.contains($0.url) })
            // Keep backend classification/rejection text as an advisory diagnostic, but never
            // remove a resolved copy from the local decoder path.
            alternateAudioSources = enriched
            if let remembered = rememberedAlternateAudioSelection(for: item),
               let restored = enriched.first(where: { candidate in
                   candidate.url == remembered.url &&
                   (remembered.streamIndex == nil || candidate.audioTrackIndex == remembered.streamIndex)
               }) {
                selectedAlternateAudioSource = restored
                alternateAudioSyncOffsetMS = storedAlternateAudioSyncOffset(for: item, source: restored)
            }
            alternateAudioDiscoveryState = .complete
            let verifiedEnglish = enriched.filter { $0.audioTrackIndex != nil }
            alternateAudioDiscoveryMessage = "Scan complete. \(enriched.count) resolved copy/copies ready for local English audio • \(verifiedEnglish.count) pre-verified by ffprobe."
            status = alternateAudioDiscoveryMessage
            return enriched
        } catch is CancellationError {
            guard generation == alternateAudioDiscoveryGeneration else { return [] }
            alternateAudioDiscoveryState = .idle
            alternateAudioDiscoveryMessage = "Scan cancelled"
            status = alternateAudioDiscoveryMessage
            return []
        } catch {
            guard generation == alternateAudioDiscoveryGeneration else { return [] }
            if !localFallbackCandidates.isEmpty {
                alternateAudioSources = localFallbackCandidates
                if let remembered = rememberedAlternateAudioSelection(for: item),
                   let restored = localFallbackCandidates.first(where: { $0.url == remembered.url }) {
                    selectedAlternateAudioSource = restored
                    alternateAudioSyncOffsetMS = storedAlternateAudioSyncOffset(for: item, source: restored)
                }
                alternateAudioDiscoveryState = .complete
                alternateAudioDiscoveryMessage = "Backend probe unavailable • \(localFallbackCandidates.count) resolved copy/copies ready for on-device English audio detection."
                status = alternateAudioDiscoveryMessage
                return localFallbackCandidates
            }
            alternateAudioDiscoveryState = .failed
            alternateAudioDiscoveryMessage = "Alternate Audio discovery failed: \(error.localizedDescription)"
            status = alternateAudioDiscoveryMessage
            return []
        }
    }

    func cancelAlternateAudioDiscovery(reason: String = "Scan cancelled", notifyBackend: Bool = true) {
        alternateAudioDiscoveryGeneration &+= 1
        let requestID = alternateAudioDiscoveryRequestID
        alternateAudioDiscoveryRequestID = nil
        if alternateAudioDiscoveryState == .preparing || alternateAudioDiscoveryState == .probing {
            alternateAudioDiscoveryState = .idle
            alternateAudioDiscoveryMessage = reason
        }
        guard notifyBackend, requestID != nil else { return }
        requestAlternateAudioBackendCancellation(
            requestUUID: requestID,
            bridgeUUID: nil,
            presentationID: playbackPresentationID,
            reason: reason
        )
    }

    func recordAlternateAudioFailure(_ message: String) {
        let clean = message
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "[redacted source]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        alternateAudioFailedHandoffs.insert("\(stamp) • \(clean)", at: 0)
        if alternateAudioFailedHandoffs.count > 5 { alternateAudioFailedHandoffs.removeLast(alternateAudioFailedHandoffs.count - 5) }
    }

    func prepareAlternateAudioBridge(for item: MediaItem, currentURL: URL) async -> AlternateAudioBridgeSession? {
        alternateAudioBridgeGeneration &+= 1
        let generation = alternateAudioBridgeGeneration
        let presentationID = playbackPresentationID
        guard StableFeatureGateManager.isEnabled(.alternateAudioMaster),
              StableFeatureGateManager.isEnabled(.alternateAudioBridge) else {
            alternateAudioBridgeState = .failed
            alternateAudioBridgeMessage = "Alternate Audio is Off. Turn it On before preparing a bridge."
            status = alternateAudioBridgeMessage
            return nil
        }
        guard let source = selectedAlternateAudioSource else {
            alternateAudioBridgeState = .failed
            alternateAudioBridgeMessage = "Select an alternate audio copy first."
            status = alternateAudioBridgeMessage
            return nil
        }

        let requestID = UUID()
        alternateAudioBridgeRequestID = requestID
        defer {
            if alternateAudioBridgeRequestID == requestID { alternateAudioBridgeRequestID = nil }
        }
        if let oldBridge = preparedAlternateAudioBridge?.id {
            requestAlternateAudioBackendCancellation(
                requestUUID: nil,
                bridgeUUID: oldBridge,
                presentationID: presentationID,
                reason: "Replacing prepared Alternate Audio bridge"
            )
        }
        preparedAlternateAudioBridge = nil
        alternateAudioBridgeState = .validating
        alternateAudioBridgeMessage = "Re-validating exact media ownership and selected English stream…"
        status = alternateAudioBridgeMessage
        let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"

        do {
            alternateAudioBridgeState = .preparing
            alternateAudioBridgeMessage = "Preparing temporary HLS bridge • video stream-copy…"
            status = alternateAudioBridgeMessage
            let session = try await AlternateAudioBridgeClient.prepare(
                backendBaseURL: backendBaseURL,
                item: item,
                currentURL: currentURL,
                currentLabel: playbackLinkLabel,
                source: source,
                offsetMS: alternateAudioSyncOffsetMS,
                playbackPresentationID: presentationID,
                requestUUID: requestID
            )
            guard generation == alternateAudioBridgeGeneration,
                  presentationID == playbackPresentationID,
                  playbackURL == currentURL,
                  selectedAlternateAudioSource?.url == source.url,
                  StableFeatureGateManager.isEnabled(.alternateAudioMaster) else {
                requestAlternateAudioBackendCancellation(
                    requestUUID: nil,
                    bridgeUUID: session.id,
                    presentationID: presentationID,
                    reason: "Discarded stale Alternate Audio bridge"
                )
                return nil
            }

            preparedAlternateAudioBridge = session
            alternateAudioBridgeState = .ready
            let reuseSuffix = session.reusedExisting ? " • reused \(session.reuseKind ?? "existing") bridge" : ""
            alternateAudioBridgeMessage = "Bridge prepared • video \(session.videoMode) • audio \(session.audioMode) • ready for KSPlayer handoff\(reuseSuffix)"
            status = alternateAudioBridgeMessage
            return session
        } catch is CancellationError {
            guard generation == alternateAudioBridgeGeneration else { return nil }
            preparedAlternateAudioBridge = nil
            alternateAudioBridgeState = .idle
            alternateAudioBridgeMessage = "Bridge preparation cancelled"
            status = alternateAudioBridgeMessage
            return nil
        } catch {
            guard generation == alternateAudioBridgeGeneration else { return nil }
            preparedAlternateAudioBridge = nil
            alternateAudioBridgeState = .failed
            alternateAudioBridgeMessage = "Alternate Audio bridge failed: \(error.localizedDescription)"
            recordAlternateAudioFailure(alternateAudioBridgeMessage)
            status = alternateAudioBridgeMessage
            return nil
        }
    }

    func cancelAlternateAudioBridgePreparation(clearPrepared: Bool = false, reason: String = "Bridge preparation cancelled") {
        alternateAudioBridgeGeneration &+= 1
        let requestID = alternateAudioBridgeRequestID
        let bridgeID = clearPrepared ? preparedAlternateAudioBridge?.id : nil
        alternateAudioBridgeRequestID = nil
        if clearPrepared { preparedAlternateAudioBridge = nil }
        if alternateAudioBridgeState == .validating || alternateAudioBridgeState == .preparing || clearPrepared {
            alternateAudioBridgeState = .idle
            alternateAudioBridgeMessage = reason
        }
        if requestID != nil || bridgeID != nil {
            requestAlternateAudioBackendCancellation(
                requestUUID: requestID,
                bridgeUUID: bridgeID,
                presentationID: playbackPresentationID,
                reason: reason
            )
        }
    }

    func cancelAllAlternateAudioWork(
        presentationID: UUID? = nil,
        additionalBridgeUUID: UUID? = nil,
        clearPrepared: Bool = true,
        reason: String
    ) {
        alternateAudioDiscoveryGeneration &+= 1
        alternateAudioBridgeGeneration &+= 1
        let owner = presentationID ?? playbackPresentationID
        let discoveryRequestID = alternateAudioDiscoveryRequestID
        let bridgeRequestID = alternateAudioBridgeRequestID
        let preparedBridgeID = preparedAlternateAudioBridge?.id
        alternateAudioDiscoveryRequestID = nil
        alternateAudioBridgeRequestID = nil
        alternateAudioDiscoveryState = .idle
        alternateAudioDiscoveryMessage = StableFeatureGateManager.isEnabled(.alternateAudioMaster) ? reason : "Alternate Audio is Off"
        alternateAudioBridgeState = .idle
        alternateAudioBridgeMessage = StableFeatureGateManager.isEnabled(.alternateAudioMaster) ? reason : "Alternate Audio is Off"
        if clearPrepared { preparedAlternateAudioBridge = nil }

        // One presentation-wide cancellation kills every in-flight ffprobe/bridge job.
        // Include the prepared/active bridge UUID so its detached ffmpeg process and files
        // are also removed immediately.
        let bridgeToCancel = additionalBridgeUUID ?? preparedBridgeID
        requestAlternateAudioBackendCancellation(
            requestUUID: discoveryRequestID ?? bridgeRequestID,
            bridgeUUID: bridgeToCancel,
            presentationID: owner,
            reason: reason
        )
    }

    private func invalidatePreparedAlternateAudioBridge(message: String, cancelBackend: Bool = false) {
        alternateAudioBridgeGeneration &+= 1
        let bridgeID = preparedAlternateAudioBridge?.id
        preparedAlternateAudioBridge = nil
        alternateAudioBridgeState = .idle
        alternateAudioBridgeMessage = message
        if cancelBackend, let bridgeID {
            requestAlternateAudioBackendCancellation(
                requestUUID: nil,
                bridgeUUID: bridgeID,
                presentationID: playbackPresentationID,
                reason: message
            )
        }
    }

    func cancelAlternateAudioBridgeSession(_ bridgeUUID: UUID?, presentationID: UUID? = nil, reason: String) {
        guard let bridgeUUID else { return }
        requestAlternateAudioBackendCancellation(
            requestUUID: nil,
            bridgeUUID: bridgeUUID,
            presentationID: presentationID ?? playbackPresentationID,
            reason: reason
        )
    }

    private func requestAlternateAudioBackendCancellation(
        requestUUID: UUID?,
        bridgeUUID: UUID?,
        presentationID: UUID,
        reason: String
    ) {
        let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
        Task.detached(priority: .utility) {
            _ = await AlternateAudioCancellationClient.cancel(
                backendBaseURL: backendBaseURL,
                playbackPresentationID: presentationID,
                requestUUID: requestUUID,
                bridgeUUID: bridgeUUID,
                reason: reason
            )
        }
    }

    func selectAlternateAudioSource(_ source: AlternateAudioSource?, for item: MediaItem) {
        invalidatePreparedAlternateAudioBridge(message: "Bridge not prepared for the new candidate")
        selectedAlternateAudioSource = source
        alternateAudioSyncOffsetMS = storedAlternateAudioSyncOffset(for: item, source: source)
        saveAlternateAudioSelection(source, for: item)
        if let source {
            status = "Alternate Audio copy selected: \(source.displayTitle). Use This Audio to attach its English track locally while the current video keeps playing."
        } else {
            status = "Alternate Audio candidate cleared. Current playback remains unchanged."
        }
    }

    func adjustAlternateAudioSyncOffset(for item: MediaItem, source: AlternateAudioSource?, deltaMS: Int) {
        invalidatePreparedAlternateAudioBridge(message: "Bridge requires preparation with the updated offset")
        alternateAudioSyncOffsetMS += deltaMS
        saveAlternateAudioSyncOffset(for: item, source: source, offsetMS: alternateAudioSyncOffsetMS)
        status = "Alternate audio sync offset: \(alternateAudioSyncOffsetMS)ms."
    }

    func resetAlternateAudioSyncOffset(for item: MediaItem, source: AlternateAudioSource?) {
        invalidatePreparedAlternateAudioBridge(message: "Bridge requires preparation after offset reset")
        alternateAudioSyncOffsetMS = 0
        saveAlternateAudioSyncOffset(for: item, source: source, offsetMS: 0)
        status = "Alternate audio sync reset to 0ms."
    }

    func storedAlternateAudioSyncOffset(for item: MediaItem, source: AlternateAudioSource?) -> Int {
        UserDefaults.standard.integer(forKey: alternateAudioSyncKey(for: item, source: source))
    }

    private func saveAlternateAudioSyncOffset(for item: MediaItem, source: AlternateAudioSource?, offsetMS: Int) {
        UserDefaults.standard.set(offsetMS, forKey: alternateAudioSyncKey(for: item, source: source))
    }

    private func alternateAudioSyncKey(for item: MediaItem, source: AlternateAudioSource?) -> String {
        let sourcePart = source?.url ?? "default"
        return "smartAltAudioSyncMS|\(alternateAudioIdentityDigest(for: item))|\(stableAlternateAudioDigest(sourcePart))"
    }

    private func alternateAudioSelectionKey(for item: MediaItem) -> String {
        "smartAltAudioSelection|\(alternateAudioIdentityDigest(for: item))"
    }

    private func alternateAudioIdentityDigest(for item: MediaItem) -> String {
        let identity = [
            item.id,
            item.imdbId ?? "",
            item.tmdbId ?? "",
            item.tvdbId ?? "",
            item.type,
            item.title,
            item.year,
            item.seasonNumber.map(String.init) ?? "",
            item.episodeNumber.map(String.init) ?? ""
        ].joined(separator: "|")
        return stableAlternateAudioDigest(identity)
    }

    private func stableAlternateAudioDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func saveAlternateAudioSelection(_ source: AlternateAudioSource?, for item: MediaItem) {
        let key = alternateAudioSelectionKey(for: item)
        guard let source else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        var payload: [String: Any] = ["url": source.url]
        if let streamIndex = source.audioTrackIndex { payload["streamIndex"] = streamIndex }
        UserDefaults.standard.set(payload, forKey: key)
    }

    private func rememberedAlternateAudioSelection(for item: MediaItem) -> (url: String, streamIndex: Int?)? {
        guard let payload = UserDefaults.standard.dictionary(forKey: alternateAudioSelectionKey(for: item)),
              let url = payload["url"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let streamIndex: Int?
        if let number = payload["streamIndex"] as? NSNumber {
            streamIndex = number.intValue
        } else if let value = payload["streamIndex"] as? Int {
            streamIndex = value
        } else {
            streamIndex = nil
        }
        return (url, streamIndex)
    }


    private func balancedSourceProviderLinks(_ rankedLinks: [StreamLink], limit: Int) -> [StreamLink] {
        SourceIntelligenceManager.balancedProviderLinks(rankedLinks, limit: limit)
    }

    private func sortedStreamLinks(_ links: [StreamLink], for item: MediaItem? = nil) -> [StreamLink] {
        SourceIntelligenceManager.sortedLinks(links, for: item)
    }


    private func sourceIntelligenceEpisodeRank(_ link: StreamLink, item: MediaItem?) -> (title: Int, season: Int, episode: Int, pack: Int) {
        guard let item, let season = item.seasonNumber, let episode = item.episodeNumber else {
            return (0, 0, 0, 0)
        }
        let haystack = link.sourceIntelligenceHaystack
        let titleRank = sourceIntelligenceTitleMatches(linkTitle: haystack, itemTitle: item.title) ? 0 : 1
        let token = sourceIntelligenceEpisodeTokenState(haystack, season: season, episode: episode)
        switch token {
        case .exactEpisode:
            return (titleRank, 0, 0, 0)
        case .matchingSeasonPack:
            return (titleRank, 0, 2, 1)
        case .wrongEpisodeOrSeason:
            return (titleRank, 9, 9, 9)
        case .generic:
            return (titleRank, 1, 1, 2)
        }
    }

    private enum SourceIntelligenceEpisodeTokenState {
        case exactEpisode
        case matchingSeasonPack
        case wrongEpisodeOrSeason
        case generic
    }

    private func sourceIntelligenceTitleMatches(linkTitle: String, itemTitle: String) -> Bool {
        let needle = sourceIntelligenceCanonicalTitle(itemTitle)
        guard needle.count >= 3 else { return true }
        let haystack = sourceIntelligenceCanonicalTitle(linkTitle)
        return haystack.contains(needle)
    }

    private func sourceIntelligenceCanonicalTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\bs\d{1,2}[ ._-]*e\d{1,3}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{1,2}x\d{1,3}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sourceIntelligenceEpisodeTokenState(_ raw: String, season: Int, episode: Int) -> SourceIntelligenceEpisodeTokenState {
        let lower = raw.lowercased()
        let paddedSeason = String(format: "%02d", season)
        let paddedEpisode = String(format: "%02d", episode)
        let exactPatterns = [
            "\\bs0?\(season)[ ._-]*e0?\(episode)\\b",
            "\\b\(season)[xX]0?\(episode)\\b",
            "\\bseason[ ._-]*0?\(season)[ ._-]*episode[ ._-]*0?\(episode)\\b",
            "\\bs\(paddedSeason)e\(paddedEpisode)\\b"
        ]
        if exactPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return .exactEpisode
        }

        let packTokens = ["complete", "full season", "season pack", "season.pack", "season-pack", "pack", "complete season"]
        let hasPackToken = packTokens.contains { lower.contains($0) }
        let matchingSeasonPatterns = [
            "\\bs0?\(season)\\b",
            "\\bseason[ ._-]*0?\(season)\\b",
            "\\b0?\(season)[ ._-]*season\\b"
        ]
        let hasMatchingSeason = matchingSeasonPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
        if hasMatchingSeason && hasPackToken { return .matchingSeasonPack }

        let explicitEpisodePatterns = [
            #"\bs\d{1,2}[ ._-]*e\d{1,3}\b"#,
            #"\b\d{1,2}x\d{1,3}\b"#,
            #"\bseason[ ._-]*\d{1,2}[ ._-]*episode[ ._-]*\d{1,3}\b"#,
            #"\bepisode[ ._-]*\d{1,3}\b"#
        ]
        if explicitEpisodePatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return .wrongEpisodeOrSeason
        }
        if hasMatchingSeason { return .matchingSeasonPack }
        return .generic
    }

    private func streamTypeCandidates(for item: MediaItem) -> [String] {
        // v576: restore the fast Source Intelligence path. Do not cross-query movie
        // endpoints for shows or series endpoints for movies; that doubled requests and
        // made movies feel like they were stalled while slow addons timed out.
        if item.seasonNumber != nil && item.episodeNumber != nil { return ["series"] }
        let lower = item.type.lowercased()
        if lower.contains("series") || lower.contains("show") { return ["series"] }
        return ["movie"]
    }

    private func streamIDCandidates(for item: MediaItem) -> [String] {
        var ordered: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { return }
            ordered.append(trimmed)
        }

        // v575: exact episode endpoints first. Parent-series fallback is handled by
        // streamIDFallbackCandidates(for:) with strict S/E title filtering so
        // multi-season shows still load without showing neighboring episodes.
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            if let imdb = item.imdbId, imdb.lowercased().hasPrefix("tt") { add("\(imdb):\(season):\(episode)") }
            add(item.id)
            let parts = item.id.split(separator: ":").map(String.init)
            let exactSuffix = ":\(season):\(episode)"
            if !item.id.hasSuffix(exactSuffix) {
                if parts.count >= 1 {
                    let base = streamParentBaseID(from: item.id)
                    add("\(base):\(season):\(episode)")
                }
                if item.id.hasPrefix("tt") == false, let range = item.id.range(of: "tt[0-9]+", options: .regularExpression) {
                    add("\(String(item.id[range])):\(season):\(episode)")
                }
            }
            return ordered
        }

        if let imdb = item.imdbId, imdb.lowercased().hasPrefix("tt") { add(imdb) }
        add(item.id)
        let parts = item.id.split(separator: ":").map(String.init)
        if parts.count >= 3, parts[0].lowercased() == "tmdb" {
            add("tmdb:\(parts[2])")
            add(parts[2])
        }
        if let colon = item.id.split(separator: ":").first { add(String(colon)) }
        if item.id.hasPrefix("tt") == false, let range = item.id.range(of: "tt[0-9]+", options: .regularExpression) {
            add(String(item.id[range]))
        }
        return ordered
    }

    private func streamParentBaseID(from rawID: String) -> String {
        let parts = rawID.split(separator: ":").map(String.init)
        if parts.count >= 5, Int(parts[parts.count - 1]) != nil, Int(parts[parts.count - 2]) != nil {
            return parts.dropLast(2).joined(separator: ":")
        }
        if parts.count >= 3, parts[0].lowercased() == "tmdb" { return parts.prefix(3).joined(separator: ":") }
        return parts.first ?? rawID
    }

    private func streamIDFallbackCandidates(for item: MediaItem) -> [String] {
        // v830 Stremio parity: many addons support exact episode IDs, but some still
        // return valid episode links only from the parent series endpoint. Query parent
        // IDs as a second pass with strict title/episode filtering so Find Links does
        // not show neighboring episodes but also does not miss links Stremio shows.
        guard item.seasonNumber != nil, item.episodeNumber != nil else { return [] }
        var ordered: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { return }
            ordered.append(trimmed)
        }
        if let imdb = item.imdbId, imdb.lowercased().hasPrefix("tt") { add(imdb) }
        add(streamParentBaseID(from: item.id))
        if item.id.hasPrefix("tt") == false, let range = item.id.range(of: "tt[0-9]+", options: .regularExpression) {
            add(String(item.id[range]))
        }
        return ordered
    }

    private func streamTitleMatchesRequestedEpisode(_ title: String, item: MediaItem, requireExplicitEpisodeToken: Bool = false) -> Bool {
        guard let season = item.seasonNumber, let episode = item.episodeNumber else { return true }
        let lower = title.lowercased()
        let paddedSeason = String(format: "%02d", season)
        let paddedEpisode = String(format: "%02d", episode)
        let exactTokens = [
            "s\(paddedSeason)e\(paddedEpisode)",
            "s\(season)e\(episode)",
            "s\(paddedSeason).e\(paddedEpisode)",
            "s\(paddedSeason)-e\(paddedEpisode)",
            "s\(paddedSeason)_e\(paddedEpisode)",
            "s\(paddedSeason) ep\(paddedEpisode)",
            "s\(paddedSeason) ep \(paddedEpisode)",
            "\(season)x\(paddedEpisode)",
            "\(season)x\(episode)",
            "season \(season) episode \(episode)",
            "season.\(season).episode.\(episode)",
            "season_\(season)_episode_\(episode)"
        ]
        if exactTokens.contains(where: { lower.contains($0) }) { return true }

        // v577: reject season-wide packs for episode clicks. Some addons answer exact
        // episode endpoints with parent/season pack titles like "Show.S01.2160p".
        // Those must not appear in Source Intelligence for S01E01/S01E02/etc.
        let seasonOnlyPatterns = [
            "\\bs0?\(season)\\b",
            "\\bseason[ ._-]*0?\(season)\\b",
            "\\b0?\(season)[ ._-]*season\\b"
        ]
        for pattern in seasonOnlyPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                let packTokens = ["complete", "full season", "season pack", "season.pack", "season-pack", "pack", "complete season"]
                return packTokens.contains { lower.contains($0) }
            }
        }

        let otherEpisodePatterns = [
            #"\bs\d{1,2}[ ._-]*e\d{1,3}\b"#,
            #"\b\d{1,2}x\d{1,3}\b"#,
            #"\bseason[ ._-]*\d{1,2}[ ._-]*episode[ ._-]*\d{1,3}\b"#,
            #"\bepisode[ ._-]*\d{1,3}\b"#
        ]
        for pattern in otherEpisodePatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil { return false }
        }

        // Exact episode endpoints may return generic titles with no S/E token; keep
        // those because the request id is exact. Explicit wrong season/episode titles
        // and season-wide packs are rejected above.
        return !requireExplicitEpisodeToken
    }

    private func rebuildReadyPlaybackSources(from links: [StreamLink]) {
        readyPlaybackSourceGeneration &+= 1
        let direct = links.filter(\.isDirectPlayable)
        guard !direct.isEmpty else {
            readyPlaybackSourcesByURL = [:]
            return
        }
        let headerMap = playbackHeaderMap(from: direct)
        let allURLs = direct.compactMap { Self.makePlayableURL(from: $0.url) }
        var next: [String: ReadyPlaybackSource] = [:]
        next.reserveCapacity(direct.count)
        for link in direct {
            guard let primary = Self.makePlayableURL(from: link.url) else { continue }
            var ordered: [URL] = [primary]
            for candidate in allURLs where candidate != primary {
                if !ordered.contains(candidate) { ordered.append(candidate) }
            }
            let primaryHeaders = link.requestHeaders.playbackHTTPHeaderDictionary
            var headers = headerMap
            if !primaryHeaders.isEmpty { headers[primary.absoluteString] = primaryHeaders }
            let parsedSummary = SourceLinkMetadataParser.summary(for: link, didProbe: true)
            let preparedSummary = (SourceMediaTrackProbeCache.cachedSummary(for: link) ?? parsedSummary).merged(with: parsedSummary)
            next[primary.absoluteString] = ReadyPlaybackSource(
                primaryURL: primary,
                fallbackURLs: ordered,
                fallbackHeaders: headers,
                primaryHeaders: primaryHeaders,
                subtitles: subtitleURLs(from: link),
                adaptiveCacheHint: link.sourceIntelligenceAdaptiveCacheHint,
                sourceTrackSummary: preparedSummary,
                preparedAt: Date()
            )
        }
        readyPlaybackSourcesByURL = next
    }

    private func readyPlaybackSource(for url: URL) -> ReadyPlaybackSource? {
        guard let ready = readyPlaybackSourcesByURL[url.absoluteString],
              Date().timeIntervalSince(ready.preparedAt) < sourceLinkMemoryCacheTTL else { return nil }
        return ready
    }

    func preparedPlaybackTrackSummary(for url: URL) -> RealMediaTrackSummary? {
        readyPlaybackSource(for: url)?.sourceTrackSummary
    }

    func completePlaybackLaunchTransition(presentationID: UUID) {
        guard playbackLaunchCoverPresentationID == presentationID else { return }
        playbackLaunchCoverActive = false
        playbackLaunchCoverItem = nil
        playbackLaunchCoverPresentationID = nil
        PlaybackLaunchBenchmark.shared.finish(sessionID: presentationID)
    }

    func cancelPlaybackLaunchTransition(presentationID: UUID? = nil) {
        if let presentationID, playbackLaunchCoverPresentationID != presentationID { return }
        let owner = playbackLaunchCoverPresentationID
        playbackLaunchCoverActive = false
        playbackLaunchCoverItem = nil
        playbackLaunchCoverPresentationID = nil
        PlaybackLaunchBenchmark.shared.cancel(sessionID: owner)
    }

    func playableURLs(from links: [StreamLink], selected: StreamLink? = nil) -> [URL] {
        DebridResolverPreflightManager.playableURLs(from: links, selected: selected)
    }

    func playbackHeaderMap(from links: [StreamLink]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for link in links where link.isDirectPlayable {
            guard let url = Self.makePlayableURL(from: link.url) else { continue }
            let headers = link.requestHeaders.playbackHTTPHeaderDictionary
            if !headers.isEmpty { result[url.absoluteString] = headers }
        }
        return result
    }

    static func makePlayableURL(from raw: String?) -> URL? {
        DebridResolverPreflightManager.makePlayableURL(from: raw)
    }

    func subtitleURLs(from link: StreamLink?) -> [URL] {
        DebridResolverPreflightManager.subtitleURLs(from: link)
    }

    func presentationArtworkRestoredItem(from item: MediaItem) -> MediaItem {
        guard item.type.lowercased() != "live" else { return item }
        var restored = item
        func missing(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        let rememberedArtwork = cachedArtwork(for: item)
        if missing(restored.posterURL) { restored.posterURL = rememberedArtwork.poster }
        if missing(restored.landscapeURL) { restored.landscapeURL = rememberedArtwork.backdrop }
        if missing(restored.logoURL) { restored.logoURL = rememberedArtwork.logo }

        let candidates = [selectedDetail, playbackItem].compactMap { $0 }
        for candidate in candidates where playbackMetadataIdentityMatches(candidate, restored)
            || candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(restored.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
            if missing(restored.tmdbId) { restored.tmdbId = candidate.tmdbId }
            if missing(restored.imdbId) { restored.imdbId = candidate.imdbId }
            if missing(restored.tvdbId) { restored.tvdbId = candidate.tvdbId }
            if missing(restored.posterURL) { restored.posterURL = candidate.posterURL }
            if missing(restored.landscapeURL) { restored.landscapeURL = candidate.landscapeURL }
            if missing(restored.logoURL) { restored.logoURL = candidate.logoURL }
            if missing(restored.previewURL) { restored.previewURL = candidate.previewURL }
        }
        return restored
    }

    private func vodCastWallRestoredPlaybackItem(from item: MediaItem) -> MediaItem {
        guard item.type.lowercased() != "live" else { return item }

        // vBRDC158: use one authoritative artwork merge for Search/Favorites launch,
        // playback metadata refreshes, and overlay redraws. A later metadata object can
        // enrich a logo but can never erase one that was already known.
        var restored = presentationArtworkRestoredItem(from: item)

        guard let detail = selectedDetail else { return restored }
        let sameTitle = detail.title.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(item.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        let sameID = detail.id == item.id
        let sameSeriesEpisode = detail.id == item.id || item.id.hasPrefix(detail.id) || detail.id.hasPrefix(item.id)
        guard sameID || sameTitle || sameSeriesEpisode else { return restored }

        if restored.castMembers.isEmpty { restored.castMembers = detail.castMembers }
        if restored.cast.isEmpty { restored.cast = detail.cast }
        if restored.directors.isEmpty { restored.directors = detail.directors }
        return restored
    }

    /// Phase 8: pre-resolve the next episode without touching the current
    /// playback URL, presentation generation, visible Source Intelligence list,
    /// Alternate Audio state, or player. Only direct HTTP(S) results are retained.
    func prepareUpNextEpisodeSources(for item: MediaItem, maximumLinks: Int = 24) async -> UpNextEpisodePreparation {
        let limit = min(max(maximumLinks, 4), 40)
        var found: [StreamLink] = []
        var seen = Set<String>()

        let optionalFebBoxEnabled = UserDefaults.standard.bool(forKey: BackupStreamingClient.febBoxEnabledKey)
        let febBoxCookieForUpNext = optionalFebBoxEnabled ? BackupStreamingCredentialStore.readFebBoxCookie() : ""
        // vBRDC037: Up Next keeps the proven Xtream + Stremio/debrid fan-out, then
        // adds enabled Nuvio plugins and optional personal FebBox links.
        // Existing Xtream VOD resolution is read-only with respect to playback and can
        // contribute direct episode links before Stremio provider fan-out.
            let xtream = await findXtreamVODLinks(for: item)
            for link in xtream where link.isDirectPlayable {
                let key = [link.source, link.url ?? "", link.title].joined(separator: "|").lowercased()
                if seen.insert(key).inserted { found.append(link) }
                if found.count >= limit { break }
            }

            let typeCandidates = streamTypeCandidates(for: item)
            let exactIDs = streamIDCandidates(for: item)
            let fallbackIDs = streamIDFallbackCandidates(for: item)
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 12
            sessionConfig.timeoutIntervalForResource = 18
            sessionConfig.requestCachePolicy = .returnCacheDataElseLoad
            sessionConfig.urlCache = nil
            let session = URLSession(configuration: sessionConfig)
            defer { session.invalidateAndCancel() }

            providerLoop: for rawManifest in prioritizedManifestURLsWithMetadataFallback() {
                guard !Task.isCancelled, found.count < limit else { break }
                var manifest: StremioManifest?
                var resolvedManifestURL: URL?
                for candidate in manifestURLCandidates(from: rawManifest) {
                    guard let candidateURL = URL(string: candidate) else { continue }
                    do {
                        var request = URLRequest(url: candidateURL, timeoutInterval: 8)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("DebridChannels-tvOS/1123 UpNext", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await session.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        manifest = try JSONDecoder().decode(StremioManifest.self, from: data)
                        resolvedManifestURL = candidateURL
                        break
                    } catch {
                        continue
                    }
                }
                guard let manifestURL = resolvedManifestURL,
                      sourceManifestCanResolvePlayableLinks(rawManifest: rawManifest, manifestURL: manifestURL, manifest: manifest) else { continue }

                let base = normalizedStremioBase(from: manifestURL.absoluteString)
                let sourceName = manifest?.name ?? manifestURL.host ?? "Stremio"
                let addonTypes = expandedStreamTypes(typeCandidates: typeCandidates, manifest: manifest)
                let passes: [(ids: [String], strict: Bool)] = [(exactIDs, false), (fallbackIDs, true)].filter { !$0.ids.isEmpty }

                for type in addonTypes {
                    for pass in passes {
                        if pass.strict && found.contains(where: { $0.source == sourceName }) { continue }
                        for streamID in pass.ids {
                            guard !Task.isCancelled else { break providerLoop }
                            guard let encodedID = streamID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                                  let streamURL = URL(string: "\(base)/stream/\(type)/\(encodedID).json") else { continue }
                            do {
                                var request = URLRequest(url: streamURL, timeoutInterval: providerCanonical(sourceName + " " + rawManifest).contains("mediafusion") ? 24 : 12)
                                request.setValue("application/json", forHTTPHeaderField: "Accept")
                                request.setValue("DebridChannels-tvOS/1123 UpNext", forHTTPHeaderField: "User-Agent")
                                let (data, response) = try await session.data(for: request)
                                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                                let decoded = try JSONDecoder().decode(StremioStreamResponse.self, from: data)
                                for stream in prioritizeEnglishStremioStreams(decoded.streams ?? []) {
                                    let title = stream.title ?? stream.name ?? stream.behaviorHints?.filename ?? "Stream"
                                    guard streamTitleMatchesRequestedEpisode(title, item: item, requireExplicitEpisodeToken: pass.strict) else { continue }
                                    let rawURL = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard let rawURL, !rawURL.isEmpty else { continue }
                                    let subtitles = (stream.subtitles ?? []).compactMap { subtitle -> String? in
                                        let value = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                        return value.isEmpty ? nil : value
                                    }
                                    let size: String
                                    if let bytes = stream.behaviorHints?.videoSize, bytes > 0 {
                                        size = String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
                                    } else {
                                        size = parsedSizeText(from: title) ?? "Unknown size"
                                    }
                                    let link = StreamLink(
                                        title: title,
                                        url: rawURL,
                                        quality: parsedQuality(from: title),
                                        size: size,
                                        source: sourceName,
                                        providerService: SourceIntelligenceManager.debridServiceLabel(manifestURL: rawManifest, sourceName: sourceName, stream: stream),
                                        infoHash: stream.infoHash,
                                        fileIndex: stream.fileIdx,
                                        subtitleURLs: subtitles,
                                        requestHeaders: (stream.behaviorHints?.proxyHeaders?.request ?? [:]).map { StreamRequestHeader(name: $0.key, value: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                                        isExternalURL: false
                                    )
                                    guard link.isDirectPlayable else { continue }
                                    let key = [rawManifest, rawURL, String(stream.fileIdx ?? -1)].joined(separator: "|").lowercased()
                                    if seen.insert(key).inserted { found.append(link) }
                                    if found.count >= limit { break providerLoop }
                                }
                            } catch {
                                continue
                            }
                        }
                    }
                }
            }


        if !NuvioPluginPreferences.enabledProviderNames().isEmpty, !Task.isCancelled {
            let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
            do {
                let resolverItem = await inSResolverReadyItem(item)
                let nuvioResult = try await NuvioPluginClient.resolve(backendBaseURL: backendBaseURL, item: resolverItem)
                for link in nuvioResult.links where link.isDirectPlayable {
                    let key = ["ins", link.source, link.url ?? "", link.title].joined(separator: "|").lowercased()
                    if seen.insert(key).inserted { found.append(link) }
                    if found.count >= limit { break }
                }
            } catch {
                // Up Next source prewarming is best-effort. The main Source Intelligence
                // path reports individual In-S provider failures and timeouts to the UI.
            }
        }

        if optionalFebBoxEnabled, !febBoxCookieForUpNext.isEmpty, !Task.isCancelled {
            let backendBaseURL = UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com"
            if let febBoxLinks = try? await BackupStreamingClient.resolveFebBox(
                backendBaseURL: backendBaseURL,
                item: item,
                febboxCookie: febBoxCookieForUpNext
            ) {
                for link in febBoxLinks where link.isDirectPlayable {
                    let key = ["febbox", link.url ?? "", link.title].joined(separator: "|").lowercased()
                    if seen.insert(key).inserted { found.append(link) }
                    if found.count >= limit { break }
                }
            }
        }

        let ranked = Array(PerTitlePlaybackMemoryManager.shared.prioritizedLinks(
            for: item,
            links: sortedStreamLinks(found, for: item).filter(\.isDirectPlayable)
        ).prefix(limit))

        // Verify only the first few ranked candidates. A definite dead response is
        // rejected; an inconclusive response remains playable and is identified as
        // prepared rather than falsely reported as verified. No player state changes.
        var selectedLink: StreamLink?
        var selectedAvailability: Bool?
        for candidate in ranked.prefix(4) {
            guard !Task.isCancelled, let candidateURL = Self.makePlayableURL(from: candidate.url) else { continue }
            let availability = await quickPlaybackPreflight(url: candidateURL, headers: candidate.requestHeaders.playbackHTTPHeaderDictionary)
            if availability == false { continue }
            selectedLink = candidate
            selectedAvailability = availability
            break
        }

        let orderedRanked: [StreamLink]
        if let selectedLink {
            orderedRanked = [selectedLink] + ranked.filter { $0.id != selectedLink.id }
        } else {
            orderedRanked = ranked
        }
        let primary = selectedLink.flatMap { Self.makePlayableURL(from: $0.url) }
        let urls = playableURLs(from: orderedRanked, selected: selectedLink)
        let subtitles = subtitleURLs(from: selectedLink)
        return UpNextEpisodePreparation(
            episode: item,
            rankedLinks: orderedRanked,
            primaryURL: primary,
            primaryAvailability: selectedAvailability,
            alternateURLs: urls,
            subtitleURLs: subtitles
        )
    }

    /// v1141 Phase 15: user-invoked Source Intelligence for a Cast Explorer or
    /// Full Episode Browser playback switch. The current player is never changed here;
    /// this method only resolves and ranks direct links for the requested target.
    func phase15PreparedSwitchSources(for item: MediaItem) async -> [StreamLink] {
        // Reuse Phase 8's isolated provider fan-out instead of findStreams(for:).
        // During active VOD, the global Source Intelligence scanner is intentionally
        // frozen by VODExclusivePlaybackGate and would otherwise return the CURRENT
        // title's visible links. This isolated preparation neither publishes into
        // streamLinks nor clears Alternate Audio/current-title Source Intelligence.
        let preparation = await prepareUpNextEpisodeSources(for: item, maximumLinks: 40)
        guard !Task.isCancelled else { return [] }
        return preparation.rankedLinks.filter(\.isDirectPlayable)
    }

    /// Opens exactly the link the user selected in the Phase 15 Source Intelligence
    /// picker. A definite-dead preflight leaves the current VOD presentation untouched
    /// so another source can be chosen. Automatic fallback is armed from the remaining
    /// ranked direct links only after the selected source is accepted.
    @discardableResult
    func playPhase15SelectedDirectStream(
        for item: MediaItem,
        selected: StreamLink,
        rankedLinks: [StreamLink]
    ) async -> Bool {
        guard selected.isDirectPlayable,
              let url = Self.makePlayableURL(from: selected.url) else {
            status = "Selected source is not a direct playable HTTP(S) stream."
            return false
        }
        status = "Checking selected Source Intelligence link…"
        let availability = await quickPlaybackPreflight(url: url, headers: selected.requestHeaders.playbackHTTPHeaderDictionary)
        guard availability != false else {
            status = "Selected source appears unavailable. Choose another ranked source."
            return false
        }

        let ranked = PerTitlePlaybackMemoryManager.shared.prioritizedLinks(
            for: item,
            links: rankedLinks.filter(\.isDirectPlayable)
        )
        PerTitlePlaybackMemoryManager.shared.rememberSource(selected, for: item)
        LastPlaybackLinkCacheManager.shared.save(item: item, link: selected, url: url)
        startPlayback(
            item: item,
            url: url,
            alternates: playableURLs(from: ranked, selected: selected),
            subtitles: subtitleURLs(from: selected),
            headers: selected.requestHeaders.playbackHTTPHeaderDictionary,
            fallbackHeaders: playbackHeaderMap(from: ranked),
            label: "Phase 15 user-selected Source Intelligence stream for \(item.title): \(selected.sourceIntelligenceCacheLabel) • \(selected.sourceIntelligenceLanguageLabel) • \(selected.quality) • \(selected.size) • \(selected.source). Adaptive fallback is armed across remaining ranked direct links.",
            adaptiveCacheHint: selected.sourceIntelligenceAdaptiveCacheHint
        )
        return true
    }

    func playFirstDirectStream(for item: MediaItem) async {
        // v765: media-info PLAY now reports each safe startup step before routing into
        // the existing player. Keep playback engines, audio selection, and resolver logic untouched.
        lastStreamMessage = "Preparing Playback..."
        status = "Preparing Playback..."
        sourceIntelligenceBatchStatus = "Checking saved source…"

        // vBRDC212: auto-play no longer waits for the slowest configured provider. Start
        // the normal Source Intelligence wave, then consume the first ranked direct result
        // it publishes. Cached repeat-title links can win on the first actor turn; a healthy
        // foreground provider can win milliseconds later while slower addons are still racing.
        let searchTask = Task { @MainActor [weak self] in
            guard let self else { return [StreamLink]() }
            return await self.findStreams(for: item)
        }
        for _ in 0..<60 {
            if Task.isCancelled {
                searchTask.cancel()
                return
            }
            await Task.yield()
            let earlyVisible = streamLinks
            let earlyDirect = PerTitlePlaybackMemoryManager.shared.prioritizedLinks(
                for: item,
                links: earlyVisible.filter { $0.isDirectPlayable }
            )
            if let direct = earlyDirect.first, let url = Self.makePlayableURL(from: direct.url) {
                lastStreamMessage = "Opening Player..."
                status = "Opening Player..."
                sourceIntelligenceBatchStatus = "Fast source ready."
                PerTitlePlaybackMemoryManager.shared.rememberSource(direct, for: item)
                LastPlaybackLinkCacheManager.shared.save(item: item, link: direct, url: url)
                startPlayback(
                    item: item,
                    url: url,
                    alternates: playableURLs(from: earlyVisible, selected: direct),
                    subtitles: subtitleURLs(from: direct),
                    headers: direct.requestHeaders.playbackHTTPHeaderDictionary,
                    fallbackHeaders: playbackHeaderMap(from: earlyVisible),
                    label: "Fast-started best available Source Intelligence stream for \(item.title): \(direct.sourceIntelligenceCacheLabel) • \(direct.sourceIntelligenceLanguageLabel) • \(direct.quality) • \(direct.size) • \(direct.source).",
                    adaptiveCacheHint: direct.sourceIntelligenceAdaptiveCacheHint
                )
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let links = await searchTask.value
        lastStreamMessage = links.isEmpty ? "Finding Best Available Source..." : "Finding Best Available Source... \(links.count) source(s) ready."
        status = lastStreamMessage
        sourceIntelligenceBatchStatus = "Testing best available source…"

        let directLinks = PerTitlePlaybackMemoryManager.shared.prioritizedLinks(for: item, links: links.filter { $0.isDirectPlayable })
        var definiteDeadCount = 0
        for direct in directLinks {
            guard let url = Self.makePlayableURL(from: direct.url) else { continue }
            lastStreamMessage = direct.providerDisplay.localizedCaseInsensitiveContains("real") || direct.source.localizedCaseInsensitiveContains("real-debrid")
                ? "Resolving Real-Debrid..."
                : "Preparing Best Available Source..."
            status = lastStreamMessage
            sourceIntelligenceBatchStatus = "Testing stream…"

            let availability = await quickPlaybackPreflight(url: url, headers: direct.requestHeaders.playbackHTTPHeaderDictionary)
            if availability == false {
                definiteDeadCount += 1
                lastStreamMessage = "This source appears unavailable. Trying another source..."
                status = lastStreamMessage
                continue
            }

            lastStreamMessage = "Opening Player..."
            status = "Opening Player..."
            PerTitlePlaybackMemoryManager.shared.rememberSource(direct, for: item)
            LastPlaybackLinkCacheManager.shared.save(item: item, link: direct, url: url)
            startPlayback(item: item, url: url, alternates: playableURLs(from: links, selected: direct), subtitles: subtitleURLs(from: direct), headers: direct.requestHeaders.playbackHTTPHeaderDictionary, fallbackHeaders: playbackHeaderMap(from: links), label: "Auto-selected best Source Intelligence stream for \(item.title): \(direct.sourceIntelligenceCacheLabel) • \(direct.sourceIntelligenceLanguageLabel) • \(direct.quality) • \(direct.size) • \(direct.source). Adaptive fallback is armed across all ranked direct links.", adaptiveCacheHint: direct.sourceIntelligenceAdaptiveCacheHint)
            return
        }

        if let preview = directPreviewURL(for: item) {
            // v84 real-player test path: when a catalog has no direct movie links yet, PLAY still opens
            // the custom Debrid player with the direct preview/sample URL so the full VOD surface can be tested.
            lastStreamMessage = "Opening Player..."
            status = "Opening Player..."
            startPlayback(item: item, url: preview, alternates: [], subtitles: [], label: "No resolved VOD link found, opening direct preview stream in the custom Debrid player for testing.")
        } else {
            let torrentCount = links.filter { $0.url?.lowercased().hasPrefix("magnet:") == true || $0.infoHash != nil }.count
            let externalCount = links.filter { $0.isExternalURL }.count
            if definiteDeadCount > 0 && directLinks.count == definiteDeadCount {
                status = "No playable sources found. Open Source Intelligence?"
                lastStreamMessage = status
            } else {
                status = links.isEmpty ? lastStreamMessage : "Links found, but none are direct-playable yet. \(torrentCount) torrent/infoHash and \(externalCount) browser/external link(s) need a configured debrid direct stream URL from the addon."
                lastStreamMessage = status
            }
        }
    }

    private func quickPlaybackPreflight(url: URL, headers: [String: String] = [:]) async -> Bool? {
        // vBRDC016: when MediaFlow is enabled, even the tiny availability probe must
        // originate from the configured home proxy. A direct preflight from the remote
        // Apple TV would expose a second public IP before the actual proxied playback.
        // vBRDC089: carry the selected provider context into the MediaFlow wrapper too,
        // so any future real preflight cannot falsely reject a protected stream.
        if MediaFlowProxyRouter.configurationError(kind: .vod) != nil { return false }
        guard let networkURL = MediaFlowProxyRouter.playbackURLIfAllowed(for: url, kind: .vod, upstreamHeaders: headers) else { return false }
        return await DebridResolverPreflightManager.quickPlaybackPreflight(url: networkURL)
    }

    /// Build 31 single-owner barrier. Every path that replaces a playback URL or
    /// presentation identity retires the outgoing decoder/audio/render owner BEFORE
    /// publishing the incoming identity. This covers ordinary tuning, experimental
    /// handoffs, rollback, automatic source failover and explicit close.
    private func retirePlaybackPresentation(
        _ presentationID: UUID,
        reason: String,
        cancelAlternateAudio: Bool = true
    ) {
        if cancelAlternateAudio {
            cancelAllAlternateAudioWork(
                presentationID: presentationID,
                additionalBridgeUUID: preparedAlternateAudioBridge?.id,
                clearPrepared: true,
                reason: reason
            )
        }
        _ = AuxiliaryVideoPlaybackCoordinator.shared.releaseAll(reason: reason)

        guard PlaybackController.shared.ownsSession(presentationID) else { return }
        PlaybackController.shared.beginPresentationDismissal(sessionID: presentationID)
        PlaybackController.shared.suspendRenderHost(sessionID: presentationID)
        PlaybackController.shared.detachRenderHost(sessionID: presentationID)
        PlaybackController.shared.stop(sessionID: presentationID)
    }

    func startPlayback(item: MediaItem, url: URL, alternates: [URL] = [], subtitles: [URL] = [], headers: [String: String] = [:], fallbackHeaders: [String: [String: String]] = [:], label: String, sourceTrackSummary: RealMediaTrackSummary? = nil, adaptiveCacheHint: String = "") {
        // vBRDC226 defense in depth: playback itself enforces membership, not only UI routing.
        // A stale focus node or delayed tap can therefore never start Live TV/VOD after lock.
        guard !MembershipEntitlementManager.isCurrentDeviceLocked() else {
            status = "Membership required. Open Membership to continue."
            selectedTab = .membership
            catalogRowsPresented = false
            liveQuickPanelOpen = false
            topMenuSelectionHoldTab = nil
            topMenuFocusLocked = false
            contentFocusToken &+= 1
            return
        }
        cancelFocusedCardPreviewDiskStage()
        // Publish a new launch identity before the URL so SwiftUI cannot reuse a departing
        // VOD screen when the user selects the same link again.
        let previousPresentationID = playbackPresentationID
        let replacingActivePlayback = playbackURL != nil
        // Build 31: a new tune/source is an exclusive playback handoff. Stop the previous
        // PlaybackKit render/audio owner synchronously before publishing a new session ID.
        // This prevents stale KSPlayer/Aether hosts from remaining audible underneath the
        // replacement stream (the reported doubled/quadrupled voices on repeated Live TV/VOD tunes).
        if replacingActivePlayback {
            retirePlaybackPresentation(
                previousPresentationID,
                reason: item.type.lowercased() == "live" ? "Live TV retune replaced previous playback" : "VOD source replaced previous playback"
            )
        }
        let nextPresentationID = UUID()
        playbackPresentationID = nextPresentationID
        AuxiliaryVideoPlaybackCoordinator.shared.releaseAll(reason: item.type.lowercased() == "live" ? "Live TV playback" : "full-screen VOD playback")
        beginVODExclusivePlaybackIfNeeded(for: item)
        playbackItem = vodCastWallRestoredPlaybackItem(from: item)

        // vBRDC138: Bluetooth/headset transport ownership follows the authoritative
        // playback session rather than SwiftUI PlayerScreen appearance. Replacing one VOD
        // with another atomically claims the new UUID with no onDisappear gap. Live TV
        // explicitly releases any prior VOD owner and never inherits this command bridge.
        if item.type.lowercased() == "live" {
            BluetoothVODMediaButtonCoordinator.shared.releaseVODSession(previousPresentationID)
            // vBRDC210: claim system media-button eligibility BEFORE playbackURL mounts the
            // Live TV decoder. The full channel/program metadata is published by the player
            // surface, but remote commands and the non-mixable audio category must already
            // be active when playback starts.
            BluetoothVODMediaButtonCoordinator.shared.claimLiveControlSession(
                nextPresentationID,
                title: item.title
            )
        } else {
            BluetoothVODMediaButtonCoordinator.shared.claimVODSession(
                nextPresentationID,
                title: item.title,
                duration: 0,
                elapsed: 0,
                isPlaying: true
            )
        }
        let ready = readyPlaybackSource(for: url)
        PlaybackLaunchBenchmark.shared.begin(sessionID: nextPresentationID, title: item.title)
        if ready != nil {
            PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "ready-source cache hit")
        } else {
            PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "ready-source cache miss")
        }

        let ordered = ready?.fallbackURLs ?? ([url] + alternates).reduce(into: [URL]()) { acc, candidate in
            if !acc.contains(candidate) { acc.append(candidate) }
        }
        playbackFallbackURLs = ordered
        // vBRDC229: the ordinary Source Intelligence path arrives here with this map
        // already shaped by rebuildReadyPlaybackSources. Legacy/direct callers retain
        // their explicit fallbackHeaders without another scan through streamLinks.
        var resolvedFallbackHeaders = ready?.fallbackHeaders ?? fallbackHeaders
        let primaryHeaders = !headers.isEmpty ? headers : (ready?.primaryHeaders ?? [:])
        if !primaryHeaders.isEmpty { resolvedFallbackHeaders[url.absoluteString] = primaryHeaders }
        playbackFallbackHTTPHeaders = resolvedFallbackHeaders
        playbackHTTPHeaders = primaryHeaders.isEmpty ? (resolvedFallbackHeaders[url.absoluteString] ?? [:]) : primaryHeaders
        PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "fallback/header plan ready")
        automaticSourceFailoverContext = nil
        originalPlaybackURL = url
        experimentalPlaybackURL = nil
        activeExperimentalPlaybackFeature = nil
        experimentalPlaybackHandoffID = nil
        experimentalPlaybackOwnerPresentationID = nil
        playbackSubtitleURLs = subtitles.isEmpty ? (ready?.subtitles ?? []) : subtitles
        playbackLinkLabel = label
        playbackAdaptiveCacheHint = adaptiveCacheHint.isEmpty ? (ready?.adaptiveCacheHint ?? "") : adaptiveCacheHint
        playbackSourceTrackSummary = sourceTrackSummary ?? ready?.sourceTrackSummary

        if item.type.lowercased() != "live" {
            playbackLaunchCoverItem = playbackItem
            playbackLaunchCoverPresentationID = nextPresentationID
            playbackLaunchCoverActive = true
            PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "continuous artwork cover armed")
        }

        // Publish the URL as soon as the launch-critical source contract is complete.
        // Journal I/O/status work is deliberately moved to the next main-queue turn.
        playbackURL = url
        PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "playback URL published")
        status = label
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.playbackPresentationID == nextPresentationID,
                  self.playbackURL == url else { return }
            PlaybackSessionTerminationJournal.begin(
                item: item,
                selectedURL: url,
                label: label,
                fallbackCount: ordered.count
            )
            PlaybackLaunchBenchmark.shared.mark(sessionID: nextPresentationID, "session journal deferred")
        }
    }

    /// Phase 0 entry point for future experimental playback handoffs. The method is
    /// fail-closed: the versioned feature must be enabled, a stable session must exist,
    /// and the original URL is captured before the first experimental replacement.
    @discardableResult
    func beginExperimentalPlaybackHandoff(
        to experimentalURL: URL,
        feature: StableFeatureGateManager.Feature,
        reason: String
    ) -> UUID? {
        guard feature.isPlaybackFeature,
              StableFeatureGateManager.isEnabled(feature),
              playbackItem != nil,
              playbackURL != nil else {
            print("[StableProtection][Phase0] rejected disabled experimental handoff feature=\(feature.rawValue)")
            return nil
        }

        if originalPlaybackURL == nil { originalPlaybackURL = playbackURL }
        let handoffID = UUID()
        experimentalPlaybackHandoffID = handoffID
        activeExperimentalPlaybackFeature = feature
        experimentalPlaybackURL = experimentalURL
        playbackHTTPHeaders = playbackFallbackHTTPHeaders[experimentalURL.absoluteString] ?? [:]
        let outgoingPresentationID = playbackPresentationID
        retirePlaybackPresentation(outgoingPresentationID, reason: "Experimental playback handoff replaced active source")
        playbackPresentationID = UUID()
        experimentalPlaybackOwnerPresentationID = playbackPresentationID
        playbackURL = experimentalURL
        status = reason
        print("[StableProtection][Phase0] experimental handoff started feature=\(feature.rawValue) id=\(handoffID)")
        return handoffID
    }

    /// Phase 4 in-place bridge handoff. The stable root playback URL and presentation
    /// identity remain unchanged while the VOD-owned KSPlayer surface changes source.
    /// This preserves overlay/focus state and still gives every bridge generation a
    /// unique ownership token for stale-callback rejection and emergency rollback.
    @discardableResult
    func beginSessionOwnedExperimentalPlaybackHandoff(
        to experimentalURL: URL,
        feature: StableFeatureGateManager.Feature,
        presentationID: UUID,
        reason: String
    ) -> UUID? {
        guard feature.isPlaybackFeature,
              StableFeatureGateManager.isEnabled(feature),
              playbackItem != nil,
              playbackURL != nil,
              playbackPresentationID == presentationID else {
            print("[StableProtection][Phase4] rejected session-owned handoff feature=\(feature.rawValue) presentation=\(presentationID)")
            return nil
        }

        if originalPlaybackURL == nil { originalPlaybackURL = playbackURL }
        let handoffID = UUID()
        experimentalPlaybackHandoffID = handoffID
        experimentalPlaybackOwnerPresentationID = presentationID
        activeExperimentalPlaybackFeature = feature
        experimentalPlaybackURL = experimentalURL
        status = reason
        print("[StableProtection][Phase4] session-owned handoff started feature=\(feature.rawValue) id=\(handoffID) presentation=\(presentationID)")
        return handoffID
    }

    func sessionOwnedExperimentalPlaybackHandoffIsCurrent(
        _ handoffID: UUID,
        presentationID: UUID,
        experimentalURL: URL
    ) -> Bool {
        experimentalPlaybackHandoffID == handoffID &&
        experimentalPlaybackOwnerPresentationID == presentationID &&
        playbackPresentationID == presentationID &&
        self.experimentalPlaybackURL == experimentalURL &&
        playbackURL != nil
    }

    func completeSessionOwnedExperimentalPlaybackHandoff(
        _ handoffID: UUID,
        presentationID: UUID,
        reason: String
    ) {
        guard experimentalPlaybackHandoffID == handoffID,
              experimentalPlaybackOwnerPresentationID == presentationID,
              playbackPresentationID == presentationID else { return }
        status = reason
        print("[StableProtection][Phase4] session-owned handoff active id=\(handoffID)")
    }

    func clearSessionOwnedExperimentalPlaybackHandoff(
        _ handoffID: UUID?,
        presentationID: UUID,
        reason: String
    ) {
        guard playbackPresentationID == presentationID else { return }
        if let handoffID, experimentalPlaybackHandoffID != handoffID { return }
        experimentalPlaybackHandoffID = nil
        experimentalPlaybackOwnerPresentationID = nil
        activeExperimentalPlaybackFeature = nil
        experimentalPlaybackURL = nil
        status = reason
        print("[StableProtection][Phase4] session-owned handoff cleared presentation=\(presentationID)")
    }

    /// Rejects callbacks owned by an older experimental bridge/player generation.
    func experimentalPlaybackHandoffIsCurrent(_ handoffID: UUID) -> Bool {
        experimentalPlaybackHandoffID == handoffID && playbackURL == experimentalPlaybackURL
    }

    /// Restores the exact user-selected source without ending the playback session.
    @discardableResult
    func restoreOriginalPlayback(reason: String) -> URL? {
        guard let originalPlaybackURL else { return nil }
        experimentalPlaybackHandoffID = nil
        experimentalPlaybackOwnerPresentationID = nil
        activeExperimentalPlaybackFeature = nil
        experimentalPlaybackURL = nil
        if playbackURL != originalPlaybackURL {
            let outgoingPresentationID = playbackPresentationID
            retirePlaybackPresentation(outgoingPresentationID, reason: "Restored original playback source")
            playbackPresentationID = UUID()
            playbackHTTPHeaders = playbackFallbackHTTPHeaders[originalPlaybackURL.absoluteString] ?? [:]
            playbackURL = originalPlaybackURL
        }
        status = reason
        print("[StableProtection][Phase0] original playback restored")
        return originalPlaybackURL
    }

    /// One-call kill switch for unrecoverable experimental playback failures.
    @discardableResult
    func emergencyRollbackExperimentalPlayback(reason: String) -> URL? {
        let disabledCount = StableFeatureGateManager.disableExperimentalPlaybackFeatures()
        StableFeatureGateManager.recordEmergencyPlaybackRollback(reason: reason)
        let restored = restoreOriginalPlayback(reason: "Experimental playback disabled — restored original source.")
        print("[StableProtection][Phase0] emergency rollback disabled=\(disabledCount) restored=\(restored != nil) reason=\(String(reason.prefix(160)))")
        return restored
    }

    func automaticSourceFailoverContext(for presentationID: UUID) -> AutomaticSourceFailoverContext? {
        guard let context = automaticSourceFailoverContext,
              context.targetPresentationID == presentationID else { return nil }
        return context
    }

    /// Phase 6 startup-only source recovery. The caller must prove that the session has
    /// never reached a stable first frame. This method repeats that check as an explicit
    /// argument, rejects stale callbacks, advances only through the existing ranked URL
    /// list, cancels any Alternate Audio work owned by the failed video source, and keeps
    /// the exact playback item/episode identity intact.
    @discardableResult
    func beginAutomaticSourceFailover(
        after failedURL: URL,
        resumeSeconds: Double,
        failureReason: String,
        hasStableFirstFrame: Bool
    ) -> AutomaticSourceFailoverContext? {
        guard !hasStableFirstFrame,
              let item = playbackItem,
              item.type.lowercased() != "live",
              playbackURL == failedURL,
              activeExperimentalPlaybackFeature == nil,
              experimentalPlaybackURL == nil,
              let nextCandidate = AutomaticSourceFailoverPolicy.nextCandidate(
                after: failedURL,
                in: playbackFallbackURLs
              ) else { return nil }

        let oldPresentationID = playbackPresentationID
        cancelAllAlternateAudioWork(
            presentationID: oldPresentationID,
            additionalBridgeUUID: preparedAlternateAudioBridge?.id,
            clearPrepared: true,
            reason: "Video source changed during automatic startup failover."
        )
        retirePlaybackPresentation(
            oldPresentationID,
            reason: "Automatic source failover retired failed decoder",
            cancelAlternateAudio: false
        )
        experimentalPlaybackHandoffID = nil
        experimentalPlaybackOwnerPresentationID = nil
        activeExperimentalPlaybackFeature = nil
        experimentalPlaybackURL = nil

        let targetPresentationID = UUID()
        let reason = AutomaticSourceFailoverPolicy.compactFailureReason(failureReason)

        // vBRDC229: startup failover is still part of the same visual launch. Keep the
        // original media artwork cover mounted while the replacement source/decoder is
        // prepared, but transfer ownership to the new immutable presentation ID so a
        // failed first source can never expose a black/intermediate player frame.
        let shouldCarryLaunchCover = playbackLaunchCoverActive && playbackLaunchCoverPresentationID == oldPresentationID
        if shouldCarryLaunchCover {
            PlaybackLaunchBenchmark.shared.cancel(sessionID: oldPresentationID)
            playbackLaunchCoverPresentationID = targetPresentationID
            PlaybackLaunchBenchmark.shared.begin(sessionID: targetPresentationID, title: item.title)
            PlaybackLaunchBenchmark.shared.mark(sessionID: targetPresentationID, "automatic source failover cover carried forward")
        }

        let context = AutomaticSourceFailoverContext(
            failedURL: failedURL,
            replacementURL: nextCandidate.url,
            targetPresentationID: targetPresentationID,
            attempt: nextCandidate.index,
            availableFallbacks: max(0, playbackFallbackURLs.count - 1),
            resumeSeconds: max(0, resumeSeconds.isFinite ? resumeSeconds : 0),
            failureReason: reason
        )

        if let matchedLink = streamLinks.first(where: { link in
            Self.makePlayableURL(from: link.url) == nextCandidate.url
        }) {
            let labelParts = [matchedLink.title, matchedLink.quality, matchedLink.size, matchedLink.source]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            playbackLinkLabel = "Automatic failover: " + labelParts.joined(separator: " • ")
            playbackAdaptiveCacheHint = matchedLink.sourceIntelligenceAdaptiveCacheHint
            playbackSubtitleURLs = subtitleURLs(from: matchedLink)
            // Never carry codec/track facts from the failed source into the replacement.
            playbackSourceTrackSummary = nil
        } else {
            playbackLinkLabel = "Automatic failover to ranked source \(nextCandidate.index + 1)"
            playbackAdaptiveCacheHint = ""
            playbackSourceTrackSummary = nil
        }

        playbackHTTPHeaders = playbackFallbackHTTPHeaders[nextCandidate.url.absoluteString] ?? [:]
        automaticSourceFailoverContext = context
        originalPlaybackURL = nextCandidate.url
        playbackPresentationID = targetPresentationID
        playbackURL = nextCandidate.url
        status = "\(AutomaticSourceFailoverContext.notice) • attempt \(context.attempt) of \(context.availableFallbacks)"
        print("[AutomaticFailover][Phase6] \(context.diagnosticSummary)")
        return context
    }

    func completeAutomaticSourceFailover(presentationID: UUID) {
        guard automaticSourceFailoverContext?.targetPresentationID == presentationID else { return }
        automaticSourceFailoverContext = nil
        status = "Automatic source recovery completed — stable first frame reached."
    }

    func closePlayer(expectedPresentationID: UUID? = nil, expectedURL: URL? = nil) {
        // v1054: a delayed dismissal owned by link A must never clear a newer link B.
        if let expectedPresentationID, playbackPresentationID != expectedPresentationID {
            print("[VODHandoff][v1054] ignored stale close request expected=\(expectedPresentationID) active=\(playbackPresentationID)")
            return
        }
        if let expectedURL, playbackURL != expectedURL {
            print("[VODHandoff][v1054] ignored stale close URL expected=\(expectedURL.absoluteString) active=\(playbackURL?.absoluteString ?? "nil")")
            return
        }
        // Build 31: an explicit close owns decoder/audio teardown too. Do not rely on a
        // later SwiftUI onDisappear to silence a player that may survive long enough to
        // overlap the next Live TV/VOD tune.
        retirePlaybackPresentation(playbackPresentationID, reason: "Playback closed")
        PlaybackSessionTerminationJournal.endNormally()
        // A dismissal before first frame must never strand the root-level cinematic
        // launch cover above the returning catalog. This is presentation-owned, so a
        // stale outgoing screen cannot clear a newer playback launch.
        cancelPlaybackLaunchTransition(presentationID: playbackPresentationID)

        // vBRDC138: this is the authoritative end of a VOD playback session. Release
        // headset/Now Playing ownership here, not from the SwiftUI screen's onDisappear,
        // so view remounts and ordered dismissal cannot accidentally strand media buttons.
        BluetoothVODMediaButtonCoordinator.shared.releaseVODSession(playbackPresentationID)

        // v992: release the process-wide VOD gate and artwork-exclusive mode before
        // publishing playbackURL=nil. @Published emits objectWillChange before the
        // assignment, so ending exclusivity first guarantees that the catalog render/focus
        // tree never remounts while interaction guards still believe playback is active.
        endVODExclusivePlaybackIfNeeded()

        // vBRDC078: publish the catalog remount from a neutral interaction state. A VOD
        // resolver/loading label must never survive the player and leave the returning
        // catalog believing another modal owner still controls interaction.
        isLoading = false
        sourceIntelligenceBatchStatus = ""
        topMenuFocusLocked = false
        // vBRDC142: publish a one-shot Live TV artwork remount generation before playbackURL
        // becomes nil. The rebuilt LiveTVScreen can therefore distinguish a real movie/show
        // return from cold/covered catalog startup and restore only its bounded visible artwork
        // corridor without waking provider/XMLTV refresh work behind Movies/Shows.
        if let closingItem = playbackItem, closingItem.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "live" {
            liveTVPostVODArtworkRecoveryGeneration &+= 1
        }
        playbackURL = nil
        originalPlaybackURL = nil
        experimentalPlaybackURL = nil
        activeExperimentalPlaybackFeature = nil
        experimentalPlaybackHandoffID = nil
        experimentalPlaybackOwnerPresentationID = nil
        playbackItem = nil
        playbackFallbackURLs = []
        playbackHTTPHeaders = [:]
        playbackFallbackHTTPHeaders = [:]
        automaticSourceFailoverContext = nil
        playbackSubtitleURLs = []
        playbackLinkLabel = ""
        playbackAdaptiveCacheHint = ""
        playbackSourceTrackSummary = nil
        ReleaseStabilityMemoryAuditManager.shared.markVODClosed()
        topMenuFocusLocked = false
        contentFocusToken &+= 1
        if liveTVFocusSnapshot != nil {
            liveTVFocusRestoreToken &+= 1
        }
    }

    /// v992 lifecycle reconciliation for tvOS foreground returns and any interrupted
    /// player dismissal. This is intentionally idempotent and only runs when no player
    /// URL is active. It repairs a stale VOD gate/artwork-exclusive state and emits a
    /// fresh focus token so the visible catalog rail can reclaim remote focus.
    func recoverCatalogInteractivity(reason: String) {
        guard playbackURL == nil else { return }

        let hadStaleExclusiveState = vodExclusivePlaybackActive || VODExclusivePlaybackGate.isActive
        if hadStaleExclusiveState {
            VODExclusivePlaybackGate.end()
            rotateSourceIntelligenceURLSession()
            PremiumRemoteImageLoader.endExclusivePlayback()
            vodExclusivePlaybackActive = false
            isLoading = false
            sourceIntelligenceBatchStatus = ""
            print("[CatalogRecovery][v992] cleared stale VOD-exclusive state reason=\(reason)")
        } else {
            // Safe even when already inactive; protects against an artwork-loader flag
            // surviving a scene suspension independently of the CatalogStore boolean.
            PremiumRemoteImageLoader.endExclusivePlayback()
        }

        if topMenuSelectionHoldTab == selectedTab {
            topMenuFocusLocked = false
            print("[CatalogRecovery][vBRDC129] preserved selected top-menu focus reason=\(reason)")
            return
        }
        topMenuFocusLocked = false
        contentFocusToken &+= 1
        print("[CatalogRecovery][v992] focus recovery token=\(contentFocusToken) reason=\(reason)")
    }

    // vBRDC040: In-S providers require TMDB identity. Many Cinemeta/Stremio rows
    // are IMDb-first, so recover the TMDB ID through the same existing TMDB identity
    // resolver used by Details instead of silently returning "requires a TMDB ID".
    private func inSResolverReadyItem(_ item: MediaItem) async -> MediaItem {
        if let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tmdb.isEmpty {
            return item
        }
        let parts = item.id.split(separator: ":").map(String.init)
        if parts.count >= 3, parts[0].lowercased() == "tmdb", !parts[2].isEmpty {
            var copy = item
            copy.tmdbId = parts[2]
            return copy
        }
        let configuredKey = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environmentKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = configuredKey.isEmpty ? environmentKey : configuredKey
        guard !key.isEmpty, let target = await tmdbTargetForCredits(item, apiKey: key) else { return item }
        var copy = item
        copy.tmdbId = target.id
        if copy.tvdbId == nil, let tvdb = target.tvdbID { copy.tvdbId = String(tvdb) }
        return copy
    }

    // vBRDC040: restore the pre-MovieBox two-stage catalog artwork contract.
    // Focus keeps the fast catalog/Stremio/TMDB row image. Clicking a title performs one
    // detail-only premium artwork lookup and may swap to Fanart/TVDB/alternate TMDB after
    // the new image is ready. The chosen detail URL is never written into catalog rows or
    // CatalogArtworkCacheManager, otherwise the two presentation stages collapse again.
    private func detailPremiumArtworkCacheKey(for item: MediaItem) -> String {
        let canonical = canonicalCatalogIdentityKey(for: item)
        return canonical.isEmpty ? item.id : canonical
    }

    private func normalizedArtworkURL(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func backendPremiumDetailBackdrops(for item: MediaItem, excluding currentURL: String) async -> [String] {
        let configuredBase = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = configuredBase.isEmpty ? "https://api.skylinejay187.it.com" : configuredBase
        guard var components = URLComponents(string: "\(base)/api/artwork/resolve") else { return [] }
        let mediaType = normalizedStremioType(item.type) == "series" ? "tv" : "movie"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "title", value: item.title),
            URLQueryItem(name: "type", value: mediaType),
            URLQueryItem(name: "proxyImages", value: "0")
        ]
        if let imdb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            query.append(URLQueryItem(name: "imdbId", value: imdb))
        }
        if let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tmdb.isEmpty {
            query.append(URLQueryItem(name: "tmdbId", value: tmdb))
        }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty {
            query.append(URLQueryItem(name: "tvdbId", value: tvdb))
        }
        components.queryItems = query
        guard let endpoint = components.url else { return [] }

        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 10)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/vBRDC075 DetailArtworkPool", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            guard data.count <= 2_000_000,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pool = root["artworkPool"] as? [String: Any] else { return [] }

            struct Candidate {
                let url: String
                let source: String
                let pixels: Int
            }
            var candidates: [Candidate] = []
            for bucket in ["backdrops", "landscape"] {
                guard let values = pool[bucket] as? [[String: Any]] else { continue }
                for value in values {
                    let url = String(describing: value["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("http://") else { continue }
                    let source = String(describing: value["source"] ?? "").lowercased()
                    let width = value["width"] as? Int ?? Int((value["width"] as? NSNumber)?.intValue ?? 0)
                    let height = value["height"] as? Int ?? Int((value["height"] as? NSNumber)?.intValue ?? 0)
                    candidates.append(Candidate(url: url, source: source, pixels: max(0, width) * max(0, height)))
                }
            }
            let current = normalizedArtworkURL(currentURL)
            var seen = Set<String>()
            return candidates
                .filter { !$0.url.isEmpty && $0.url != current && seen.insert($0.url).inserted }
                .sorted { lhs, rhs in
                    func priority(_ source: String) -> Int {
                        if source.contains("fanart") { return 0 }
                        if source.contains("tvdb") { return 1 }
                        if source.contains("tmdb") { return 2 }
                        return 3
                    }
                    let lp = priority(lhs.source), rp = priority(rhs.source)
                    if lp != rp { return lp < rp }
                    if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
                    return lhs.url < rhs.url
                }
                .map(\.url)
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func directFanartDetailBackdrops(for item: MediaItem, excluding currentURL: String) async -> [String] {
        let fanartKey = fanartTVApiKey()
        guard !fanartKey.isEmpty else { return [] }

        let kind = normalizedStremioType(item.type)
        let isTV = kind == "series" || kind == "tv" || item.seasonNumber != nil || item.episodeNumber != nil
        var tmdbID = item.tmdbId.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var tvdbID = item.tvdbId.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        // Use IDs already carried by the catalog item first. Only consult TMDB identity
        // resolution when the provider-specific ID we actually need is missing. This lets
        // a saved Fanart.tv key work even when the user did not also save a TMDB key.
        if (isTV && tvdbID == nil) || (!isTV && tmdbID == nil) {
            let configuredKey = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let environmentKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tmdbKey = configuredKey.isEmpty ? environmentKey : configuredKey
            if !tmdbKey.isEmpty, let target = await tmdbTargetForCredits(item, apiKey: tmdbKey) {
                if tmdbID == nil { tmdbID = Int(target.id) }
                if tvdbID == nil { tvdbID = target.tvdbID }
            }
        }

        let fanartID: String
        let endpoint: String
        if isTV {
            guard let tvdbID, tvdbID > 0 else { return [] }
            fanartID = String(tvdbID)
            endpoint = "tv"
        } else {
            guard let tmdbID, tmdbID > 0 else { return [] }
            fanartID = String(tmdbID)
            endpoint = "movies"
        }

        guard let encodedKey = fanartKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://webservice.fanart.tv/v3/\(endpoint)/\(fanartID)?api_key=\(encodedKey)") else { return [] }
        do {
            var request = URLRequest(url: url, timeoutInterval: 9)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/vBRDC075 DetailFanartPool", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard data.count <= 4_000_000,
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return [] }

            let images: [FanartTVImage]
            if isTV {
                images = try JSONDecoder().decode(FanartTVResponse.self, from: data).showbackground ?? []
            } else {
                images = try JSONDecoder().decode(FanartMovieResponse.self, from: data).moviebackground ?? []
            }
            let current = normalizedArtworkURL(currentURL)
            var seen = Set<String>()
            return images
                .sorted { lhs, rhs in
                    let lhsLang = (lhs.lang ?? "").lowercased()
                    let rhsLang = (rhs.lang ?? "").lowercased()
                    let lhsEnglish = lhsLang == "en" || lhsLang.isEmpty
                    let rhsEnglish = rhsLang == "en" || rhsLang.isEmpty
                    if lhsEnglish != rhsEnglish { return lhsEnglish && !rhsEnglish }
                    return lhs.likeScore > rhs.likeScore
                }
                .compactMap { Self.highest($0.url?.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty && $0 != current && seen.insert($0).inserted }
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func tmdbPremiumDetailBackdrops(for item: MediaItem, excluding currentURL: String) async -> [String] {
        let configuredKey = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environmentKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = configuredKey.isEmpty ? environmentKey : configuredKey
        guard !key.isEmpty,
              let target = await tmdbTargetForCredits(item, apiKey: key) else { return [] }
        guard let endpoint = URL(string: "https://api.themoviedb.org/3/\(target.kind)/\(target.id)/images?api_key=\(key)&include_image_language=en,null") else { return [] }
        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 9)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/vBRDC075 DetailTMDBArtworkPool", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            let decoded = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            let current = normalizedArtworkURL(currentURL)
            var seen = Set<String>()
            return (decoded.backdrops ?? []).compactMap { image -> (url: String, pixels: Int, votes: Int, score: Double)? in
                guard let path = image.file_path, !path.isEmpty else { return nil }
                let url = "https://image.tmdb.org/t/p/original\(path)"
                guard url != current, seen.insert(url).inserted else { return nil }
                return (url, max(0, image.width ?? 0) * max(0, image.height ?? 0), image.vote_count ?? 0, image.vote_average ?? 0)
            }.sorted { lhs, rhs in
                if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
                if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
                return lhs.score > rhs.score
            }.map(\.url)
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private func resolvePremiumDetailBackdropPool(for item: MediaItem) async -> [String] {
        let current = normalizedArtworkURL(item.landscapeURL ?? item.posterURL)
        async let fanart = directFanartDetailBackdrops(for: item, excluding: current)
        async let backend = backendPremiumDetailBackdrops(for: item, excluding: current)
        async let tmdb = tmdbPremiumDetailBackdrops(for: item, excluding: current)
        let (fanartResults, backendResults, tmdbResults) = await (fanart, backend, tmdb)

        // Interleave provider pools instead of draining one provider first. Reopening the
        // same Media Information card therefore visibly rotates across Fanart/backend
        // (including TVDB) and TMDB alternatives when those providers have candidates.
        let pools = [fanartResults, backendResults, tmdbResults]
        var ordered: [String] = []
        let maxCount = pools.map(\.count).max() ?? 0
        if maxCount > 0 {
            for index in 0..<maxCount {
                for pool in pools where index < pool.count {
                    ordered.append(pool[index])
                }
            }
        }
        var seen = Set<String>()
        return ordered.filter { url in
            let clean = normalizedArtworkURL(url)
            guard !clean.isEmpty, clean != current else { return false }
            return seen.insert(clean).inserted
        }
    }

    private func nextPremiumDetailBackdrop(forKey key: String, pool: [String]) -> String? {
        guard !pool.isEmpty else { return nil }
        let cursor = detailPremiumBackdropRotationCursor[key, default: 0]
        let index = cursor % pool.count
        detailPremiumBackdropRotationCursor[key] = (index + 1) % pool.count
        return pool[index]
    }

    private func schedulePremiumDetailArtwork(for item: MediaItem, generation: UInt64) {
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        detailPremiumBackdropURL = nil
        guard detailPresentationOrigin == .catalog else { return }

        let cacheKey = detailPremiumArtworkCacheKey(for: item)
        if let cachedPool = detailPremiumBackdropSessionCache[cacheKey], !cachedPool.isEmpty {
            detailPremiumBackdropURL = nextPremiumDetailBackdrop(forKey: cacheKey, pool: cachedPool)
            return
        }

        detailPremiumArtworkTask = VODExclusiveWorkRegistry.start(allowDuringExclusivePlayback: playbackUnityBrowseActive) { [weak self] in
            guard let self else { return }
            let pool = await self.resolvePremiumDetailBackdropPool(for: item)
            guard !Task.isCancelled,
                  generation == self.detailOpenGeneration,
                  self.detailPresentationOrigin == .catalog,
                  let current = self.selectedDetail,
                  self.catalogItemsShareCanonicalIdentity(current, item),
                  !pool.isEmpty else { return }
            self.detailPremiumBackdropSessionCache[cacheKey] = pool
            self.detailPremiumBackdropURL = self.nextPremiumDetailBackdrop(forKey: cacheKey, pool: pool)
            print("[DetailArtwork][vBRDC075] alternate detail pool ready for \(item.title): \(pool.count) candidate(s)")
        }
    }

    func openDetail(
        _ item: MediaItem,
        pushCurrent: Bool = false,
        origin: DetailPresentationOrigin? = nil
    ) {
        guard playbackUnityBrowseInteractionAllowed else { return }

        // v1154 central invariant: a real live/M3U channel is never VOD content. Any UI
        // that accidentally routes a type="live" card through openDetail is corrected
        // here before Media Information can mount. This protects Sports automatic rows,
        // manually assigned channels, and future live-channel surfaces from Find Links.
        if item.type.lowercased() == "live",
           let raw = item.previewURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let liveURL = URL(string: raw) {
            clearSportsPresentationStateForNavigation(reason: "Direct live openDetail bypass")
            startPlayback(
                item: item,
                url: liveURL,
                alternates: [],
                subtitles: [],
                label: "Direct live channel: \(item.title) • bypassed VOD Media Information"
            )
            return
        }
        if let origin {
            detailPresentationOrigin = origin
        } else if !pushCurrent {
            detailPresentationOrigin = .catalog
        }
        detailOpenGeneration &+= 1
        detailPresentationRevision &+= 1
        detailPresentationAnchorItem = item
        let generation = detailOpenGeneration
        detailCreditsTask?.cancel()
        detailCreditsTask = nil
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        detailPremiumBackdropURL = nil
        if selectedDetail?.id != item.id {
            clearStreamLinkState()
        }
        if pushCurrent, let current = selectedDetail {
            detailBackStack.append(current)
        } else if !pushCurrent {
            detailBackStack.removeAll()
        }
        // vBRDC092: MediaInfoPopup already has a revision+media identity, so clearing
        // selectedDetail for one run-loop is no longer needed for anti-stale artwork. That
        // old gap briefly re-enabled the catalog/top-menu focus graph between the card tap
        // and popup mount, producing a visible focus/artwork flash. Publish the new detail
        // identity atomically, then hydrate richer metadata in place.
        catalogDetailDismissalFocusHandoffPrepared = false
        selectedDetail = item
        schedulePremiumDetailArtwork(for: item, generation: generation)
        hydrateCreditsForOpenDetail(item, generation: generation)
    }

    private func hydrateCreditsForOpenDetail(_ item: MediaItem, generation: UInt64) {
        guard playbackUnityBrowseInteractionAllowed else { return }
        detailCreditsTask?.cancel()
        detailCreditsTask = VODExclusiveWorkRegistry.start(allowDuringExclusivePlayback: playbackUnityBrowseActive) { [weak self] in
            guard let self else { return }
            guard let enriched = await self.detailItemWithCredits(for: item),
                  !Task.isCancelled,
                  generation == self.detailOpenGeneration,
                  self.playbackUnityBrowseInteractionAllowed else { return }
            guard let current = self.selectedDetail,
                  self.catalogItemsShareCanonicalIdentity(current, item) else { return }
            self.selectedDetail = enriched
            // vBRDC040: do not overwrite detailPresentationAnchorItem with hydrated
            // TMDB/Stremio artwork. It is the immutable originating row image that the
            // anti-flash handoff holds underneath the detail-only premium backdrop.
            if let index = self.detailBackStack.lastIndex(where: { self.catalogItemsShareCanonicalIdentity($0, item) }) {
                self.detailBackStack[index] = enriched
            }
        }
    }

    private func detailItemWithCredits(for item: MediaItem) async -> MediaItem? {
        // v996: Details and VOD share the same layered metadata authority: current item,
        // Cinemeta/Stremio fallback, TMDB artwork/overview, and TMDB credits. This prevents
        // a title from having rich metadata in one screen and placeholders in another.
        var enriched = await playbackMetadata(for: item)

        // v616: Only show Explore the Franchise when TMDB confirms this movie belongs
        // to a real collection. Never use same-genre/popular fallback rows here.
        if let collectionItems = await tmdbCollectionItemsForDetail(enriched), !collectionItems.isEmpty {
            enriched.franchiseItems = collectionItems
        }

        // v1040: franchise metadata is independent from credits. A collection result
        // must not stop cast hydration and leave the Cast Wall empty until relaunch.
        if !enriched.cast.isEmpty || !enriched.castMembers.isEmpty {
            return enriched
        }

        let type = normalizedStremioType(item.type)
        let idCandidates = streamIDCandidates(for: item)
        for rawManifest in prioritizedManifestURLsWithMetadataFallback() {
            for candidate in manifestURLCandidates(from: rawManifest) {
                guard let manifestURL = URL(string: candidate) else { continue }
                let base = normalizedStremioBase(from: manifestURL.absoluteString)
                for mediaID in idCandidates {
                    guard let encodedID = mediaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let metaURL = URL(string: "\(base)/meta/\(type)/\(encodedID).json") else { continue }
                    do {
                        var request = URLRequest(url: metaURL, timeoutInterval: 8)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("DebridChannels-tvOS/469 CreditsHydration", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        let decoded = try JSONDecoder().decode(StremioMetaResponse.self, from: data)
                        guard let meta = decoded.meta else { continue }
                        let cast = Array((meta.cast ?? []).prefix(8))
                        let directors = Array((meta.directors ?? []).prefix(3))
                        guard !cast.isEmpty || !directors.isEmpty else { continue }
                        enriched.cast = cast
                        enriched.directors = directors
                        if enriched.castMembers.isEmpty {
                            enriched.castMembers = cast.map { CastMember(name: $0, role: nil, imageURL: nil) }
                        }
                        return enriched
                    } catch {
                        continue
                    }
                }
            }
        }
        return enriched == item ? nil : enriched
    }


    /// vBRDC157: reconstruct Search-only favorites whose profile restore retained the
    /// authoritative favorite identity but came from an older backup that had no MediaItem
    /// snapshot payload. This method is read-only with respect to catalogs and playback.
    func rehydrateFavoriteMediaItem(fromFavoriteKey rawKey: String) async -> MediaItem? {
        let parts = rawKey.split(separator: "::", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }

        // vBRDC159: favorites created by older builds used `itemID::catalog::type`.
        // v157/v158 accidentally interpreted the first component as an identity *kind*,
        // so a restore could retain the favorite key yet be unable to rebuild the title.
        // Recognize the modern schema explicitly and translate every other 3-part key as
        // the legacy schema before attempting network hydration.
        let modernKinds = Set(["imdb", "tmdb", "tvdb", "id", "title"])
        let first = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLower = first.lowercased()
        let isModernKey = modernKinds.contains(firstLower)
        let type = normalizedStremioType(parts[2])
        let identityKind: String
        let identityValue: String
        if isModernKey {
            identityKind = firstLower
            identityValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let legacyID = first
            let legacyLower = legacyID.lowercased()
            if legacyLower.hasPrefix("tt") {
                identityKind = "imdb"
                identityValue = legacyID
            } else if legacyLower.hasPrefix("tmdb:") {
                identityKind = "tmdb"
                identityValue = legacyID.split(separator: ":").last.map(String.init) ?? legacyID
            } else if legacyLower.hasPrefix("tvdb:") {
                identityKind = "tvdb"
                identityValue = legacyID.split(separator: ":").last.map(String.init) ?? legacyID
            } else {
                identityKind = "id"
                identityValue = legacyID
            }
        }
        guard !identityValue.isEmpty else { return nil }

        func itemFromCinemeta(_ meta: StremioMeta, fallbackID: String) -> MediaItem? {
            let title = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return MediaItem(
                id: meta.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (meta.id ?? fallbackID) : fallbackID,
                tmdbId: meta.tmdbId,
                imdbId: meta.imdbId,
                tvdbId: meta.tvdbId,
                title: title,
                year: Self.firstYear(from: meta.releaseInfo),
                type: meta.type ?? type,
                catalog: "Favorite Restore",
                description: meta.description ?? "",
                genres: Array((meta.genres ?? []).prefix(4)),
                rating: meta.imdbRating ?? "",
                posterURL: Self.highest(meta.poster),
                landscapeURL: Self.highest(meta.background ?? meta.poster),
                logoURL: Self.highest(meta.logo),
                previewURL: Self.previewURL(from: meta),
                addonName: "Cinemeta",
                addonIconURL: nil,
                cast: Array((meta.cast ?? []).prefix(8)),
                directors: Array((meta.directors ?? []).prefix(3))
            )
        }

        func cinemetaDirect(_ mediaID: String) async -> MediaItem? {
            let typeCandidates = [type, type == "series" ? "movie" : "series"]
            for candidateType in typeCandidates {
                guard let encoded = mediaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(candidateType)/\(encoded).json") else { continue }
                do {
                    var request = URLRequest(url: url, timeoutInterval: 7)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/vBRDC157 FavoriteRestore", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    guard let meta = try JSONDecoder().decode(StremioMetaResponse.self, from: data).meta,
                          var rebuilt = itemFromCinemeta(meta, fallbackID: mediaID) else { continue }
                    if let tmdb = await tmdbMetadataFallbackForDetail(rebuilt) {
                        rebuilt = mergePlaybackMetadata(base: rebuilt, candidate: tmdb)
                    }
                    return rebuilt
                } catch {
                    continue
                }
            }
            return nil
        }

        if identityKind == "imdb" || (identityKind == "id" && identityValue.lowercased().hasPrefix("tt")) {
            return await cinemetaDirect(identityValue)
        }

        // A legacy favorite may use a Cinemeta/Stremio id that is already directly
        // fetchable even though it has no imdb/tmdb prefix. Try that before degrading an
        // opaque provider id into a text-search query.
        if identityKind == "id", let rebuilt = await cinemetaDirect(identityValue) {
            return rebuilt
        }

        if identityKind == "tvdb" {
            if let rebuilt = await cinemetaDirect("tvdb:\(identityValue)") { return rebuilt }
        }

        var tmdbIdentity: String? = identityKind == "tmdb" ? identityValue : nil
        if identityKind == "id", identityValue.lowercased().hasPrefix("tmdb-") {
            tmdbIdentity = identityValue.split(separator: "-").last.map(String.init)
        }
        if let tmdbIdentity, let tmdbID = Int(tmdbIdentity) {
            let key = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = type == "series" ? "tv" : "movie"
            if !key.isEmpty, let url = URL(string: "https://api.themoviedb.org/3/\(kind)/\(tmdbID)?api_key=\(key)&language=en-US") {
                do {
                    var request = URLRequest(url: url, timeoutInterval: 7)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("DebridChannels-tvOS/vBRDC157 FavoriteRestoreTMDB", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        let result = try JSONDecoder().decode(TMDBListItem.self, from: data)
                        let title = (kind == "tv" ? result.name : result.title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !title.isEmpty {
                            let date = kind == "tv" ? result.first_air_date : result.release_date
                            let logo = await tmdbLogoURL(id: result.id, mediaType: kind, apiKey: key)
                            return MediaItem(
                                id: "tmdb:\(kind == "tv" ? "series" : "movie"):\(result.id)",
                                tmdbId: String(result.id),
                                title: title,
                                year: date.map { String($0.prefix(4)) } ?? "",
                                type: type,
                                catalog: "Favorite Restore",
                                description: result.overview ?? "",
                                genres: [],
                                rating: (result.vote_average ?? 0) > 0 ? String(format: "%.1f", result.vote_average ?? 0) : "",
                                posterURL: result.poster_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                                landscapeURL: result.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                                logoURL: logo
                            )
                        }
                    }
                } catch {
                    // Fall through to the text/id recovery below.
                }
            }
        }

        let query: String
        let year: String
        if identityKind == "title" {
            if let range = identityValue.range(of: #"-(19|20)\d{2}$"#, options: .regularExpression) {
                year = String(identityValue[range]).replacingOccurrences(of: "-", with: "")
                query = String(identityValue[..<range.lowerBound]).replacingOccurrences(of: "-", with: " ")
            } else {
                year = ""
                query = identityValue.replacingOccurrences(of: "-", with: " ")
            }
        } else {
            year = ""
            query = identityValue.replacingOccurrences(of: "-", with: " ")
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanQuery.count >= 2 else { return nil }
        let seed = MediaItem(
            id: identityValue,
            title: cleanQuery,
            year: year,
            type: type,
            catalog: "Favorite Restore",
            description: "",
            genres: [],
            rating: "",
            posterURL: nil,
            landscapeURL: nil,
            logoURL: nil
        )
        guard var matched = await cinemetaSearchMatch(for: seed, fallbackQuery: cleanQuery) else { return nil }
        if let tmdb = await tmdbMetadataFallbackForDetail(matched) {
            matched = mergePlaybackMetadata(base: matched, candidate: tmdb)
        }
        return matched
    }

    /// v996 authoritative metadata hydration for full-screen VOD. Unlike detail-row
    /// hydration, this method is allowed to run while VOD Exclusive Mode is active because
    /// it owns only one small result object and never remounts catalog rows or artwork rails.
    func playbackMetadata(for item: MediaItem) async -> MediaItem {
        let cacheKey = playbackMetadataCacheKey(for: item)
        var enriched = item
        let hadCachedMetadata = playbackMetadataCache[cacheKey] != nil
        if let cached = playbackMetadataCache[cacheKey] {
            enriched = mergePlaybackMetadata(base: enriched, candidate: cached)
        }

        // vBRDC157: merge the currently hydrated Search/Favorites detail BEFORE the old
        // completed-credits cache shortcut. Previously a cast-complete cache could return
        // here first and discard a clearlogo that Media Information had just resolved.
        if let selectedDetail, playbackMetadataIdentityMatches(selectedDetail, item) {
            enriched = mergePlaybackMetadata(base: enriched, candidate: selectedDetail)
        }
        if let playbackItem, playbackMetadataIdentityMatches(playbackItem, item) {
            enriched = mergePlaybackMetadata(base: enriched, candidate: playbackItem)
        }
        if hadCachedMetadata {
            // v1040: a description/artwork-only cache entry is not a completed credits
            // result. Continue through the lightweight metadata providers until cast or
            // director data is available; force-closing the app is no longer required.
            let isEpisode = enriched.seasonNumber != nil || enriched.episodeNumber != nil
            // Episode caches from older builds may contain an addon availability date.
            // Always continue to the exact episode endpoint before publishing a date.
            if playbackMetadataHasCast(enriched) && !isEpisode {
                // vBRDC159: cast-complete is not presentation-complete for the themed VOD
                // overlay. Search/Favorites titles frequently arrive with credits cached but
                // no clearlogo. Keep the lightweight provider pass alive until title artwork
                // is also known (or no metadata provider can add anything).
                let hasLogo = !(enriched.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let rememberedLogo = !(cachedArtwork(for: enriched).logo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if hasLogo || rememberedLogo {
                    return presentationArtworkRestoredItem(from: enriched)
                }
            }
        }

        // Cinemeta/Stremio metadata works without a TMDB key and is the first universal
        // fallback for catalog items, search results, and exact episode IDs.
        if let stremio = await stremioMetadataForPlayback(enriched) {
            enriched = mergePlaybackMetadata(base: enriched, candidate: stremio)
        }

        // TMDB remains the premium artwork/overview/credits enrichment path when configured.
        if let tmdb = await tmdbMetadataFallbackForDetail(enriched) {
            enriched = mergePlaybackMetadata(base: enriched, candidate: tmdb)
        }

        // v1104: parent-series metadata must never supply the episode date shown in
        // VOD or the connected media profile. Resolve the exact season/episode now.
        if enriched.seasonNumber != nil || enriched.episodeNumber != nil {
            enriched = await exactEpisodeMetadataForPresentation(enriched)
        }

        if let credits = await tmdbCreditsForDetail(enriched) {
            if !credits.castMembers.isEmpty { enriched.castMembers = credits.castMembers }
            if !credits.cast.isEmpty { enriched.cast = credits.cast }
            if !credits.directors.isEmpty { enriched.directors = credits.directors }
        }

        let restored = presentationArtworkRestoredItem(from: enriched)
        if restored != item {
            // vBRDC159: every playback metadata wave ends by re-applying the strongest
            // remembered artwork identity. A provider response that omits clearlogo must
            // never erase the Search/Favorites logo already learned under an alias ID.
            cacheArtwork(for: restored, poster: restored.posterURL, backdrop: restored.landscapeURL, logo: restored.logoURL)
            rememberPlaybackMetadata(restored, forKey: cacheKey)
        }
        return restored
    }

    private func playbackMetadataHasCast(_ item: MediaItem) -> Bool {
        !item.castMembers.isEmpty || !item.cast.isEmpty
    }

    private func playbackMetadataCacheKey(for item: MediaItem) -> String {
        canonicalCatalogIdentityKey(for: item)
    }

    private func playbackMetadataIdentityMatches(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        catalogItemsShareCanonicalIdentity(lhs, rhs)
    }

    private func mergePlaybackMetadata(base: MediaItem, candidate: MediaItem) -> MediaItem {
        var merged = base
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func isMissingDescription(_ value: String) -> Bool {
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lower.isEmpty || lower.contains("no description") || lower.contains("metadata is still loading")
        }

        if clean(merged.tmdbId) == nil { merged.tmdbId = clean(candidate.tmdbId) }
        if clean(merged.imdbId) == nil { merged.imdbId = clean(candidate.imdbId) }
        if clean(merged.tvdbId) == nil { merged.tvdbId = clean(candidate.tvdbId) }
        if merged.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !candidate.year.isEmpty { merged.year = candidate.year }
        if isMissingDescription(merged.description), !isMissingDescription(candidate.description) { merged.description = candidate.description }
        if !candidate.genres.isEmpty { merged.genres = candidate.genres }
        if (merged.rating.isEmpty || merged.rating == "—" || merged.rating == "0"), !candidate.rating.isEmpty { merged.rating = candidate.rating }
        if let value = clean(candidate.posterURL) { merged.posterURL = value }
        if let value = clean(candidate.landscapeURL) { merged.landscapeURL = value }
        if let value = clean(candidate.logoURL) { merged.logoURL = value }
        if let value = clean(candidate.previewURL), clean(merged.previewURL) == nil { merged.previewURL = value }
        if !candidate.cast.isEmpty { merged.cast = candidate.cast }
        if !candidate.directors.isEmpty { merged.directors = candidate.directors }
        if !candidate.castMembers.isEmpty { merged.castMembers = candidate.castMembers }

        // Only exact episode candidates may replace the air date. This prevents a
        // parent-series premiere date or an addon availability timestamp from being
        // presented as the selected episode's release date.
        let sameEpisode = candidate.seasonNumber == merged.seasonNumber
            && candidate.episodeNumber == merged.episodeNumber
            && candidate.seasonNumber != nil
            && candidate.episodeNumber != nil
        if sameEpisode, let exactAirDate = clean(candidate.airDateString) {
            merged.airDateString = exactAirDate
            let exactDates = ([exactAirDate] + candidate.episodeDateStrings)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniquedPreservingOrder()
            merged.episodeDateStrings = exactDates
        }
        return merged
    }

    // v1104: shared exact episode hydration used by the connected media profile and
    // the full-screen VOD overlay. TMDB is preferred; TVMaze is a key-free fallback.
    func exactEpisodeMetadataForPresentation(_ item: MediaItem) async -> MediaItem {
        guard let season = item.seasonNumber, let episode = item.episodeNumber, season > 0, episode > 0 else { return item }

        if let tmdb = await tmdbExactEpisodeMetadata(item, season: season, episode: episode) {
            return mergePlaybackMetadata(base: item, candidate: tmdb)
        }

        var lookupItem = item
        lookupItem.title = Self.parentSeriesTitleForEpisodeLookup(item.title)
        let tvMazeEpisodes = await fetchTVMazeEpisodesForAlerts(for: lookupItem)
        if let exact = tvMazeEpisodes.first(where: { ($0.seasonNumber ?? 0) == season && ($0.episodeNumber ?? 0) == episode }) {
            var candidate = item
            candidate.seasonNumber = season
            candidate.episodeNumber = episode
            candidate.airDateString = exact.airDateString
            candidate.episodeDateStrings = exact.episodeDateStrings
            if !exact.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { candidate.description = exact.description }
            if let still = exact.landscapeURL ?? exact.posterURL, !still.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate.landscapeURL = still
            }
            return mergePlaybackMetadata(base: item, candidate: candidate)
        }
        return item
    }

    private static func parentSeriesTitleForEpisodeLookup(_ rawTitle: String) -> String {
        var value = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s+[sS]\d{1,2}[eE]\d{1,3}.*$"#,
            #"\s+[sS]eason\s*\d{1,2}.*$"#,
            #"\s+\d{1,2}x\d{1,3}.*$"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawTitle : value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tmdbExactEpisodeMetadata(_ item: MediaItem, season: Int, episode: Int) async -> MediaItem? {
        let configuredKey = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environmentKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = configuredKey.isEmpty ? environmentKey : configuredKey
        guard !key.isEmpty, let target = await tmdbTargetForCredits(item, apiKey: key), target.kind == "tv" else { return nil }
        guard let url = URL(string: "https://api.themoviedb.org/3/tv/\(target.id)/season/\(season)/episode/\(episode)?api_key=\(key)&language=en-US") else { return nil }

        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/1104 ExactEpisodeDate", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let detail = try JSONDecoder().decode(TMDBEpisodeDetail.self, from: data)
            guard detail.season_number == nil || detail.season_number == season,
                  detail.episode_number == nil || detail.episode_number == episode else { return nil }
            let exactDate = detail.air_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !exactDate.isEmpty else { return nil }

            var updated = item
            updated.seasonNumber = season
            updated.episodeNumber = episode
            updated.airDateString = exactDate
            updated.episodeDateStrings = [exactDate]
            if updated.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let overview = detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                updated.description = overview
            }
            if let still = detail.still_path, !still.isEmpty {
                updated.landscapeURL = "https://image.tmdb.org/t/p/original\(still)"
            }
            if (updated.rating.isEmpty || updated.rating == "—" || updated.rating == "0"),
               let vote = detail.vote_average, vote > 0 {
                updated.rating = String(format: "%.1f", vote)
            }
            return updated
        } catch {
            return nil
        }
    }

    private func stremioMetadataForPlayback(_ item: MediaItem) async -> MediaItem? {
        let type = (item.seasonNumber != nil || item.episodeNumber != nil) ? "series" : normalizedStremioType(item.type)
        var ids: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ids.contains(trimmed) else { return }
            ids.append(trimmed)
        }

        // Parent-series IDs must precede exact episode IDs for metadata endpoints.
        if item.seasonNumber != nil || item.episodeNumber != nil {
            add(item.imdbId)
            add(item.tmdbId.map { "tmdb:\($0)" })
            add(streamParentBaseID(from: item.id))
            for value in streamIDFallbackCandidates(for: item) { add(value) }
        }
        for value in streamIDCandidates(for: item) { add(value) }

        let metadataManifests = prioritizedManifestURLsWithMetadataFallback().sorted { lhs, rhs in
            let lhsCore = lhs.lowercased().contains("v3-cinemeta.strem.io")
            let rhsCore = rhs.lowercased().contains("v3-cinemeta.strem.io")
            if lhsCore != rhsCore { return lhsCore && !rhsCore }
            return lhs < rhs
        }
        for rawManifest in metadataManifests.prefix(4) {
            for candidate in manifestURLCandidates(from: rawManifest) {
                guard let manifestURL = URL(string: candidate) else { continue }
                let base = normalizedStremioBase(from: manifestURL.absoluteString)
                for mediaID in ids {
                    guard let encodedID = mediaID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let metaURL = URL(string: "\(base)/meta/\(type)/\(encodedID).json") else { continue }
                    do {
                        var request = URLRequest(url: metaURL, timeoutInterval: 6)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("DebridChannels-tvOS/525 PlaybackMetadata", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        guard let meta = try JSONDecoder().decode(StremioMetaResponse.self, from: data).meta else { continue }
                        return MediaItem(
                            id: item.id,
                            tmdbId: meta.tmdbId ?? item.tmdbId,
                            imdbId: meta.imdbId ?? item.imdbId,
                            tvdbId: meta.tvdbId ?? item.tvdbId,
                            title: item.title,
                            year: Self.firstYear(from: meta.releaseInfo).isEmpty ? item.year : Self.firstYear(from: meta.releaseInfo),
                            type: item.type,
                            catalog: item.catalog,
                            description: meta.description ?? item.description,
                            genres: meta.genres ?? item.genres,
                            rating: meta.imdbRating ?? item.rating,
                            posterURL: Self.highest(meta.poster) ?? item.posterURL,
                            landscapeURL: Self.highest(meta.background ?? meta.poster) ?? item.landscapeURL,
                            logoURL: Self.highest(meta.logo) ?? item.logoURL,
                            previewURL: Self.previewURL(from: meta) ?? item.previewURL,
                            addonName: item.addonName,
                            addonIconURL: item.addonIconURL,
                            seasonNumber: item.seasonNumber,
                            episodeNumber: item.episodeNumber,
                            cast: Array((meta.cast ?? item.cast).prefix(8)),
                            directors: Array((meta.directors ?? item.directors).prefix(3)),
                            castMembers: item.castMembers,
                            airDateString: item.airDateString,
                            episodeDateStrings: item.episodeDateStrings,
                            franchiseItems: item.franchiseItems
                        )
                    } catch {
                        continue
                    }
                }
            }
        }

        // Search fallback covers catalog providers that supply only titles and no stable IDs.
        if item.seasonNumber == nil, item.episodeNumber == nil {
            return await cinemetaSearchMatch(for: item, fallbackQuery: item.title)
        }
        return nil
    }

    private func tmdbMetadataFallbackForDetail(_ item: MediaItem) async -> MediaItem? {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        let query = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = normalizedStremioType(item.type) == "series" ? "tv" : "movie"
        let directTMDBID: String? = {
            if let explicit = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty { return explicit }
            let parts = item.id.split(separator: ":").map(String.init)
            if parts.count >= 3, parts[0].lowercased() == "tmdb" { return parts[2] }
            return nil
        }()
        if let directTMDBID,
           let directURL = URL(string: "https://api.themoviedb.org/3/\(kind)/\(directTMDBID)?api_key=\(key)&language=en-US") {
            do {
                var request = URLRequest(url: directURL, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/525 MetadataDirect", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    let result = try JSONDecoder().decode(TMDBListItem.self, from: data)
                    var updated = item
                    updated.tmdbId = String(result.id)
                    let overview = result.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !overview.isEmpty && (updated.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || updated.description.localizedCaseInsensitiveContains("No description")) {
                        updated.description = overview
                    }
                    if let poster = result.poster_path, !poster.isEmpty { updated.posterURL = "https://image.tmdb.org/t/p/original\(poster)" }
                    if let backdrop = result.backdrop_path, !backdrop.isEmpty { updated.landscapeURL = "https://image.tmdb.org/t/p/original\(backdrop)" }
                    if updated.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        updated.logoURL = await tmdbLogoURL(id: result.id, mediaType: kind, apiKey: key)
                    }
                    if (updated.rating.isEmpty || updated.rating == "—"), let vote = result.vote_average, vote > 0 { updated.rating = String(format: "%.1f", vote) }
                    let date = kind == "tv" ? result.first_air_date : result.release_date
                    if updated.year.isEmpty, let y = date?.prefix(4), !y.isEmpty { updated.year = String(y) }
                    cacheArtwork(for: updated, poster: updated.posterURL, backdrop: updated.landscapeURL, logo: updated.logoURL)
                    if updated != item { return updated }
                }
            } catch {
                // Fall through to title/year search.
            }
        }
        guard query.count >= 2, let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let yearDigits = item.year.filter { $0.isNumber }
        let yearParam = (!yearDigits.isEmpty && kind == "movie") ? "&year=\(yearDigits)" : ((!yearDigits.isEmpty) ? "&first_air_date_year=\(yearDigits)" : "")
        guard let url = URL(string: "https://api.themoviedb.org/3/search/\(kind)?api_key=\(key)&query=\(encoded)&include_adult=false&language=en-US\(yearParam)") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/497 MetadataFallback", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let decoded = try JSONDecoder().decode(TMDBListResponse.self, from: data)
            guard let result = decoded.results.first else { return nil }
            var updated = item
            if updated.tmdbId == nil { updated.tmdbId = String(result.id) }
            let overview = result.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !overview.isEmpty && (updated.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || updated.description.localizedCaseInsensitiveContains("No description")) {
                updated.description = overview
            }
            if let poster = result.poster_path, !poster.isEmpty { updated.posterURL = "https://image.tmdb.org/t/p/original\(poster)" }
            if let backdrop = result.backdrop_path, !backdrop.isEmpty { updated.landscapeURL = "https://image.tmdb.org/t/p/original\(backdrop)" }
            if updated.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                updated.logoURL = await tmdbLogoURL(id: result.id, mediaType: kind, apiKey: key)
            }
            cacheArtwork(for: updated, poster: updated.posterURL, backdrop: updated.landscapeURL, logo: updated.logoURL)
            if (updated.rating.isEmpty || updated.rating == "—"), let vote = result.vote_average, vote > 0 { updated.rating = String(format: "%.1f", vote) }
            let date = kind == "tv" ? result.first_air_date : result.release_date
            if updated.year.isEmpty, let y = date?.prefix(4), !y.isEmpty { updated.year = String(y) }
            return updated == item ? nil : updated
        } catch {
            return nil
        }
    }

    private func tmdbCollectionItemsForDetail(_ item: MediaItem) async -> [MediaItem]? {
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        guard normalizedStremioType(item.type) != "series" else { return nil }
        guard let target = await tmdbTargetForCredits(item, apiKey: key), target.kind == "movie" else { return nil }
        guard let detailURL = URL(string: "https://api.themoviedb.org/3/movie/\(target.id)?api_key=\(key)&language=en-US") else { return nil }
        do {
            var detailRequest = URLRequest(url: detailURL, timeoutInterval: 8)
            detailRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            detailRequest.setValue("DebridChannels-tvOS/616 TMDBCollectionDetail", forHTTPHeaderField: "User-Agent")
            let (detailData, detailResponse) = try await URLSession.shared.data(for: detailRequest)
            if let http = detailResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let movieDetail = try JSONDecoder().decode(TMDBMovieDetailWithCollection.self, from: detailData)
            guard let collectionID = movieDetail.belongs_to_collection?.id else { return nil }
            guard let collectionURL = URL(string: "https://api.themoviedb.org/3/collection/\(collectionID)?api_key=\(key)&language=en-US") else { return nil }
            var collectionRequest = URLRequest(url: collectionURL, timeoutInterval: 8)
            collectionRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            collectionRequest.setValue("DebridChannels-tvOS/616 TMDBCollection", forHTTPHeaderField: "User-Agent")
            let (collectionData, collectionResponse) = try await URLSession.shared.data(for: collectionRequest)
            if let http = collectionResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let decoded = try JSONDecoder().decode(TMDBCollectionResponse.self, from: collectionData)
            let parts = (decoded.parts ?? []).sorted { lhs, rhs in
                let ly = (lhs.release_date ?? "").prefix(10)
                let ry = (rhs.release_date ?? "").prefix(10)
                if ly != ry { return ly < ry }
                return lhs.id < rhs.id
            }
            guard parts.count > 1 else { return nil }
            let currentKey = "tmdb:movie:\(target.id)"
            var mapped: [MediaItem] = []
            mapped.reserveCapacity(parts.count)
            for part in parts {
                let title = (part.title ?? part.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let mediaID = "tmdb:movie:\(part.id)"
                let year = String((part.release_date ?? "").prefix(4))
                let poster = part.poster_path.map { "https://image.tmdb.org/t/p/original\($0)" }
                let backdrop = part.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" }
                let rating = (part.vote_average ?? 0) > 0 ? String(format: "%.1f", part.vote_average ?? 0) : ""
                let logo = await tmdbMovieLogoURL(movieID: part.id, apiKey: key)
                mapped.append(MediaItem(
                    id: mediaID,
                    title: title,
                    year: year,
                    type: "movie",
                    catalog: decoded.name ?? "Franchise",
                    description: part.overview ?? "",
                    genres: item.genres,
                    rating: rating,
                    posterURL: poster,
                    landscapeURL: backdrop ?? poster,
                    logoURL: logo,
                    addonName: item.addonName,
                    addonIconURL: item.addonIconURL
                ))
            }
            // Hide the shelf unless TMDB's collection actually contains the current movie.
            guard mapped.contains(where: { $0.id == currentKey }) else { return nil }
            return mapped
        } catch {
            return nil
        }
    }

    private func tmdbMovieLogoURL(movieID: Int, apiKey key: String) async -> String? {
        await tmdbLogoURL(id: movieID, mediaType: "movie", apiKey: key)
    }

    private func tmdbLogoURL(id: Int, mediaType: String, apiKey key: String) async -> String? {
        let endpointType = mediaType.lowercased().contains("tv") || mediaType.lowercased().contains("series") ? "tv" : "movie"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(endpointType)/\(id)/images?api_key=\(key)&include_image_language=en,null") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/752 TMDBTitleLogos", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let decoded = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            let logos = decoded.logos ?? []
            let preferred = logos.sorted { lhs, rhs in
                let lhsEnglish = (lhs.iso_639_1 ?? "") == "en"
                let rhsEnglish = (rhs.iso_639_1 ?? "") == "en"
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                let lhsVotes = lhs.vote_count ?? 0
                let rhsVotes = rhs.vote_count ?? 0
                if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }
                return (lhs.vote_average ?? 0) > (rhs.vote_average ?? 0)
            }.first
            guard let path = preferred?.file_path, !path.isEmpty else { return nil }
            return "https://image.tmdb.org/t/p/original\(path)"
        } catch {
            return nil
        }
    }

    private func tmdbCreditsForDetail(_ item: MediaItem) async -> (castMembers: [CastMember], cast: [String], directors: [String])? {
        let configuredKey = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environmentKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = configuredKey.isEmpty ? environmentKey : configuredKey
        guard !key.isEmpty else { return nil }

        let cacheKey = canonicalCatalogIdentityKey(for: item)
        if let cached = exactCreditsCache[cacheKey] { return cached }
        guard let target = await tmdbTargetForCredits(item, apiKey: key) else { return nil }

        var endpoints: [(path: String, label: String)] = []
        if target.kind == "tv", let season = item.seasonNumber, let episode = item.episodeNumber {
            // v1062 global episode rule: exact episode credits first. TMDB places many
            // anthology and guest actors in `guest_stars`, so that array is decoded and
            // merged ahead of the ordinary cast array.
            endpoints.append(("tv/\(target.id)/season/\(season)/episode/\(episode)/credits", "episode"))
            // If an exact episode has no published credits, prefer the current season
            // before falling back to the full series cast.
            endpoints.append(("tv/\(target.id)/season/\(season)/aggregate_credits", "season"))
            endpoints.append(("tv/\(target.id)/aggregate_credits", "series-aggregate"))
            endpoints.append(("tv/\(target.id)/credits", "series"))
        } else if target.kind == "tv" {
            endpoints.append(("tv/\(target.id)/aggregate_credits", "series-aggregate"))
            endpoints.append(("tv/\(target.id)/credits", "series"))
        } else {
            endpoints.append(("movie/\(target.id)/credits", "movie"))
        }

        var selectedCast: [CastMember] = []
        var selectedDirectors: [String] = []
        for endpoint in endpoints {
            guard !Task.isCancelled else { return nil }
            guard let url = URL(string: "https://api.themoviedb.org/3/\(endpoint.path)?api_key=\(key)&language=en-US") else { continue }
            do {
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/1062 ExactEpisodeCredits", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return nil }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                let decoded = try JSONDecoder().decode(TMDBCreditsResponse.self, from: data)
                let payload = tmdbCreditsPayload(decoded, preferGuestStars: endpoint.label == "episode")
                if selectedCast.isEmpty, !payload.castMembers.isEmpty { selectedCast = payload.castMembers }
                if selectedDirectors.isEmpty, !payload.directors.isEmpty { selectedDirectors = payload.directors }
                if !selectedCast.isEmpty, !selectedDirectors.isEmpty { break }
            } catch {
                continue
            }
        }

        guard !selectedCast.isEmpty || !selectedDirectors.isEmpty else { return nil }
        let result = (castMembers: selectedCast, cast: selectedCast.map(\.name), directors: selectedDirectors)
        rememberExactCredits(result, forKey: cacheKey)
        return result
    }

    private func tmdbCreditsPayload(
        _ decoded: TMDBCreditsResponse,
        preferGuestStars: Bool
    ) -> (castMembers: [CastMember], directors: [String]) {
        let primary = preferGuestStars ? (decoded.guest_stars ?? []) + (decoded.cast ?? []) : (decoded.cast ?? []) + (decoded.guest_stars ?? [])
        var seenCast = Set<String>()
        let castMembers = Array(primary.compactMap { member -> CastMember? in
            guard let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let roleCandidates = [member.character] + (member.roles ?? []).map(\.character)
            let role = roleCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let dedupeKey = name.lowercased()
            guard seenCast.insert(dedupeKey).inserted else { return nil }
            let image = member.profile_path.map { "https://image.tmdb.org/t/p/original\($0)" }
            return CastMember(name: name, role: role, imageURL: image, tmdbPersonId: member.id)
        }.prefix(16))

        var seenDirectors = Set<String>()
        let directors = Array((decoded.crew ?? []).compactMap { member -> String? in
            let jobs = [member.job] + (member.jobs ?? []).map(\.job)
            guard jobs.compactMap({ $0 }).contains(where: { $0.localizedCaseInsensitiveContains("director") }),
                  let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  seenDirectors.insert(name.lowercased()).inserted else { return nil }
            return name
        }.prefix(4))
        return (castMembers, directors)
    }

    private func tmdbTargetForCredits(_ item: MediaItem, apiKey: String) async -> (kind: String, id: String, source: String, tvdbID: Int?)? {
        let parts = item.id.split(separator: ":").map(String.init)
        if parts.count >= 3, parts[0].lowercased() == "tmdb" {
            let kind = (parts[1].lowercased() == "tv" || normalizedStremioType(item.type) == "series") ? "tv" : "movie"
            return (kind, parts[2], "tmdb-id", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        }
        if let explicitTMDB = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitTMDB.isEmpty {
            let kind = normalizedStremioType(item.type) == "series" ? "tv" : "movie"
            return (kind, explicitTMDB, "catalog-tmdbId", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        }
        let parsedTMDB = Self.extractedTrailerTMDBId(from: item.id)
        if !parsedTMDB.isEmpty {
            let kind = normalizedStremioType(item.type) == "series" ? "tv" : "movie"
            return (kind, parsedTMDB, "parsed-tmdb-id", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        }
        var candidates = streamIDCandidates(for: item)
        if let explicitIMDb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitIMDb.isEmpty {
            candidates.insert(explicitIMDb, at: 0)
        }
        if let imdb = candidates.first(where: { $0.lowercased().hasPrefix("tt") }) {
            guard let encoded = imdb.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://api.themoviedb.org/3/find/\(encoded)?api_key=\(apiKey)&external_source=imdb_id&language=en-US") else { return nil }
            do {
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await sourceIntelligenceURLSession.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
                let decoded = try JSONDecoder().decode(TMDBFindResponse.self, from: data)
                if normalizedStremioType(item.type) == "series", let id = decoded.tv_results?.compactMap({ $0.id }).first {
                    return ("tv", String(id), "imdb-find", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
                }
                if let id = decoded.movie_results?.compactMap({ $0.id }).first { return ("movie", String(id), "imdb-find", nil) }
                if let id = decoded.tv_results?.compactMap({ $0.id }).first { return ("tv", String(id), "imdb-find", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")) }
            } catch {
                print("[TMDB] find error \(item.title) imdb=\(imdb): \(error.localizedDescription)")
            }
        }
        if let searched = await tmdbTargetByTitleYear(item, apiKey: apiKey) { return searched }
        return nil
    }

    private func tmdbTargetByTitleYear(_ item: MediaItem, apiKey: String) async -> (kind: String, id: String, source: String, tvdbID: Int?)? {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let kind = normalizedStremioType(item.type) == "series" ? "tv" : "movie"
        let year = item.year.filter { $0.isNumber }
        var query = "api_key=\(apiKey)&query=\(encodedTitle)&include_adult=false&page=1&language=en-US"
        if !year.isEmpty {
            query += kind == "tv" ? "&first_air_date_year=\(year)" : "&year=\(year)"
        }
        guard let url = URL(string: "https://api.themoviedb.org/3/search/\(kind)?\(query)") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/712 TMDBTitleLookup", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await sourceIntelligenceURLSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let decoded = try JSONDecoder().decode(TMDBListResponse.self, from: data)
            let titleKey = normalizedMatchText(title)
            let ranked = decoded.results.sorted { lhs, rhs in
                let lhsTitle = normalizedMatchText(lhs.title ?? lhs.name ?? "")
                let rhsTitle = normalizedMatchText(rhs.title ?? rhs.name ?? "")
                let lhsExact = lhsTitle == titleKey
                let rhsExact = rhsTitle == titleKey
                if lhsExact != rhsExact { return lhsExact && !rhsExact }
                let lhsYear = String((lhs.release_date ?? lhs.first_air_date ?? "").prefix(4))
                let rhsYear = String((rhs.release_date ?? rhs.first_air_date ?? "").prefix(4))
                if !year.isEmpty && lhsYear != rhsYear { return lhsYear == year }
                return (lhs.vote_average ?? 0) > (rhs.vote_average ?? 0)
            }
            guard let match = ranked.first else { return nil }
            return (kind, String(match.id), "title-year-search", Int(item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        } catch {
            print("[TMDB] title lookup error \(item.title): \(error.localizedDescription)")
            return nil
        }
    }

    // v1154: Sports uses the Live TV grid as its background, so stale catalog-detail
    // anchors/restore tokens can otherwise survive a Sports → Home/Live transition and
    // recapture focus or remount old metadata. Clear the whole transient presentation lane
    // when Sports is exited or a live channel bypasses VOD details.
    func clearSportsPresentationStateForNavigation(reason: String) {
        // vBRDC081: Sports exit is a UNITY surface handoff. Avoid blindly assigning every
        // @Published presentation property to its existing default value; each redundant set
        // invalidates the entire CatalogStore observer tree while Live TV is reclaiming focus.
        detailOpenGeneration &+= 1
        detailPresentationRevision &+= 1
        detailCreditsTask?.cancel()
        detailCreditsTask = nil
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        if detailPremiumBackdropURL != nil { detailPremiumBackdropURL = nil }
        if selectedDetail != nil { selectedDetail = nil }
        if !detailBackStack.isEmpty { detailBackStack.removeAll() }

        let hasStreamPresentationState = activeStreamSearchItemID != nil
            || !streamLinks.isEmpty
            || !sourceProviderStatuses.isEmpty
            || !alternateAudioSources.isEmpty
            || selectedAlternateAudioSource != nil
            || alternateAudioSyncOffsetMS != 0
            || !lastStreamMessage.isEmpty
        if hasStreamPresentationState { clearStreamLinkState() }

        if detailPresentationAnchorItem != nil { detailPresentationAnchorItem = nil }
        if detailPresentationOrigin != .catalog { detailPresentationOrigin = .catalog }
        if quickPanelRestoreItemID != nil { quickPanelRestoreItemID = nil }
        if quickPanelRestoreCanonicalKey != nil { quickPanelRestoreCanonicalKey = nil }
        if quickPanelRestoreIdentityItem != nil { quickPanelRestoreIdentityItem = nil }
        if quickPanelRestoreRowID != nil { quickPanelRestoreRowID = nil }
        if quickPanelRestoreRowIndex != 0 { quickPanelRestoreRowIndex = 0 }
        if quickPanelRestoreItemIndex != 0 { quickPanelRestoreItemIndex = 0 }
        if quickPanelRestoreSection != nil { quickPanelRestoreSection = nil }
        if quickPanelRestoreFocusedCardID != nil { quickPanelRestoreFocusedCardID = nil }
        if liveQuickPanelOpen { liveQuickPanelOpen = false }
        if topMenuFocusLocked { topMenuFocusLocked = false }
        // vBRDC081: destination focus tokens are owned by Root's UNITY lifecycle handoff.
        // The outgoing Sports tree must not publish a competing focus revision.
        print("[UNITY Lifecycle][Sports] transient presentation released reason=\(reason)")
    }

    // vBRDC086: Favorites is a dedicated presentation surface even though it reuses the
    // fixed-slot catalog rail. Its restore identity must never survive into Home/Movies/
    // Shows. Keeping this reset in CatalogStore makes the invariant independent of which
    // UI path (Back, top menu, or post-playback exit) leaves Favorites.
    private func clearFavoritesRestoreIdentity() {
        if quickPanelRestoreItemID != nil { quickPanelRestoreItemID = nil }
        if quickPanelRestoreCanonicalKey != nil { quickPanelRestoreCanonicalKey = nil }
        if quickPanelRestoreIdentityItem != nil { quickPanelRestoreIdentityItem = nil }
        if quickPanelRestoreRowID != nil { quickPanelRestoreRowID = nil }
        if quickPanelRestoreRowIndex != 0 { quickPanelRestoreRowIndex = 0 }
        if quickPanelRestoreItemIndex != 0 { quickPanelRestoreItemIndex = 0 }
        if quickPanelRestoreSection != nil { quickPanelRestoreSection = nil }
        if quickPanelRestoreFocusedCardID != nil { quickPanelRestoreFocusedCardID = nil }
    }

    func clearFavoritesPresentationStateForNavigation(reason: String) {
        let ownsFavoritesIdentity = detailPresentationOrigin == .favorites
            || quickPanelRestoreRowID == "catalog-favorites-quick-panel"
            || (quickPanelRestoreFocusedCardID?.hasPrefix("catalog-favorites-quick-panel#") == true)

        guard ownsFavoritesIdentity else { return }

        detailOpenGeneration &+= 1
        detailPresentationRevision &+= 1
        detailCreditsTask?.cancel()
        detailCreditsTask = nil
        detailPremiumArtworkTask?.cancel()
        detailPremiumArtworkTask = nil
        if detailPremiumBackdropURL != nil { detailPremiumBackdropURL = nil }
        if selectedDetail != nil { selectedDetail = nil }
        if detailPresentationAnchorItem != nil { detailPresentationAnchorItem = nil }
        if !detailBackStack.isEmpty { detailBackStack.removeAll() }

        let hasStreamPresentationState = activeStreamSearchItemID != nil
            || !streamLinks.isEmpty
            || !sourceProviderStatuses.isEmpty
            || !alternateAudioSources.isEmpty
            || selectedAlternateAudioSource != nil
            || alternateAudioSyncOffsetMS != 0
            || !lastStreamMessage.isEmpty
        if hasStreamPresentationState { clearStreamLinkState() }

        clearFavoritesRestoreIdentity()
        if detailPresentationOrigin != .catalog { detailPresentationOrigin = .catalog }
        if topMenuFocusLocked { topMenuFocusLocked = false }
        if liveQuickPanelOpen { liveQuickPanelOpen = false }
        print("[UNITY Lifecycle][Favorites][vBRDC086] transient presentation released reason=\(reason)")
    }

    /// vBRDC092: while the popup is still visually present, let the hidden catalog
    /// rail restore its exact row/index FocusState. By the time the reverse popup animation
    /// reaches zero opacity, removing selectedDetail reveals an already-settled card.
    func prepareCatalogDetailDismissalFocusHandoff() {
        guard selectedDetail != nil,
              detailPresentationOrigin == .catalog,
              quickPanelRestoreSection == "streamingCatalog" else { return }
        topMenuFocusLocked = true
        guard !catalogDetailDismissalFocusHandoffPrepared else { return }
        catalogDetailDismissalFocusHandoffPrepared = true
        contentFocusToken &+= 1
    }

    func closeDetail() {
        if let previous = detailBackStack.popLast() {
            catalogDetailDismissalFocusHandoffPrepared = false
            clearStreamLinkState()
            detailPremiumArtworkTask?.cancel()
            detailPremiumArtworkTask = nil
            detailPresentationRevision &+= 1
            detailPresentationAnchorItem = previous
            selectedDetail = previous
            let premiumKey = detailPremiumArtworkCacheKey(for: previous)
            if let pool = detailPremiumBackdropSessionCache[premiumKey] {
                detailPremiumBackdropURL = nextPremiumDetailBackdrop(forKey: premiumKey, pool: pool)
            } else {
                detailPremiumBackdropURL = nil
            }
        } else {
            let closingAnchor = detailPresentationAnchorItem ?? selectedDetail
            selectedDetail = nil
            detailCreditsTask?.cancel()
            detailCreditsTask = nil
            detailPremiumArtworkTask?.cancel()
            detailPremiumArtworkTask = nil
            clearStreamLinkState()
            // v1061: only a catalog-origin detail keeps its hero anchor alive through the
            // focus handoff. Search/alerts/other routes release immediately so no unrelated
            // restore snapshot can pin an old title behind their popup.
            // vBRDC086: only the shared Home/Movies/Shows catalog surface may retain a
            // detail hero anchor through Back. Favorites uses the same rail component, but
            // its restore row belongs to a dedicated surface; retaining that anchor leaked
            // the last Favorite title/artwork into the next catalog until the user moved.
            let closingOrigin = detailPresentationOrigin
            let restoreMatchesClosingItem: Bool = {
                guard closingOrigin == .catalog,
                      quickPanelRestoreSection == "streamingCatalog",
                      quickPanelRestoreRowID != "catalog-favorites-quick-panel",
                      let restoreItem = quickPanelRestoreIdentityItem,
                      let closingAnchor else { return false }
                return catalogItemsShareCanonicalIdentity(restoreItem, closingAnchor)
            }()
            if !restoreMatchesClosingItem {
                detailPremiumBackdropURL = nil
                detailPresentationAnchorItem = nil
            }
            if closingOrigin == .favorites || quickPanelRestoreRowID == "catalog-favorites-quick-panel" {
                clearFavoritesRestoreIdentity()
            }
            // vBRDC044: when returning to the originating catalog card, keep the premium
            // backdrop pinned with the anchor until the row focus is verified. Clearing it
            // here caused premium->row artwork to swap during the popup removal itself.
            detailPresentationOrigin = .catalog
            // v709: catalog-origin details must restore directly to their source card.
            // Keep the top menu out of the focus race until the quick panel consumes
            // the contentFocusToken and reasserts row focus after the row view remounts.
            topMenuFocusLocked = restoreMatchesClosingItem
            if !catalogDetailDismissalFocusHandoffPrepared {
                contentFocusToken &+= 1
            }
            catalogDetailDismissalFocusHandoffPrepared = false
        }
    }

    /// v1061: release the pinned catalog hero only after the visible rail has restored the
    /// same canonical item. Releasing earlier allows tvOS FocusState to briefly resolve row
    /// zero and flash an unrelated logo; releasing after a verified match is visually inert.
    func releaseDetailPresentationAnchorAfterCatalogRestore(matching restoredItem: MediaItem) {
        guard selectedDetail == nil,
              let anchor = detailPresentationAnchorItem,
              catalogItemsShareCanonicalIdentity(anchor, restoredItem) else { return }
        detailPremiumBackdropURL = nil
        detailPresentationAnchorItem = nil
        topMenuFocusLocked = false
        // The restore target has been consumed. Leaving it populated lets a later catalog
        // refresh or focus token snap back to an old row even after the user has moved on.
        quickPanelRestoreItemID = nil
        quickPanelRestoreCanonicalKey = nil
        quickPanelRestoreIdentityItem = nil
        quickPanelRestoreRowID = nil
        quickPanelRestoreSection = nil
        quickPanelRestoreFocusedCardID = nil
    }
    var allInOneCatalogsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: allInOneCatalogsEnabledKey) == nil { return true }
        return defaults.bool(forKey: allInOneCatalogsEnabledKey)
    }

    /// User-managed manifests only. The official all-in-one catalog is deliberately
    /// omitted because it is a built-in app service controlled by a single toggle.
    var userVisibleManifestURLs: [String] {
        dedupedManifestURLs(manifestURLs).filter { !isAllInOneManifestURL($0) }
    }

    func applyAllInOneCatalogPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: allInOneCatalogsEnabledKey)

        // vBRDC196: mode switches invalidate any request that began under the previous mode.
        // Without this generation bump an old All-in-One request could publish after the toggle
        // was turned off (or vice versa), which is why a relaunch appeared to be required.
        catalogLifecycleGeneration &+= 1
        cancelCatalogRecoveryRetry(resetAttempt: true)
        for task in catalogRowRefreshDebounceTasks.values { task.cancel() }
        catalogRowRefreshDebounceTasks.removeAll()
        catalogRowRefreshInFlight.removeAll()
        catalogArtworkEnrichmentTask?.cancel(); catalogArtworkEnrichmentTask = nil
        tmdbDefaultRowsRefreshTask?.cancel(); tmdbDefaultRowsRefreshTask = nil
        catalogLoadLastSuccessfulCompletionAt = nil
        catalogRefreshRequestedAfterActivation = false

        let retainedAccountRows = rows.filter { isTraktCatalogRow($0) }
        if enabled {
            enforceAllInOneManifestPresence()
            let durableRows = bestAvailableOfficialCatalogRows()
            let official = applyBuiltInCatalogRowPreferences(to: durableRows, captureDescriptors: true)
            var next = official + retainedAccountRows
            if let local = localContinueWatchingRow(existingItems: (official + retainedAccountRows).flatMap(\.items)) { next.append(local) }
            rows = prioritizedRowsForDisplay(next)
            status = "All-in-One Catalogs are on. Cached built-in rows are active immediately; checking for updates…"
        } else {
            // Persist the visible external rows whenever possible, then restore the last known
            // external snapshot immediately instead of leaving stale built-in rows mounted.
            let cachedExternal = cachedRows(forKey: externalCatalogRowsCacheKey)
            var next = cachedExternal + retainedAccountRows
            if let local = localContinueWatchingRow(existingItems: (cachedExternal + retainedAccountRows).flatMap(\.items)) { next.append(local) }
            rows = prioritizedRowsForDisplay(next)
            status = cachedExternal.isEmpty
                ? "All-in-One Catalogs are off. Loading your saved external catalogs now…"
                : "All-in-One Catalogs are off. Restored your saved external catalogs immediately; checking for updates…"
        }

        traktCatalogRefreshPending = TraktSyncManager.shared.isConnected
        VODExclusiveWorkRegistry.start { await self.loadAllManifests(forceOfficialRefresh: false) }
    }

    /// Reconcile a backend/profile restore without allowing restored manifest order to
    /// override the current catalog-mode setting. Personal URLs remain saved, but while
    /// All-in-One is enabled only the all-in-one manifest is eligible for browsing.
    func reconcileCatalogsAfterRestore(restoredManifests: [String]?, allInOneEnabled: Bool) {
        UserDefaults.standard.set(allInOneEnabled, forKey: allInOneCatalogsEnabledKey)
        if let restoredManifests {
            // Restores may contain a legacy local/public all-in-one URL from older builds.
            // Keep it hidden and built-in rather than reviving it as a removable addon.
            manifestURLs = dedupedManifestURLs(restoredManifests).filter { !isAllInOneManifestURL($0) }
        }
        if allInOneEnabled {
            enforceAllInOneManifestPresence()
            let durableRows = bestAvailableOfficialCatalogRows()
            if !durableRows.isEmpty {
                _ = updateVisibleCatalogRows(durableRows)
            } else {
                let retainedAccount = rows.filter { isTraktCatalogRow($0) || isPlaybackDerivedCatalogRow($0) }
                rows = prioritizedRowsForDisplay(officialRows(from: rows) + retainedAccount)
            }
        } else {
            cancelCatalogRecoveryRetry(resetAttempt: true)
            let cachedExternal = cachedRows(forKey: externalCatalogRowsCacheKey)
            let retainedAccount = rows.filter { isTraktCatalogRow($0) || isPlaybackDerivedCatalogRow($0) }
            let externalBase = !cachedExternal.isEmpty
                ? cachedExternal
                : rows.filter { !isOfficialCatalogRow($0) && !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0) }
            rows = prioritizedRowsForDisplay(externalBase + retainedAccount)
        }
        UserDefaults.standard.set(manifestURLs, forKey: manifestsKey)
        if allInOneEnabled {
            persistCatalogRowsCache(rows.filter(isOfficialCatalogRow))
        } else {
            persistRows(rows.filter { !isOfficialCatalogRow($0) && !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0) },
                        forKey: externalCatalogRowsCacheKey, maxRows: 80, maxItemsPerRow: 48)
        }
        status = allInOneEnabled
            ? "Profile restored. All-in-One Catalogs remain authoritative."
            : "Profile restored. Using only the person's saved catalogs."
        VODExclusiveWorkRegistry.start { await self.loadAllManifests() }
    }

    private func enforceAllInOneManifestPresence() {
        // The built-in source must never become a visible saved JSON addon. This also
        // removes legacy local/public entries restored from pre-v1007 profiles.
        manifestURLs = dedupedManifestURLs(manifestURLs).filter { !isAllInOneManifestURL($0) }
        UserDefaults.standard.set(manifestURLs, forKey: manifestsKey)
    }

    private func catalogBrowsingManifestURLs() -> [String] {
        if allInOneCatalogsEnabled {
            // Authoritative hidden service: one internal endpoint, controlled only by the
            // toggle. Personal manifests remain saved but are not browsed while it is on.
            return [builtInAllInOneManifestURL]
        }
        // vBRDC053: user-added catalog manifests are the only external catalog source.
        // Managed Debridio catalog adapters were removed; manually added Stremio addons
        // continue to flow through manifestURLs unchanged.
        return dedupedManifestURLs(manifestURLs).filter { !isAllInOneManifestURL($0) }
    }

    private func rememberAllInOneManifestURL(_ value: String) {
        // Intentionally not persisted. Official all-in-one endpoints are internal app
        // configuration and must not appear in the user's saved catalog list.
        _ = value
    }

    private func isAllInOneManifestURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return isSameManifest(value, builtInAllInOneManifestURL)
            || lower.contains("192.168.100.55:8484")
            || lower.contains("api.skylinejay187.it.com")
            || lower.contains("catalog.skylinejay187.it.com")
            || lower.contains("catalog.debridchannels")
    }

    private func isSameManifest(_ lhs: String, _ rhs: String) -> Bool {
        let left = Set(manifestURLCandidates(from: lhs).map { $0.lowercased() })
        let right = Set(manifestURLCandidates(from: rhs).map { $0.lowercased() })
        return !left.isDisjoint(with: right)
    }

    private func isCinemetaManifest(_ value: String) -> Bool {
        value.lowercased().contains("v3-cinemeta.strem.io")
    }

    private func isRetiredManagedCometManifest(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("comet.elfhosted.com") || lower.contains("comet.feels.legal")
    }

    private func isDebridChannelsCatalog(name: String, manifestURL: String) -> Bool {
        // Phase 12B: official-row identity must survive manifest display-name changes.
        // Older builds only matched the exact words "Debrid Channels Catalog"; names
        // such as "Debrid Channels All-in-One" were therefore rejected when restoring
        // a perfectly valid protected snapshot, leaving Home empty until the toggle was
        // cycled. Any catalog identity owned by Debrid Channels is official here.
        let normalizedName = normalizedCatalogName(name)
        if normalizedName.contains("debridchannels") { return true }
        let lower = manifestURL.lowercased()
        return lower.contains("192.168.100.55:8484")
            || lower.contains("api.skylinejay187.it.com")
            || lower.contains("catalog.skylinejay187.it.com")
            || lower.contains("catalog.debridchannels")
    }

    private func manifestDeduplicationKey(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("stremio:///") {
            clean = "https://" + String(clean.dropFirst("stremio:///".count))
        } else if clean.hasPrefix("stremio://") {
            clean = "https://" + String(clean.dropFirst("stremio://".count))
        }
        while clean.hasSuffix("/") { clean.removeLast() }
        guard var components = URLComponents(string: clean) else { return clean }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.lowercased().hasSuffix("/configure") {
            components.path = String(components.path.dropLast("/configure".count)) + "/manifest.json"
            // Configure query values can represent a different account/configuration.
            // Keep them in the identity rather than collapsing every install on one host.
        } else if components.path.lowercased().hasSuffix("/manifest.json") {
            // Signed/query variants of the exact same manifest are equivalent, but the
            // configured path before manifest.json remains part of the identity.
            components.fragment = nil
        }
        return components.string ?? clean
    }

    private func dedupedManifestURLs(_ urls: [String]) -> [String] {
        var output: [String] = []
        var seenKeys = Set<String>()
        for raw in urls {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let key = manifestDeduplicationKey(clean)
            guard seenKeys.insert(key).inserted else { continue }
            output.append(clean)
        }
        return output
    }

    private func persistManifestPriority(_ message: String) {
        manifestURLs = dedupedManifestURLs(manifestURLs)
        if manifestURLs.isEmpty { manifestURLs = [coreMetadataManifestURL] }
        UserDefaults.standard.set(manifestURLs, forKey: manifestsKey)
        // v467: Apply ordering to already-loaded rows immediately. This prevents
        // Cinemeta from staying visually pinned at the top until the next reload.
        rows = prioritizedRowsForDisplay(rows)
        status = message
    }

    private func cleanAllInOneRowTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyPrefix = "Debrid Channels "
        if trimmed.lowercased().hasPrefix(legacyPrefix.lowercased()) {
            let clean = String(trimmed.dropFirst(legacyPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? trimmed : clean
        }
        return trimmed
    }

    private func normalizedCatalogName(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private func manifestPriorityNameMap() -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, url) in prioritizedManifestURLsWithMetadataFallback().enumerated() {
            if let identity = addonIdentities[url] {
                let key = normalizedCatalogName(identity.name)
                if !key.isEmpty, map[key] == nil { map[key] = index }
            }
            if url.lowercased().contains("v3-cinemeta.strem.io") {
                map["cinemeta"] = index
                map["cinemetasearch"] = index
            }
        }
        return map
    }

    private func priorityIndex(for row: MediaRow, using map: [String: Int]) -> Int {
        let addonKey = normalizedCatalogName(row.items.first?.addonName)
        if let priority = map[addonKey] { return priority }
        let rowKey = normalizedCatalogName(row.title)
        if rowKey.contains("cinemeta") { return map["cinemeta"] ?? 9000 }
        if addonKey.contains("cinemeta") { return map["cinemeta"] ?? 9000 }
        if rowKey.contains("tmdb") || addonKey == "tmdb" {
            return max(0, (map["cinemeta"] ?? 9000) - 1)
        }
        // Unknown/user rows should remain above fallback rows but preserve their
        // existing relative order through Swift's stable enumerated sort below.
        return 1000
    }

    private func prioritizedRowsForDisplay(_ inputRows: [MediaRow]? = nil) -> [MediaRow] {
        // vBRDC198 final publication boundary: no cached/fresh Trakt row can bypass the
        // authoritative movie/show sanitizer, and duplicate logical shelf ids collapse here.
        var sourceRows: [MediaRow] = []
        var seenRowIDs = Set<String>()
        for rawRow in (inputRows ?? rows) {
            let candidate: MediaRow?
            if isTraktCatalogRow(rawRow) {
                candidate = sanitizedTraktRows([rawRow]).first
            } else {
                candidate = rawRow
            }
            guard let candidate, seenRowIDs.insert(candidate.id).inserted else { continue }
            sourceRows.append(candidate)
        }
        let hidden = hiddenCustomizedRowIDs()
        let visibleRows = sourceRows.filter { !hidden.contains($0.id) }
        let accountRows = visibleRows.filter { isTraktCatalogRow($0) || isPlaybackDerivedCatalogRow($0) }
        let ordinaryRows = visibleRows.filter { !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0) }
        let priorityMap = manifestPriorityNameMap()
        let manifestSorted = ordinaryRows.enumerated().sorted { left, right in
            let leftPriority = priorityIndex(for: left.element, using: priorityMap)
            let rightPriority = priorityIndex(for: right.element, using: priorityMap)
            if leftPriority == rightPriority { return left.offset < right.offset }
            return leftPriority < rightPriority
        }.map { $0.element }

        let savedOrder = savedCustomizedRowOrder()
        let customRank = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        let sortedAccount = accountRows.enumerated().sorted { lhs, rhs in
            let l = customRank[lhs.element.id] ?? Int.max
            let r = customRank[rhs.element.id] ?? Int.max
            if l == r { return lhs.offset < rhs.offset }
            return l < r
        }.map { $0.element }

        guard allInOneCatalogsEnabled else { return sortedAccount + manifestSorted }

        // In built-in mode the saved customization order is global across official, local
        // Continue Watching, and Trakt rows. Rows unknown to the customizer remain stable.
        let combined = manifestSorted + sortedAccount
        return combined.enumerated().sorted { lhs, rhs in
            let l = customRank[lhs.element.id] ?? Int.max
            let r = customRank[rhs.element.id] ?? Int.max
            if l == r { return lhs.offset < rhs.offset }
            return l < r
        }.map { $0.element }
    }

    private func prioritizedManifestURLsWithMetadataFallback() -> [String] {
        // vBRDC053: the only runtime-managed Stremio provider is Torrentio. User-added
        // addons remain in manifestURLs and are never given global credentials automatically.
        var ordered = dedupedManifestURLs(manifestURLs + builtInDebridManifestURLsFromSettings())
        if !allInOneCatalogsEnabled {
            ordered.removeAll { isAllInOneManifestURL($0) }
        }
        if !ordered.contains(where: { isCinemetaManifest($0) }) {
            ordered.append(coreMetadataManifestURL)
        }
        return ordered
    }

    /// vBRDC053: native TorBox and Torrentio share the main TorBox credential.
    /// Legacy Torrentio override values are migrated once into the main key.
    private func effectiveTorBoxAPIKey() -> String {
        DebridCredentialBridge.effectiveTorBoxAPIKey()
    }

    private func builtInDebridManifestURLsFromSettings() -> [String] {
        // vBRDC053: Torrentio consumes the same authoritative service keys used by
        // native TorBox/RD features and returns ephemeral manifests.
        ManagedAddonBridge.coreDebridStreamManifests().map(\.manifestURL)
    }

    func moveManifestURLToTop(_ urlString: String) {
        guard let index = manifestURLs.firstIndex(of: urlString), index > 0 else { return }
        let moved = manifestURLs.remove(at: index)
        manifestURLs.insert(moved, at: 0)
        persistManifestPriority("Catalog priority updated. Search and Home catalog loading use this saved order first.")
    }

    func moveManifestURLUp(_ urlString: String) {
        guard let index = manifestURLs.firstIndex(of: urlString), index > 0 else { return }
        manifestURLs.swapAt(index, index - 1)
        persistManifestPriority("Catalog moved up. Higher rows are searched and loaded first.")
    }

    func moveManifestURLDown(_ urlString: String) {
        guard let index = manifestURLs.firstIndex(of: urlString), index < manifestURLs.count - 1 else { return }
        manifestURLs.swapAt(index, index + 1)
        persistManifestPriority("Catalog moved down. Higher rows keep priority.")
    }

    func moveManifestURLToBottom(_ urlString: String) {
        guard let index = manifestURLs.firstIndex(of: urlString), index < manifestURLs.count - 1 else { return }
        let moved = manifestURLs.remove(at: index)
        manifestURLs.append(moved)
        persistManifestPriority("Catalog priority updated. This catalog is now lower priority.")
    }

    func addManifestURL(_ urlString: String) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, URL(string: clean) != nil else {
            status = "Enter a valid Stremio manifest URL before adding."
            return
        }
        if isAllInOneManifestURL(clean) {
            UserDefaults.standard.set(true, forKey: allInOneCatalogsEnabledKey)
            enforceAllInOneManifestPresence()
            status = "All-in-One Catalogs are built in and are now enabled."
            VODExclusiveWorkRegistry.start { await self.loadAllManifests() }
            return
        }
        let candidateKey = manifestDeduplicationKey(clean)
        let alreadyExists = manifestURLs.contains { manifestDeduplicationKey($0) == candidateKey }
        guard !alreadyExists else {
            status = "That Stremio JSON/addon is already in your list."
            return
        }
        manifestURLs.append(clean)
        persistManifestPriority("Added Stremio addon at the bottom. Use Move Up or Move to Top to give it search/catalog priority.")
    }

    func removeManifestURL(_ urlString: String) {
        manifestURLs.removeAll { $0 == urlString }
        if manifestURLs.isEmpty { manifestURLs = [coreMetadataManifestURL] }
        UserDefaults.standard.set(manifestURLs, forKey: manifestsKey)
        status = "Removed Stremio JSON/addon."
    }

    func loadAllManifests(forceOfficialRefresh: Bool = false, forceCompleteRows: Bool = false) async {
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else {
            if allInOneCatalogsEnabled { catalogRefreshRequestedAfterActivation = true }
            return
        }
        // vBRDC212: an explicit force request is a true foreground supersede. Previously
        // Reload waited behind the very slow request the user was trying to escape, making
        // the button appear ineffective. Generation invalidation prevents the old task from
        // publishing while the urgent request starts immediately.
        if forceOfficialRefresh,
           catalogLoadInProgress,
           catalogLoadOwnerGeneration == catalogLifecycleGeneration {
            catalogLifecycleGeneration &+= 1
            print("[CatalogFastLoad][vBRDC213] urgent reload superseded active catalog generation")
        }
        if catalogLoadInProgress, catalogLoadOwnerGeneration == catalogLifecycleGeneration {
            let waitStartedAt = Date()
            print("[CatalogPermanence][vBRDC196] waiting for same-generation catalog refresh")
            while catalogLoadInProgress, catalogLoadOwnerGeneration == catalogLifecycleGeneration, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled else { return }
            if !forceOfficialRefresh,
               let completedAt = catalogLoadLastSuccessfulCompletionAt,
               completedAt >= waitStartedAt {
                print("[CatalogPermanence][vBRDC196] coalesced duplicate fresh catalog refresh")
                return
            }
        } else if catalogLoadInProgress {
            print("[CatalogPermanence][vBRDC196] superseding stale catalog-mode generation immediately")
        }

        cancelCatalogRecoveryRetry(resetAttempt: false)
        let lifecycleGeneration = catalogLifecycleGeneration
        catalogLoadOwnerGeneration = lifecycleGeneration
        catalogLoadInProgress = true
        catalogHealthRefreshInProgress = true
        catalogHealthPaginationFailureBuffer = []
        if forceOfficialRefresh { catalogHealthRowPaginationStates = [:] }
        catalogHealthRevision &+= 1
        var freshOfficialCatalogPublished = false
        var anyCatalogPublished = false
        defer {
            let ownsLoadState = catalogLoadOwnerGeneration == lifecycleGeneration
            if ownsLoadState {
                catalogLoadInProgress = false
                catalogHealthRefreshInProgress = false
                catalogHealthFailedPages = catalogHealthPaginationFailureBuffer
            }
            let lifecycleStillCurrent = lifecycleGeneration == catalogLifecycleGeneration
            if (freshOfficialCatalogPublished || anyCatalogPublished),
               !Task.isCancelled,
               lifecycleStillCurrent {
                let completedAt = Date()
                catalogLoadLastSuccessfulCompletionAt = completedAt
                catalogHealthLastSuccessfulRefresh = completedAt
                UserDefaults.standard.set(completedAt, forKey: catalogHealthLastSuccessfulRefreshKey)
                if forceCompleteRows {
                    catalogHealthLastFullPaginationRefresh = completedAt
                    UserDefaults.standard.set(completedAt, forKey: catalogHealthLastFullPaginationRefreshKey)
                }
                catalogHealthRevision &+= 1
                cancelCatalogRecoveryRetry(resetAttempt: true)
                print("[CatalogPermanence][vBRDC027] fresh catalog refresh published")
                // vBRDC210: a cold Resume shelf may have mounted before official artwork.
                // Re-project it against the just-published catalog immediately; do not make
                // the user visit another section before posters/logos become available.
                refreshPlaybackDerivedCatalogRowsIfNeededWithoutNetwork()
                hydrateResumeArtworkOnColdLaunchIfNeeded(force: false)
                // vBRDC195: once the authoritative Debrid Channels catalogs are available,
                // remap connected Trakt shelves against those fully enriched MediaItems. This
                // avoids blank Trakt cards on a cold start even when the initial account refresh
                // raced the base catalog bootstrap.
                if TraktSyncManager.shared.isConnected {
                    let shouldForce = traktCatalogRefreshPending
                    traktCatalogRefreshPending = false
                    refreshTraktCatalogRowsIfNeeded(force: shouldForce)
                }
            } else if (allInOneCatalogsEnabled),
                      !Task.isCancelled,
                      lifecycleStillCurrent {
                scheduleCatalogRecoveryRetry(reason: "official refresh did not publish a complete fresh set")
            }
        }

        if allInOneCatalogsEnabled {
            enforceAllInOneManifestPresence()
            _ = restoreBestOfficialCatalogCacheIfNeeded(reason: "refresh start")
        }
        let urls = catalogBrowsingManifestURLs()
        catalogHealthProviderStatuses = urls.map { url in
            CatalogProviderHealth(
                id: url,
                name: catalogHealthProviderName(for: url),
                endpoint: catalogHealthEndpointLabel(for: url),
                state: .checking,
                loadedRows: 0,
                message: "Checking manifest and catalog rows"
            )
        }
        catalogHealthRevision &+= 1
        guard !urls.isEmpty else {
            status = allInOneCatalogsEnabled
                ? "The built-in catalog is enabled and will retry automatically."
                : "Add at least one Stremio manifest URL."
            return
        }

        isLoading = true
        defer {
            if catalogLoadOwnerGeneration == lifecycleGeneration,
               !fullScreenPlaybackResourceSuspended,
               !vodExclusivePlaybackActive,
               !VODExclusivePlaybackGate.isActive { isLoading = false }
        }

        let previousRows = rows

        let cachedPrimaryRows = allInOneCatalogsEnabled ? bestAvailableOfficialCatalogRows() : []
        let hasCachedPrimaryRows = !cachedPrimaryRows.isEmpty
        var mergedRows: [MediaRow] = []
        var loadedCatalogNames: [String] = []
        var streamOnlyNames: [String] = []
        var failedNames: [String] = []
        var primaryCatalogLoaded = false
        let cinemetaURL = urls.first(where: { isCinemetaManifest($0) })

        // Built-in mode intentionally browses only the hidden official service. Personal
        // manifests remain saved and are restored immediately when the toggle is off.
        for url in urls {
            guard !Task.isCancelled,
                  lifecycleGeneration == catalogLifecycleGeneration,
                  !fullScreenPlaybackResourceSuspended,
                  !vodExclusivePlaybackActive,
                  !VODExclusivePlaybackGate.isActive else { return }
            if isCinemetaManifest(url) {
                recordCatalogProviderHealth(
                    url: url,
                    name: "Cinemeta",
                    state: .streamOnly,
                    loadedRows: 0,
                    message: allInOneCatalogsEnabled ? "Metadata fallback retained; built-in catalog owns browsing rows" : "Queued for personal catalog load"
                )
                continue
            }
            if primaryCatalogLoaded, isSameManifest(url, builtInAllInOneManifestURL) {
                recordCatalogProviderHealth(
                    url: url,
                    state: .cached,
                    loadedRows: 0,
                    message: "Duplicate built-in endpoint skipped after a successful provider response"
                )
                continue
            }
            do {
                let result = try await fetchRows(from: url, forceCompleteRows: forceCompleteRows && isAllInOneManifestURL(url))
                switch result.kind {
                case "stream-only":
                    streamOnlyNames.append(result.name)
                    recordCatalogProviderHealth(
                        url: url,
                        name: result.name,
                        state: .streamOnly,
                        loadedRows: 0,
                        message: "Configured for Source Intelligence; no catalog rows expected"
                    )
                default:
                    if result.rows.isEmpty {
                        failedNames.append("\(result.name): no catalog items")
                        recordCatalogProviderHealth(
                            url: url,
                            name: result.name,
                            state: .noRows,
                            loadedRows: 0,
                            message: "Provider returned no visible catalog rows"
                        )
                    } else {
                        mergedRows.append(contentsOf: result.rows)
                        loadedCatalogNames.append(result.name)
                        recordCatalogProviderHealth(
                            url: url,
                            name: result.name,
                            state: .loaded,
                            loadedRows: result.rows.count,
                            message: "Loaded \(result.rows.count) row(s) with \(result.rows.reduce(0) { $0 + $1.items.count }) posters"
                        )
                        if isDebridChannelsCatalog(name: result.name, manifestURL: url) {
                            primaryCatalogLoaded = true
                        }
                    }
                }
            } catch {
                failedNames.append(safeCatalogFailureDescription(for: url, error: error))
                recordCatalogProviderHealth(
                    url: url,
                    state: catalogHealthTimedOut(error) ? .timedOut : .failed,
                    loadedRows: 0,
                    message: error.localizedDescription
                )
            }
        }

        guard !Task.isCancelled,
              lifecycleGeneration == catalogLifecycleGeneration,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }

        // vBRDC212: never let the frame-budget gate become a catalog availability gate.
        // First paint (or an explicit user force reload) publishes immediately. When a stable
        // catalog is already visible, retain the durable navigation gate to avoid row-tree
        // churn during an active focus transition.
        let hasVisibleCatalogRows = rows.contains { row in
            !isTraktCatalogRow(row) && !isPlaybackDerivedCatalogRow(row) && !row.items.isEmpty
        }
        let publicationPermitted: Bool
        if forceOfficialRefresh || !hasVisibleCatalogRows {
            publicationPermitted = true
        } else {
            publicationPermitted = await UnityFrameRuntime.shared.waitUntilPermittedDurably(.interactiveMetadata)
        }
        guard publicationPermitted,
              !Task.isCancelled,
              lifecycleGeneration == catalogLifecycleGeneration else {
            catalogRefreshRequestedAfterActivation = true
            return
        }

        if allInOneCatalogsEnabled {
            if primaryCatalogLoaded, !mergedRows.isEmpty {
                let didPublish = updateVisibleCatalogRows(mergedRows)
                anyCatalogPublished = didPublish
                freshOfficialCatalogPublished = didPublish && builtInCatalogRowDescriptors.count >= officialCatalogFullPublishedRows
                let streamNote = streamOnlyNames.isEmpty ? "" : " Stream-only addons remain available for Find Links."
                if freshOfficialCatalogPublished {
                    status = "Loaded and verified \(builtInCatalogRowDescriptors.count) built-in catalog rows.\(streamNote)"
                } else if didPublish {
                    status = "Showing \(builtInCatalogRowDescriptors.count) built-in rows while background recovery completes the catalog.\(streamNote)"
                } else {
                    status = "The cached catalog remains visible while the complete update retries."
                }
            } else {
                // Phase 12A invariant: network failure is never a publishing event and
                // never clears rows. The fullest durable catalog remains on-screen.
                if hasCachedPrimaryRows {
                    _ = updateVisibleCatalogRows(cachedPrimaryRows)
                } else {
                    let visibleOfficial = officialRows(from: previousRows)
                    if !visibleOfficial.isEmpty { _ = updateVisibleCatalogRows(visibleOfficial) }
                }
                let failNote = failedNames.isEmpty ? "" : " Last check: \(failedNames.prefix(2).joined(separator: "; "))."
                status = rows.isEmpty
                    ? "The built-in catalog is still preparing its first complete cache and will retry automatically.\(failNote)"
                    : "Showing cached built-in catalogs; background recovery will keep retrying.\(failNote)"
            }
            return
        }

        // Personal-catalog mode remains fully controlled by the existing toggle.
        if let cinemetaURL {
            do {
                let result = try await fetchRows(from: cinemetaURL)
                if !result.rows.isEmpty {
                    let existing = Set(mergedRows.map(\.id))
                    mergedRows.append(contentsOf: result.rows.filter { !existing.contains($0.id) })
                    loadedCatalogNames.append("Cinemeta")
                    recordCatalogProviderHealth(
                        url: cinemetaURL,
                        name: "Cinemeta",
                        state: .loaded,
                        loadedRows: result.rows.count,
                        message: "Loaded \(result.rows.count) metadata row(s)"
                    )
                } else {
                    recordCatalogProviderHealth(
                        url: cinemetaURL,
                        name: "Cinemeta",
                        state: .noRows,
                        loadedRows: 0,
                        message: "Provider returned no catalog rows"
                    )
                }
            } catch {
                failedNames.append("Cinemeta: \(error.localizedDescription)")
                recordCatalogProviderHealth(
                    url: cinemetaURL,
                    name: "Cinemeta",
                    state: catalogHealthTimedOut(error) ? .timedOut : .failed,
                    loadedRows: 0,
                    message: error.localizedDescription
                )
            }
        }

        guard !Task.isCancelled,
              lifecycleGeneration == catalogLifecycleGeneration,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }

        if !mergedRows.isEmpty {
            persistRows(mergedRows, forKey: externalCatalogRowsCacheKey, maxRows: 80, maxItemsPerRow: 48)
            anyCatalogPublished = updateVisibleCatalogRows(mergedRows)
            let streamNote = streamOnlyNames.isEmpty ? "" : " Stream-only addons active for Find Links: \(streamOnlyNames.joined(separator: ", "))."
            status = "Loaded \(mergedRows.count) personal catalog row(s) from \(loadedCatalogNames.joined(separator: ", ")).\(streamNote)"
        } else {
            // vBRDC196: a failed external refresh keeps the last-known-good external
            // snapshot mounted. Never recover by heuristically filtering the previous
            // mixed array; that was a source of official/Trakt mode contamination.
            let cachedExternal = cachedRows(forKey: externalCatalogRowsCacheKey)
            let priorExternal = previousRows.filter {
                !isOfficialCatalogRow($0) && !isTraktCatalogRow($0) && !isPlaybackDerivedCatalogRow($0)
            }
            let stableExternal = !cachedExternal.isEmpty ? cachedExternal : priorExternal
            let accountRows = previousRows.filter { isTraktCatalogRow($0) || isPlaybackDerivedCatalogRow($0) }
            rows = prioritizedRowsForDisplay(stableExternal + accountRows)
            let failNote = failedNames.isEmpty ? "" : " Catalog providers returned no rows or failed: \(failedNames.prefix(3).joined(separator: "; "))."
            status = "No personal catalog rows were replaced. Kept the last working external catalog snapshot.\(failNote)"
        }
    }

    private func startTMDBDefaultRowsRefresh(existingRows: [MediaRow]) {
        guard !allInOneCatalogsEnabled else { return }
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }
        let key = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        tmdbDefaultRowsRefreshTask?.cancel()
        tmdbDefaultRowsRefreshTask = Task { @MainActor in
            let start = Date()
            print("[CatalogFastLoad] TMDB enrichment start defaultShelves existingRows=\(existingRows.count)")
            do {
                let tmdbRows = try await withTimeout(10) {
                    await self.tmdbDefaultCatalogRows(apiKey: key)
                }
                guard !Task.isCancelled,
                      !self.vodExclusivePlaybackActive,
                      !VODExclusivePlaybackGate.isActive,
                      !tmdbRows.isEmpty else {
                    print("[CatalogFastLoad] TMDB enrichment end defaultShelves rows=0/cancelled elapsedMs=\(Self.elapsedMS(since: start))")
                    return
                }
                var merged = self.rows
                let existing = Set(merged.map { $0.id })
                merged.append(contentsOf: tmdbRows.filter { !existing.contains($0.id) })
                guard await UnityFrameRuntime.shared.waitUntilPermittedDurably(.interactiveMetadata),
                      !Task.isCancelled else { return }
                self.updateVisibleCatalogRows(merged)
                print("[CatalogFastLoad] TMDB enrichment end defaultShelves rows=\(tmdbRows.count) elapsedMs=\(Self.elapsedMS(since: start))")
            } catch {
                let label = (error as? URLError)?.code == .timedOut ? "timeout" : "fail"
                print("[CatalogFastLoad] TMDB enrichment \(label) defaultShelves error=\(error.localizedDescription) elapsedMs=\(Self.elapsedMS(since: start))")
            }
        }
    }

    /// vBRDC324: bounded MAIN-catalog metadata repair with one atomic publication.
    func requestMainCatalogArtworkRepair(for visibleRows: [MediaRow], reason: String) {
        guard !visibleRows.isEmpty,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }

        let tmdbKey = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
        guard !tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let missing = visibleRows.flatMap(\.items).filter { item in
            let poster = item.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let landscape = item.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return poster.isEmpty || landscape.isEmpty
        }
        var seen = Set<String>()
        let targetItems = Array(missing.filter { seen.insert($0.id).inserted }.prefix(24))
        guard !targetItems.isEmpty else { return }

        catalogArtworkEnrichmentTask?.cancel()
        catalogArtworkEnrichmentTask = VODExclusiveWorkRegistry.start {
            var replacements: [String: MediaItem] = [:]
            for batchStart in stride(from: 0, to: targetItems.count, by: 3) {
                guard !Task.isCancelled,
                      !self.fullScreenPlaybackResourceSuspended,
                      !self.vodExclusivePlaybackActive,
                      !VODExclusivePlaybackGate.isActive else { return }
                let batch = Array(targetItems[batchStart..<min(batchStart + 3, targetItems.count)])
                await withTaskGroup(of: (String, MediaItem).self) { group in
                    for item in batch {
                        group.addTask {
                            let enriched = await self.applyTMDBPrimaryArtworkIfResolvable(to: item, tmdbApiKey: tmdbKey)
                            return (item.id, enriched)
                        }
                    }
                    for await (id, enriched) in group { replacements[id] = enriched }
                }
            }

            guard !Task.isCancelled, !replacements.isEmpty else { return }
            await MainActor.run {
                guard !self.fullScreenPlaybackResourceSuspended,
                      !self.vodExclusivePlaybackActive,
                      !VODExclusivePlaybackGate.isActive else { return }
                var changed = false
                let repaired = self.rows.map { row in
                    var rowChanged = false
                    let items = row.items.map { item -> MediaItem in
                        guard let replacement = replacements[item.id] else { return item }
                        let oldPoster = item.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let oldLandscape = item.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let newPoster = replacement.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let newLandscape = replacement.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard (oldPoster.isEmpty && !newPoster.isEmpty) || (oldLandscape.isEmpty && !newLandscape.isEmpty) else { return item }
                        rowChanged = true
                        changed = true
                        return replacement
                    }
                    return rowChanged ? MediaRow(id: row.id, title: row.title, items: items, presentation: row.presentation) : row
                }
                guard changed else { return }
                self.rows = self.prioritizedRowsForDisplay(repaired)
                self.persistCatalogRowsCache(self.rows)
                print("[MainCatalogArtwork][vBRDC324] atomic repair items=\(replacements.count) reason=\(reason)")
            }
        }
    }

    private func startCatalogArtworkEnrichment(for newRows: [MediaRow], reason: String) {
        requestMainCatalogArtworkRepair(for: Array(newRows.prefix(3)), reason: reason)
    }

    func requestLazyCatalogRowRefresh(row: MediaRow, selectedItem: MediaItem?, reason: String) {
        guard !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }
        guard shouldLazyRefreshCatalogRow(row, selectedItem: selectedItem) else { return }
        let key = canonicalCatalogRowRefreshKey(row)
        catalogRowRefreshDebounceTasks[key]?.cancel()
        catalogRowRefreshDebounceTasks[key] = VODExclusiveWorkRegistry.start {
            try? await Task.sleep(nanoseconds: 720_000_000)
            guard !Task.isCancelled,
                  !self.fullScreenPlaybackResourceSuspended,
                  !self.vodExclusivePlaybackActive,
                  !VODExclusivePlaybackGate.isActive else { return }
            await self.refreshCatalogRowIfNeeded(row: row, selectedItem: selectedItem, reason: reason)
        }
    }

    private func shouldLazyRefreshCatalogRow(_ row: MediaRow, selectedItem: MediaItem?) -> Bool {
        // vBRDC202: Resume/Trakt rows are account-derived, not manifest rows. Missing
        // artwork there must never trigger a full All-in-One provider row fetch; Trakt/TMDB
        // hydration owns those cards. The old generic repair lane could launch multiple
        // unnecessary catalog requests during a sync and visibly stall the main screen.
        if isTraktCatalogRow(row) || isPlaybackDerivedCatalogRow(row) { return false }
        if row.items.isEmpty { return true }
        let candidates = Array(([selectedItem].compactMap { $0 } + row.items.prefix(8)).prefix(9))
        if candidates.contains(where: { item in
            let poster = item.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let landscape = item.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return poster.isEmpty && landscape.isEmpty
        }) { return true }
        if row.items.count < 5 {
            let key = canonicalCatalogRowRefreshKey(row)
            if let last = catalogRowRefreshLastAttempt[key] {
                return Date().timeIntervalSince(last) > 600
            }
            return true
        }
        return false
    }

    private func refreshCatalogRowIfNeeded(row: MediaRow, selectedItem: MediaItem?, reason: String) async {
        guard !Task.isCancelled,
              !fullScreenPlaybackResourceSuspended,
              !vodExclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive else { return }
        let key = canonicalCatalogRowRefreshKey(row)
        let now = Date()
        if let last = catalogRowRefreshLastAttempt[key], now.timeIntervalSince(last) < catalogRowRefreshCooldown {
            // Phase 5: internal repair bookkeeping must not publish global UI status.
            print("catalog row refresh skipped due to cooldown", key, reason)
            return
        }
        guard catalogRowRefreshInFlight.count < catalogRowRefreshMaxConcurrent else {
            // Phase 5: keep queue pressure off the app-wide observable UI state.
            print("catalog row refresh skipped because concurrent limit is active", key, reason)
            return
        }
        guard !catalogRowRefreshInFlight.contains(key) else { return }
        catalogRowRefreshLastAttempt[key] = now
        catalogRowRefreshInFlight.insert(key)
        print("catalog row refresh requested", key, reason)
        defer { catalogRowRefreshInFlight.remove(key) }

        var refreshedRowCount = 0
        for url in catalogBrowsingManifestURLs() {
            do {
                let result = try await fetchRows(from: url)
                guard result.kind != "stream-only", !result.rows.isEmpty else { continue }
                if let replacement = matchingRefreshRow(for: row, selectedItem: selectedItem, in: result.rows) {
                    guard await UnityFrameRuntime.shared.waitUntilPermittedDurably(.interactiveMetadata),
                          !Task.isCancelled else { return }
                    replaceCatalogRow(row, with: replacement)
                    refreshedRowCount = 1
                    print("catalog row refresh succeeded", key, "refreshed row count", refreshedRowCount)
                    break
                }
            } catch {
                print("catalog row refresh provider failed", key, safeCatalogLogLabel(for: url), error.localizedDescription)
                continue
            }
        }
        if refreshedRowCount == 0 {
            print("catalog row refresh failed", key, "refreshed row count", refreshedRowCount)
        }
    }

    private func replaceCatalogRow(_ displayedRow: MediaRow, with replacement: MediaRow) {
        let displayedKey = canonicalCatalogRowRefreshKey(displayedRow)
        guard let canonicalReplacement = canonicalizedCatalogRows([replacement]).first else { return }
        var didReplace = false
        rows = rows.map { existing in
            if canonicalCatalogRowRefreshKey(existing) == displayedKey || existing.title == displayedRow.title {
                didReplace = true
                return canonicalReplacement
            }
            return existing
        }
        if !didReplace {
            rows.append(canonicalReplacement)
        }
        rows = prioritizedRowsForDisplay(rows)
    }

    private func matchingRefreshRow(for displayedRow: MediaRow, selectedItem: MediaItem?, in candidateRows: [MediaRow]) -> MediaRow? {
        let displayedKey = canonicalCatalogRowRefreshKey(displayedRow)
        if let exact = candidateRows.first(where: { canonicalCatalogRowRefreshKey($0) == displayedKey }) {
            return exact
        }
        if let titleMatch = candidateRows.first(where: { $0.title.caseInsensitiveCompare(displayedRow.title) == .orderedSame }) {
            return titleMatch
        }
        if let selectedItem {
            return candidateRows.first(where: { candidate in
                candidate.items.contains { $0.id == selectedItem.id || ($0.title == selectedItem.title && $0.type == selectedItem.type) }
            })
        }
        return nil
    }

    private func canonicalCatalogRowRefreshKey(_ row: MediaRow) -> String {
        row.id
            .replacingOccurrences(of: "-slot-overlay-series", with: "")
            .replacingOccurrences(of: "-slot-overlay-movie", with: "")
            .replacingOccurrences(of: "-slot-overlay", with: "")
    }

    private func fetchRows(from urlString: String, forceCompleteRows: Bool = false) async throws -> (name: String, kind: String, rows: [MediaRow]) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOfficialRequest = isAllInOneManifestURL(clean)
        let candidates = manifestURLCandidates(from: clean)
        var manifestURL: URL? = nil
        var manifestData: Data? = nil
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            do {
                let timeout: TimeInterval = candidate.lowercased().contains("192.168.100.55:8484") ? 3.0 : (isOfficialRequest ? 4.5 : 8.0)
                var request = URLRequest(url: url, timeoutInterval: timeout)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/916 InstantCatalogManifest", forHTTPHeaderField: "User-Agent")
                // vBRDC212: foreground catalog fetches fail over at the catalog-recovery
                // layer; do not spend 25+ seconds retrying the same manifest request here.
                let (data, _) = try await fetchCatalogData(request, attempts: 1)
                manifestURL = url
                manifestData = data
                break
            } catch {
                continue
            }
        }
        guard let manifestURL, let manifestData else {
            throw isOfficialRequest ? CatalogReliabilityError.unavailable : URLError(.badURL)
        }
        var manifest = try JSONDecoder().decode(StremioManifest.self, from: manifestData)
        if isOfficialRequest || manifest.debridChannels?.allInOne == true {
            try validateAndSanitizeOfficialManifest(&manifest, manifestURL: manifestURL)
        }
        if manifest.debridChannels?.allInOne == true {
            rememberAllInOneManifestURL(urlString)
            // Internal endpoint hints are retained only in memory for unified Search.
            builtInUnifiedSearchURL = manifest.debridChannels?.searchURL
            builtInUnifiedBatchRowsURL = manifest.debridChannels?.batchRowsURL
        }
        let base = URL(string: normalizedStremioBase(from: manifestURL.absoluteString)) ?? manifestURL.deletingLastPathComponent()
        let catalogs = (manifest.catalogs ?? [])
        let addonName = manifest.name ?? manifestURL.host ?? "Stremio"
        let addonIconURL = Self.highest(manifest.logo ?? manifest.icon)
        await MainActor.run {
            self.addonIdentities[urlString] = StremioAddonIdentity(name: addonName, iconURL: addonIconURL, kind: self.addonKind(from: manifest))
        }

        func mappedItems(from metas: [StremioMeta], type: String, catalogName: String, forceDeclaredType: Bool = false) -> [MediaItem] {
            metas.compactMap { meta in
                let cleanID = meta.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanTitle = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                if isOfficialRequest, (cleanID?.isEmpty != false || cleanTitle?.isEmpty != false) {
                    return nil
                }
                guard let poster = Self.highest(meta.poster)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !poster.isEmpty else {
                    // v1005: Never create a visible catalog card without a concrete poster URL.
                    // The Phase 2.7 server also enforces this, but the client remains defensive
                    // against stale caches or third-party malformed catalog responses.
                    return nil
                }
                return MediaItem(
                    id: cleanID ?? UUID().uuidString,
                    tmdbId: meta.tmdbId,
                    imdbId: meta.imdbId,
                    tvdbId: meta.tvdbId,
                    title: cleanTitle ?? "Untitled",
                    year: Self.firstYear(from: meta.releaseInfo),
                    // vBRDC199: for the official All-in-One source the manifest catalog
                    // declaration is authoritative. A malformed/swapped batch meta must not
                    // turn a Movies row into TV Shows (or vice versa).
                    type: forceDeclaredType ? type : (meta.type ?? type),
                    catalog: catalogName,
                    description: meta.description ?? "No description available yet.",
                    genres: Array((meta.genres ?? [type.capitalized, "Cinema"]).prefix(3)),
                    rating: meta.imdbRating ?? "—",
                    posterURL: poster,
                    landscapeURL: Self.highest(meta.background) ?? poster,
                    logoURL: Self.highest(meta.logo),
                    previewURL: Self.previewURL(from: meta),
                    addonName: addonName,
                    addonIconURL: addonIconURL,
                    seasonNumber: nil,
                    episodeNumber: nil,
                    cast: Array((meta.cast ?? []).prefix(8)),
                    directors: Array((meta.directors ?? []).prefix(3))
                )
            }
        }

        func fullyHydratedOfficialRows(seedRows: [MediaRow]) async -> [MediaRow] {
            guard isOfficialRequest, forceCompleteRows, !seedRows.isEmpty else { return seedRows }

            let manifestName = manifest.name ?? "manifest"
            let maximumSeedCount = seedRows.map { $0.items.count }.max() ?? 0
            var hydratedRowsByID = Dictionary(uniqueKeysWithValues: seedRows.map { ($0.id, $0) })
            var hydratedRowsByTitle: [String: String] = [:]
            for row in seedRows where hydratedRowsByTitle[normalizedCatalogName(row.title)] == nil {
                hydratedRowsByTitle[normalizedCatalogName(row.title)] = row.id
            }

            // Batch rows are intentionally fast and can stop at one page. Only rows that
            // reach the batch's largest page boundary are likely truncated; page those
            // rows completely so the manual reload remains bounded across 83 catalogs.
            for catalog in catalogs {
                guard !Task.isCancelled,
                      !vodExclusivePlaybackActive,
                      !VODExclusivePlaybackGate.isActive else {
                    return seedRows.compactMap { hydratedRowsByID[$0.id] }
                }

                let type = catalog.type ?? "movie"
                let catalogID = catalog.id ?? "popular"
                let cleanName = cleanAllInOneRowTitle(catalog.name ?? catalogID.capitalized)
                let expectedRowID = "\(type)-\(catalogID)-\(manifestName)"
                let seedRowID = hydratedRowsByID[expectedRowID] != nil
                    ? expectedRowID
                    : hydratedRowsByTitle[normalizedCatalogName(cleanName)]
                guard let rowID = seedRowID, var row = hydratedRowsByID[rowID] else { continue }
                guard row.items.count >= 12,
                      row.items.count == maximumSeedCount || [12, 20, 24, 25, 30, 40, 48, 50, 60, 80, 96, 100].contains(row.items.count) else { continue }

                var mergedItems = row.items
                var seenIDs = Set(mergedItems.map { $0.id })
                var skip = mergedItems.count
                var pageCount = 0

                while pageCount < 8, mergedItems.count < 500 {
                    var acceptedMetas: [StremioMeta] = []
                    var acceptedItems: [MediaItem] = []
                    var pageErrors: [String] = []
                    var receivedResponse = false
                    let requestedSkip = skip
                    for catalogURL in catalogEndpointCandidates(base: base, catalog: catalog, skip: skip) {
                        do {
                            let timeout: TimeInterval = catalogURL.host == "192.168.100.55" ? 7.0 : 12.0
                            var request = URLRequest(url: catalogURL, timeoutInterval: timeout)
                            request.setValue("application/json", forHTTPHeaderField: "Accept")
                            request.setValue("DebridChannels-tvOS/1099 CatalogHealthFullPagination", forHTTPHeaderField: "User-Agent")
                            let (catalogData, _) = try await fetchCatalogData(request, attempts: 2)
                            receivedResponse = true
                            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: catalogData)
                            let metas = decoded.metas ?? []
                            guard !metas.isEmpty else { continue }
                            let candidateItems = mappedItems(from: metas, type: type, catalogName: cleanName, forceDeclaredType: isOfficialRequest)
                            let unseenItems = candidateItems.filter { !seenIDs.contains($0.id) }
                            // A server may accept ?skip= but ignore it. Keep trying the
                            // path-extra candidate until a page actually advances.
                            guard !unseenItems.isEmpty else { continue }
                            acceptedMetas = metas
                            acceptedItems = unseenItems
                            break
                        } catch {
                            pageErrors.append(error.localizedDescription)
                            continue
                        }
                    }

                    guard !acceptedMetas.isEmpty, !acceptedItems.isEmpty else {
                        if !receivedResponse, !pageErrors.isEmpty {
                            let failure = CatalogPageFailure(
                                id: "\(rowID)|\(requestedSkip)",
                                rowID: rowID,
                                rowTitle: row.title,
                                page: pageCount + 2,
                                skip: requestedSkip,
                                message: pageErrors.first ?? "Page request failed"
                            )
                            if !catalogHealthPaginationFailureBuffer.contains(where: { $0.id == failure.id }) {
                                catalogHealthPaginationFailureBuffer.append(failure)
                            }
                        }
                        break
                    }
                    for item in acceptedItems { seenIDs.insert(item.id) }
                    mergedItems.append(contentsOf: acceptedItems)
                    skip += max(acceptedMetas.count, acceptedItems.count)
                    pageCount += 1
                    if acceptedMetas.count < 8 { break }
                }

                catalogHealthRowPaginationStates[rowID] = pageCount > 0
                    ? "\(pageCount + 1) pages checked • \(mergedItems.count) posters"
                    : "First page checked • \(mergedItems.count) posters"
                if mergedItems.count > row.items.count {
                    row = MediaRow(id: row.id, title: row.title, items: mergedItems, presentation: row.presentation)
                    hydratedRowsByID[rowID] = row
                    hydratedRowsByTitle[normalizedCatalogName(row.title)] = rowID
                    print("[CatalogFullRows][v1060] hydrated row=\(row.title) items=\(mergedItems.count) pages=\(pageCount)")
                }
            }

            return seedRows.compactMap { hydratedRowsByID[$0.id] }
        }

        if let batchURLString = manifest.debridChannels?.batchRowsURL,
           let batchURL = URL(string: batchURLString) {
            do {
                let timeout: TimeInterval = batchURL.host == "192.168.100.55" ? 6.0 : (isOfficialRequest ? 8.0 : 12.0)
                var request = URLRequest(url: batchURL, timeoutInterval: timeout)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/916 InstantCatalogBatchRows", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await fetchCatalogData(request, attempts: 1)
                let decoded = try JSONDecoder().decode(DebridChannelsBatchCatalogResponse.self, from: data)
                let rows = decoded.rows.compactMap { row -> MediaRow? in
                    let cleanName = cleanAllInOneRowTitle(row.name)
                    let batchID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    let titleKey = normalizedCatalogName(cleanName)
                    // Match the manifest row by its display name first. Movie + series
                    // catalogs often reuse ids such as "popular"; matching by id alone can
                    // silently bind a Shows batch row to the Movies declaration.
                    let manifestByTitle = catalogs.first(where: {
                        normalizedCatalogName(cleanAllInOneRowTitle($0.name ?? $0.id ?? "")) == titleKey
                    })
                    let manifestIDMatches = catalogs.filter {
                        ($0.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == batchID
                    }
                    let normalizedBatchType = row.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let manifestByUniqueID = manifestIDMatches.count == 1 ? manifestIDMatches.first : nil
                    let manifestByTypedID = manifestIDMatches.first(where: {
                        let value = ($0.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return !normalizedBatchType.isEmpty && value == normalizedBatchType
                    })
                    let manifestCatalog = manifestByTitle ?? manifestByUniqueID ?? manifestByTypedID
                    let declaredType = (manifestCatalog?.type ?? row.type)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let authoritativeType: String
                    if declaredType == "show" || declaredType == "tv" || declaredType == "episode" { authoritativeType = "series" }
                    else { authoritativeType = declaredType.isEmpty ? "movie" : declaredType }
                    let items = mappedItems(
                        from: row.metas ?? [],
                        type: authoritativeType,
                        catalogName: cleanName,
                        forceDeclaredType: isOfficialRequest
                    )
                    guard !items.isEmpty else { return nil }
                    return MediaRow(
                        id: "\(authoritativeType)-\(row.id)-\(manifest.name ?? "manifest")",
                        title: cleanName,
                        items: items,
                        presentation: row.debridChannels
                    )
                }
                if !rows.isEmpty {
                    let repairedRows = isOfficialRequest
                        ? repairedOfficialCatalogRows(rows, catalogs: catalogs, manifestName: manifest.name ?? "manifest")
                        : rows
                    var readyRows = isOfficialRequest
                        ? try validatedOfficialCatalogRows(repairedRows, expectedRowCount: max(decoded.rows.count, catalogs.count))
                        : repairedRows
                    if isOfficialRequest, forceCompleteRows {
                        readyRows = await fullyHydratedOfficialRows(seedRows: readyRows)
                        readyRows = try validatedOfficialCatalogRows(readyRows, expectedRowCount: max(decoded.rows.count, catalogs.count))
                    }
                    return (manifest.name ?? "manifest", addonKind(from: manifest), readyRows)
                }
            } catch {
                print("[Catalog][v1003] Phase 2 batch rows unavailable; using standard manifest endpoints: \(error.localizedDescription)")
            }
        }

        var builtRows: [MediaRow] = []
        if catalogs.isEmpty {
            // Stream-only addons such as Torrentio/TorBox are valid and should remain saved/active even though
            // they do not create Home rows. Their /stream endpoints are used from Find Links on Cinemeta items.
            return (manifest.name ?? manifestURL.host ?? "stream addon", addonKind(from: manifest), [])
        }
        // vBRDC212: if the batch endpoint is unavailable, fan out first-page catalog
        // endpoints in bounded parallel waves. The old serial 83-row fallback could turn a
        // single batch miss into nearly a minute of blank catalogs.
        let fallbackConcurrency = min(isOfficialRequest ? 12 : 6, max(1, catalogs.count))
        for chunkStart in stride(from: 0, to: catalogs.count, by: fallbackConcurrency) {
            guard !Task.isCancelled else { break }
            let chunk = Array(catalogs[chunkStart..<min(chunkStart + fallbackConcurrency, catalogs.count)])
            let tasks: [Task<(StremioCatalog, CatalogResponse?), Never>] = chunk.map { catalog in
                Task { @MainActor [weak self] in
                    guard let self else { return (catalog, nil) }
                    let candidates = self.catalogEndpointCandidates(base: base, catalog: catalog)
                    let foregroundCandidates = isOfficialRequest ? Array(candidates.prefix(2)) : candidates
                    for catalogURL in foregroundCandidates {
                        guard !Task.isCancelled else { return (catalog, nil) }
                        do {
                            let timeout: TimeInterval = catalogURL.host == "192.168.100.55" ? 4.0 : (isOfficialRequest ? 5.0 : 8.0)
                            var request = URLRequest(url: catalogURL, timeoutInterval: timeout)
                            request.setValue("application/json", forHTTPHeaderField: "Accept")
                            request.setValue("DebridChannels-tvOS/916 InstantCatalogFanout", forHTTPHeaderField: "User-Agent")
                            let (catalogData, _) = try await self.fetchCatalogData(request, attempts: 1)
                            let response = try JSONDecoder().decode(CatalogResponse.self, from: catalogData)
                            return (catalog, response)
                        } catch {
                            continue
                        }
                    }
                    return (catalog, nil)
                }
            }

            for task in tasks {
                let (catalog, response) = await task.value
                guard let response else { continue }
                let type = catalog.type ?? "movie"
                let id = catalog.id ?? "popular"
                let cleanName = cleanAllInOneRowTitle(catalog.name ?? id.capitalized)
                let items = mappedItems(
                    from: response.metas ?? [],
                    type: type,
                    catalogName: cleanName,
                    forceDeclaredType: isOfficialRequest
                )
                if !items.isEmpty {
                    builtRows.append(MediaRow(
                        id: "\(type)-\(id)-\(manifest.name ?? "manifest")",
                        title: cleanName,
                        items: items,
                        presentation: catalog.debridChannels
                    ))
                }
            }
        }
        let repairedRows = isOfficialRequest
            ? repairedOfficialCatalogRows(builtRows, catalogs: catalogs, manifestName: manifest.name ?? "manifest")
            : builtRows
        var readyRows = isOfficialRequest
            ? try validatedOfficialCatalogRows(repairedRows, expectedRowCount: catalogs.count)
            : repairedRows
        if isOfficialRequest, forceCompleteRows {
            readyRows = await fullyHydratedOfficialRows(seedRows: readyRows)
            readyRows = try validatedOfficialCatalogRows(readyRows, expectedRowCount: catalogs.count)
        }
        return (manifest.name ?? "manifest", addonKind(from: manifest), readyRows)
    }


    private static func isSeriesLikeForEpisodeAlerts(_ item: MediaItem) -> Bool {
        let lowerType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return item.seasonNumber != nil
            || item.episodeNumber != nil
            || lowerType.contains("series")
            || lowerType.contains("show")
            || lowerType.contains("episode")
            || lowerType == "tv"
    }

    private static func normalizedAlertTitle(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func strippedTVMazeSummary(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tvMazeShow(for item: MediaItem) async -> TVMazeShow? {
        var candidates: [URL] = []
        if let rawTVDB = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let tvdb = rawTVDB.filter(\.isNumber)
            if !tvdb.isEmpty, let url = URL(string: "https://api.tvmaze.com/lookup/shows?thetvdb=\(tvdb)") {
                candidates.append(url)
            }
        }
        if let rawIMDb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines),
           let range = rawIMDb.range(of: #"tt\d+"#, options: [.regularExpression, .caseInsensitive]) {
            let imdb = String(rawIMDb[range]).lowercased()
            if let url = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdb)") {
                candidates.append(url)
            }
        }

        for url in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/1053 EpisodeAlerts", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) { continue }
                if let show = try? JSONDecoder().decode(TVMazeShow.self, from: data) { return show }
            } catch {
                if Task.isCancelled { return nil }
            }
        }

        guard var components = URLComponents(string: "https://api.tvmaze.com/search/shows") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: item.title)]
        guard let searchURL = components.url else { return nil }
        do {
            var request = URLRequest(url: searchURL, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/1053 EpisodeAlerts", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            let results = try JSONDecoder().decode([TVMazeSearchResult].self, from: data)
            let targetTitle = Self.normalizedAlertTitle(item.title)
            let targetYear = String(item.year.prefix(4))
            let exact = results.first { result in
                let titleMatches = Self.normalizedAlertTitle(result.show.name) == targetTitle
                let yearMatches = targetYear.isEmpty || String((result.show.premiered ?? "").prefix(4)) == targetYear
                return titleMatches && yearMatches
            }
            if let exact { return exact.show }
            return results.first(where: {
                Self.normalizedAlertTitle($0.show.name) == targetTitle && ($0.score ?? 0) >= 0.70
            })?.show
        } catch {
            return nil
        }
    }

    private func fetchTVMazeEpisodesForAlerts(for item: MediaItem) async -> [MediaItem] {
        guard Self.isSeriesLikeForEpisodeAlerts(item), let show = await tvMazeShow(for: item),
              let url = URL(string: "https://api.tvmaze.com/shows/\(show.id)/episodes") else { return [] }
        do {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/1053 EpisodeAlerts", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return [] }
            let decoded = try JSONDecoder().decode([TVMazeEpisode].self, from: data)
            return decoded.compactMap { episode in
                guard episode.season > 0, let number = episode.number, number > 0 else { return nil }
                let dateStrings = [episode.airdate, episode.airstamp]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let still = episode.image?.original ?? episode.image?.medium
                let summary = Self.strippedTVMazeSummary(episode.summary)
                return MediaItem(
                    id: "tvmaze:\(episode.id)",
                    tmdbId: item.tmdbId,
                    imdbId: item.imdbId,
                    tvdbId: item.tvdbId,
                    title: "\(item.title)  S\(String(format: "%02d", episode.season))E\(String(format: "%02d", number))  \(episode.name)",
                    year: item.year,
                    type: "series",
                    catalog: "Season \(episode.season)",
                    description: summary.isEmpty ? item.description : summary,
                    genres: item.genres,
                    rating: item.rating,
                    posterURL: Self.highest(still ?? item.posterURL),
                    landscapeURL: Self.highest(still ?? item.landscapeURL ?? item.posterURL),
                    logoURL: item.logoURL,
                    previewURL: Self.highest(still),
                    addonName: "TVMaze",
                    addonIconURL: item.addonIconURL,
                    seasonNumber: episode.season,
                    episodeNumber: number,
                    // Exact episode credits are hydrated on selection. Do not stamp the
                    // parent-series cast onto every episode before that request runs.
                    cast: [],
                    directors: [],
                    castMembers: [],
                    airDateString: dateStrings.first,
                    episodeDateStrings: dateStrings
                )
            }.sorted { lhs, rhs in
                if (lhs.seasonNumber ?? 0) != (rhs.seasonNumber ?? 0) { return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0) }
                return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
            }
        } catch {
            return []
        }
    }

    private func fetchVerifiedEpisodeAlertEpisodes(for item: MediaItem) async -> [MediaItem] {
        let tvMaze = await fetchTVMazeEpisodesForAlerts(for: item)
        if !tvMaze.isEmpty { return tvMaze }
        return await fetchSeriesEpisodes(for: item, publishStatus: false)
    }

    func fetchSeriesEpisodes(for item: MediaItem, publishStatus: Bool = true) async -> [MediaItem] {
        guard Self.isSeriesLikeForEpisodeAlerts(item) else { return [] }

        // v1141 physical-test correction: VOD opens this browser from the currently
        // playing episode, whose title/id can be exact-episode shaped (for example
        // "Reacher S03E03 …" / "tt…:3:3"). Series metadata endpoints need the parent
        // identity instead. Normalize only the lookup copy; the current playback item
        // remains untouched.
        var seriesItem = item
        if item.seasonNumber != nil || item.episodeNumber != nil {
            // MediaItem.id is intentionally immutable. Build a parent-series lookup
            // value rather than mutating the playing episode identity in place.
            seriesItem = MediaItem(
                id: streamParentBaseID(from: item.id),
                tmdbId: item.tmdbId,
                imdbId: item.imdbId,
                tvdbId: item.tvdbId,
                title: Self.parentSeriesTitleForEpisodeLookup(item.title),
                year: item.year,
                type: item.type,
                catalog: item.catalog,
                description: item.description,
                genres: item.genres,
                rating: item.rating,
                posterURL: item.posterURL,
                landscapeURL: item.landscapeURL,
                logoURL: item.logoURL,
                previewURL: item.previewURL,
                addonName: item.addonName,
                addonIconURL: item.addonIconURL,
                seasonNumber: nil,
                episodeNumber: nil,
                cast: item.cast,
                directors: item.directors,
                castMembers: item.castMembers,
                airDateString: nil,
                episodeDateStrings: [],
                franchiseItems: item.franchiseItems
            )
        }

        if publishStatus { status = "Loading all seasons and episodes for \(seriesItem.title)…" }
        let idCandidates = streamIDCandidates(for: seriesItem)
        var episodes: [MediaItem] = []
        var seen = Set<String>()

        for rawManifest in prioritizedManifestURLsWithMetadataFallback() {
            guard !Task.isCancelled else { return [] }
            for candidate in manifestURLCandidates(from: rawManifest) {
                guard !Task.isCancelled else { return [] }
                guard let manifestURL = URL(string: candidate) else { continue }
                let base = normalizedStremioBase(from: manifestURL.absoluteString)
                for seriesID in idCandidates {
                    guard !Task.isCancelled else { return [] }
                    guard let encodedID = seriesID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                          let metaURL = URL(string: "\(base)/meta/series/\(encodedID).json") else { continue }
                    do {
                        var request = URLRequest(url: metaURL, timeoutInterval: 12)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("DebridChannels-tvOS/968 EpisodeAlerts", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                        let decoded = try JSONDecoder().decode(StremioMetaResponse.self, from: data)
                        let meta = decoded.meta
                        for video in meta?.videos ?? [] {
                            guard let videoID = video.id?.trimmingCharacters(in: .whitespacesAndNewlines), !videoID.isEmpty else { continue }
                            let season = video.season ?? 1
                            let episodeTitle = video.title ?? video.name ?? "Episode \(video.episode ?? 1)"
                            let specialTitle = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            guard season > 0, specialTitle != "special", specialTitle != "specials", specialTitle != "season 0" else { continue }
                            guard seen.insert(videoID).inserted else { continue }
                            let episode = video.episode ?? (episodes.filter { $0.seasonNumber == season }.count + 1)
                            let episodeDateCandidates = Self.episodeDateStrings(from: video)
                            let airDate = episodeDateCandidates.first
                            episodes.append(MediaItem(
                                id: videoID,
                                tmdbId: seriesItem.tmdbId,
                                imdbId: seriesItem.imdbId,
                                tvdbId: seriesItem.tvdbId,
                                title: "\(seriesItem.title)  S\(String(format: "%02d", season))E\(String(format: "%02d", episode))  \(episodeTitle)",
                                year: seriesItem.year,
                                type: "series",
                                catalog: "Season \(season)",
                                description: video.overview ?? video.description ?? seriesItem.description,
                                genres: seriesItem.genres,
                                rating: seriesItem.rating,
                                // v569: episode cards need real episode stills/previews, not the repeated
                                // parent show backdrop.  Prefer Stremio/TMDB video thumbnails anywhere the
                                // episode UI asks for poster, landscape, or preview art.
                                posterURL: Self.highest(video.thumbnail ?? seriesItem.posterURL),
                                landscapeURL: Self.highest(video.thumbnail ?? seriesItem.landscapeURL ?? seriesItem.posterURL),
                                logoURL: seriesItem.logoURL,
                                previewURL: Self.highest(video.thumbnail ?? video.url ?? video.src ?? video.source),
                                addonName: seriesItem.addonName,
                                addonIconURL: seriesItem.addonIconURL,
                                seasonNumber: season,
                                episodeNumber: episode,
                                cast: [],
                                directors: [],
                                castMembers: [],
                                airDateString: airDate,
                                episodeDateStrings: episodeDateCandidates
                            ))
                        }
                        if !episodes.isEmpty {
                            // v1141: configured Stremio metadata can legally expose only
                            // one season even when the series has many. Merge it with the
                            // key-free TVMaze complete-series endpoint by exact S/E identity.
                            // Stremio wins duplicate metadata so its canonical episode IDs
                            // remain first-class resolver inputs; TVMaze fills missing seasons.
                            let tvMazeEpisodes = await fetchTVMazeEpisodesForAlerts(for: seriesItem)
                            let sorted = mergedCompleteSeriesEpisodes(primary: episodes, fallback: tvMazeEpisodes)
                            if publishStatus { status = "Loaded \(sorted.count) episode(s) across \(Set(sorted.compactMap(\.seasonNumber)).count) season(s) for \(seriesItem.title)." }
                            return sorted
                        }
                    } catch {
                        if Task.isCancelled { return [] }
                        continue
                    }
                }
            }
        }
        // No configured Stremio provider returned videos. TVMaze is already used by
        // Debrid Channels for verified episode-alert metadata and exposes the complete
        // series episode inventory, so use it as a real key-free fallback here too.
        let tvMazeEpisodes = await fetchTVMazeEpisodesForAlerts(for: seriesItem)
        if !tvMazeEpisodes.isEmpty {
            let sorted = mergedCompleteSeriesEpisodes(primary: [], fallback: tvMazeEpisodes)
            if publishStatus { status = "Loaded \(sorted.count) episode(s) across \(Set(sorted.compactMap(\.seasonNumber)).count) season(s) for \(seriesItem.title) from TVMaze fallback metadata." }
            return sorted
        }
        if publishStatus { status = "No complete episode list was returned for \(seriesItem.title)." }
        return []
    }

    private func mergedCompleteSeriesEpisodes(primary: [MediaItem], fallback: [MediaItem]) -> [MediaItem] {
        var byEpisode: [String: MediaItem] = [:]
        func key(_ episode: MediaItem) -> String? {
            guard let season = episode.seasonNumber, let number = episode.episodeNumber,
                  season > 0, number > 0 else { return nil }
            return "s\(season)e\(number)"
        }
        for episode in fallback {
            if let episodeKey = key(episode) { byEpisode[episodeKey] = episode }
        }
        // Primary provider metadata replaces fallback values for the same episode.
        for episode in primary {
            if let episodeKey = key(episode) { byEpisode[episodeKey] = episode }
        }
        return byEpisode.values.sorted { lhs, rhs in
            if (lhs.seasonNumber ?? 0) != (rhs.seasonNumber ?? 0) {
                return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0)
            }
            return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
        }
    }

    // v621: Search result cards may be TMDB/Cinemeta artwork shells. Before Source
    // Intelligence scans streams, upgrade them to the best resolver identity available
    // so configured Stremio addons are always queried with IMDb/Cinemeta/addon ids.
    func resolverReadyStreamItem(for item: MediaItem, tmdbApiKey: String, publishStatus: Bool = true) async -> MediaItem {
        await searchHydratedDetailItem(for: item, query: item.title, tmdbApiKey: tmdbApiKey, publishStatus: publishStatus)
    }

    // v621: app-open/resume verified episode alert scan. tvOS cannot run this while
    // force-closed, so we scan followed shows whenever the app launches/resumes.
    func rememberFollowedShow(_ item: MediaItem) {
        let key = Self.followedShowKey(for: item)
        let legacyKey = Self.legacyFollowedShowKey(for: item)
        var snapshots = followedShowSnapshotMap()
        snapshots[key] = FollowedShowSnapshot(item: item)
        if legacyKey != key { snapshots.removeValue(forKey: legacyKey) }
        persistFollowedShowSnapshotMap(snapshots)
    }

    func forgetFollowedShow(_ item: MediaItem) {
        var snapshots = followedShowSnapshotMap()
        for key in Self.followedShowKeyAliases(for: item) {
            snapshots.removeValue(forKey: key)
        }
        persistFollowedShowSnapshotMap(snapshots)
    }

    private func followedShowSnapshotMap() -> [String: FollowedShowSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: followedShowSnapshotsKey),
              let decoded = try? JSONDecoder().decode([String: FollowedShowSnapshot].self, from: data) else { return [:] }
        return decoded
    }

    private func persistFollowedShowSnapshotMap(_ snapshots: [String: FollowedShowSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: followedShowSnapshotsKey)
    }


    /// v1053: catalog identity changes and restore-code installs can leave followed IDs
    /// without a matching durable snapshot. Rebuild those snapshots from any currently
    /// loaded row before scanning so alerts no longer depend on toggling catalogs or
    /// relaunching the app.
    @discardableResult
    func repairFollowedShowSnapshotsFromLoadedRows() -> Int {
        let raw = UserDefaults.standard.string(forKey: "followedShowIds") ?? ""
        let followed = Set(raw.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        guard !followed.isEmpty else { return 0 }

        var snapshots = followedShowSnapshotMap()
        var changes = 0
        for item in rows.flatMap(\.items) where Self.isSeriesLikeForEpisodeAlerts(item) {
            let aliases = Self.followedShowKeyAliases(for: item)
            guard !followed.isDisjoint(with: aliases) else { continue }
            let canonical = Self.followedShowKey(for: item)
            let candidate = FollowedShowSnapshot(item: item)
            let existing = snapshots[canonical]?.mediaItem
            let existingScore = existing.map(Self.episodeAlertSnapshotScore) ?? -1
            let candidateScore = Self.episodeAlertSnapshotScore(item)
            if existing == nil || candidateScore > existingScore {
                snapshots[canonical] = candidate
                changes += 1
            }
            for alias in aliases where alias != canonical {
                if snapshots.removeValue(forKey: alias) != nil { changes += 1 }
            }
        }
        if changes > 0 { persistFollowedShowSnapshotMap(snapshots) }
        return changes
    }

    private static func episodeAlertSnapshotScore(_ item: MediaItem) -> Int {
        var score = 0
        if item.imdbId?.isEmpty == false { score += 12 }
        if item.tvdbId?.isEmpty == false { score += 10 }
        if item.tmdbId?.isEmpty == false { score += 8 }
        if !item.id.isEmpty { score += 4 }
        if item.posterURL?.isEmpty == false { score += 2 }
        if item.landscapeURL?.isEmpty == false { score += 2 }
        if !item.description.isEmpty { score += 1 }
        return score
    }

    @MainActor
    func runFollowedEpisodeAlertScan(reason: String) async -> [NewEpisodeAlertHit] {
        let report = await runFollowedEpisodeAlertScanReport(reason: reason)
        return report.hits
    }

    @MainActor
    func runFollowedEpisodeAlertScanReport(reason: String) async -> NewEpisodeAlertScanReport {
        // v835: production alert hardening. Keep a wider forgiving window so alerts
        // still fire after app downtime, addon clock drift, UTC date rollover, or late
        // metadata updates. Duplicate suppression still keys the newest episode per show.
        let recentWindowDays = 45
        let raw = UserDefaults.standard.string(forKey: "followedShowIds") ?? ""
        let followed = Set(raw.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        var report = NewEpisodeAlertScanReport(recentWindowDays: recentWindowDays, followedKeysCount: followed.count)
        guard !followed.isEmpty else {
            report.scanCompletedSuccessfully = true
            report.scanOutcome = "No followed shows"
            return report
        }
        _ = repairFollowedShowSnapshotsFromLoadedRows()
        let all = rows.flatMap { $0.items }
        let visibleMatches = all.filter { show in
            !followed.isDisjoint(with: Self.followedShowKeyAliases(for: show))
        }
        let snapshots = followedShowSnapshotMap()
        report.followedSnapshotCount = snapshots.count
        var followedItems: [MediaItem] = []
        var seenShowKeys = Set<String>()
        for show in visibleMatches {
            let key = Self.followedShowKey(for: show)
            if seenShowKeys.insert(key).inserted { followedItems.append(show) }
        }
        // v967: old builds stored snapshots as id::catalog::type while newer Follow
        // Center UI stores catalog-independent media keys. Match both aliases and
        // normalize every item to the canonical key before scanning.
        for snapshot in snapshots.values {
            let show = snapshot.mediaItem
            guard !followed.isDisjoint(with: Self.followedShowKeyAliases(for: show)) else { continue }
            let key = Self.followedShowKey(for: show)
            if seenShowKeys.insert(key).inserted { followedItems.append(show) }
        }
        report.followedShowsMatchedInLoadedRows = visibleMatches.count
        guard !followedItems.isEmpty else {
            report.scanCompletedSuccessfully = false
            report.scanOutcome = "Followed identities exist, but no matching snapshot or loaded catalog item was available"
            report.metadataFetchFailureCount = followed.count
            if playbackURL == nil && selectedTab == .settings { status = "Episode alert scan (\(reason)): followed shows will be checked after catalogs load." }
            return report
        }
        var hits: [NewEpisodeAlertHit] = []
        // v835: scan every followed snapshot we have, not only the first visible page.
        // The follow list is user-curated and small; skipping after 30 made alerts feel
        // unreliable for users with many followed shows from multiple catalogs.
        for show in followedItems {
            // v1086: keep the always-on scanner cooperative with KSPlayer and focus/UI
            // work. This yields between followed shows without pausing or postponing scans.
            await Task.yield()
            guard !Task.isCancelled else {
                report.scanCompletedSuccessfully = false
                report.scanOutcome = "Scan cancelled before completion"
                return report
            }
            report.showsChecked += 1
            report.metadataFetchAttempted = true
            // v830: followed snapshots may come from TMDB/search/custom catalogs and lack the
            // exact Stremio/Cinemeta resolver id needed for /meta/series/{id}.json. Hydrate the
            // show before scanning so episode alerts use the same resolver identity as playback.
            // v968: trust the followed snapshot first. Most followed items already carry
            // the correct IMDb/Stremio identity, so a broad configured-addon search before
            // every scan only adds latency and another failure point. Hydrate only when the
            // direct snapshot cannot return an episode list, then retry once.
            var hydratedAlertShow = show
            var episodes = await fetchVerifiedEpisodeAlertEpisodes(for: show)
            if episodes.isEmpty {
                let tmdbKey = UserDefaults.standard.string(forKey: "tmdbApiKey") ?? ""
                hydratedAlertShow = await resolverReadyStreamItem(for: show, tmdbApiKey: tmdbKey, publishStatus: false)
                if hydratedAlertShow.id != show.id || hydratedAlertShow.imdbId != show.imdbId || hydratedAlertShow.tvdbId != show.tvdbId {
                    episodes = await fetchVerifiedEpisodeAlertEpisodes(for: hydratedAlertShow)
                }
            }
            report.episodesFetchedCount += episodes.count
            if !episodes.isEmpty {
                report.metadataFetchSuccessCount += 1
            } else {
                report.metadataFetchFailureCount += 1
            }
            let eligibility = Self.bestEpisodeInRecentWindow(from: episodes, days: recentWindowDays)
            report.missingDateCount += eligibility.missingDateCount
            report.dateParseSuccessCount += eligibility.parseSuccessCount
            report.dateParseFailedCount += eligibility.parseFailedCount
            if let newest = eligibility.newestParsedDate, report.newestParsedDate == "None" || newest > report.newestParsedDate {
                report.newestParsedDate = newest
                report.newestRawDateStringSeen = eligibility.newestRawDateStringSeen ?? "None"
            }
            guard let eligible = eligibility.eligible else { continue }
            let episode = eligible.episode
            report.recentEpisodeDetected = true
            if eligible.dateKey == Self.todayKey() { report.newerTodayEpisodeDetected = true }
            if report.newestEligibleEpisodeDate == "None" || eligible.dateKey > report.newestEligibleEpisodeDate {
                report.newestEligibleEpisodeDate = eligible.dateKey
            }
            let showKey = Self.followedShowKey(for: show)
            let showKeyAliases = Self.followedShowKeyAliases(for: show)
            let episodeKey = Self.episodeAlertProgressKey(showKey: showKey, episode: episode, dateKey: eligible.dateKey)
            report.newestDetectedEpisodeKey = episodeKey
            let lastAlertedCandidates = showKeyAliases.compactMap { alias -> String? in
                let value = UserDefaults.standard.string(forKey: Self.lastAlertedEpisodeKey(forShowKey: alias)) ?? ""
                guard !value.isEmpty else { return nil }
                return Self.normalizedEpisodeAlertProgressKey(value, storedShowKey: alias, canonicalShowKey: showKey)
            }
            let lastAlerted = lastAlertedCandidates.max() ?? ""
            if !lastAlerted.isEmpty {
                report.lastAlertedEpisodeKeyForShow = lastAlerted
                UserDefaults.standard.set(lastAlerted, forKey: Self.lastAlertedEpisodeKey(forShowKey: showKey))
            }
            guard lastAlerted.isEmpty || episodeKey > lastAlerted else {
                report.alreadyAlertedCount += 1
                report.suppressedDuplicateCount += 1
                if episodeKey == lastAlerted { report.suppressedSameEpisodeCount += 1 }
                continue
            }
            let alertKey = "episodeAlertShown::\(showKey)::\(episode.id)"
            let wasAlreadyShown = showKeyAliases.contains { alias in
                UserDefaults.standard.bool(forKey: "episodeAlertShown::\(alias)::\(episode.id)")
            }
            guard !wasAlreadyShown else {
                report.eligibleButConsumedCount += 1
                report.suppressedDuplicateCount += 1
                UserDefaults.standard.set(true, forKey: alertKey)
                continue
            }
            // v835: keep the stored followed-show identity on the alert hit so
            // markEpisodeAlertPresented() writes the same per-show progress key that
            // runFollowedEpisodeAlertScanReport() checks on the next scan. The hydrated
            // item is still used for metadata fetching, artwork, and source reporting.
            let alertShow = Self.alertPresentationShow(original: show, hydrated: hydratedAlertShow)
            hits.append(NewEpisodeAlertHit(alertKey: alertKey, show: alertShow, episode: episode))
            let source = [hydratedAlertShow.addonName, hydratedAlertShow.catalog, show.addonName, show.catalog].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? "Unknown"
            report.hitSourceSummaries.append("\(alertShow.title): \(source)")
        }
        report.hits = hits
        report.alertQueuedCount = hits.count
        report.returnedAlertHits = hits.count
        report.scanCompletedSuccessfully = report.showsChecked > 0 && report.metadataFetchFailureCount == 0
        report.scanWasPartial = report.metadataFetchSuccessCount > 0 && report.metadataFetchFailureCount > 0
        if report.scanCompletedSuccessfully {
            report.scanOutcome = hits.isEmpty
                ? "All followed shows checked; no new eligible episodes"
                : "All followed shows checked; \(hits.count) alert(s) ready"
        } else if report.scanWasPartial {
            report.scanOutcome = "\(report.metadataFetchSuccessCount) show(s) checked, \(report.metadataFetchFailureCount) metadata lookup(s) failed"
        } else {
            report.scanOutcome = "No followed-show metadata source returned an episode list"
        }
        if playbackURL == nil && selectedTab == .settings {
            if report.scanCompletedSuccessfully {
                status = hits.isEmpty ? "Episode alert scan (\(reason)): no verified new episodes today." : "Episode alert scan (\(reason)): found \(hits.count) new alert(s)."
            } else {
                status = "Episode alert scan (\(reason)) incomplete: \(report.scanOutcome). A reliability retry is scheduled."
            }
        }
        return report
    }

    func markEpisodeAlertConsumed(_ hit: NewEpisodeAlertHit) {
        UserDefaults.standard.set(true, forKey: hit.alertKey)
        markEpisodeAlertPresented(hit)
    }

    func markEpisodeAlertPresented(_ hit: NewEpisodeAlertHit) {
        let showKey = Self.followedShowKey(for: hit.show)
        let rawDate = Self.alertEpisodeDateString(for: hit.episode)
        let parsedDate = Self.parseEpisodeAirDate(rawDate).map(Self.episodeDateKey) ?? rawDate
        let episodeKey = Self.episodeAlertProgressKey(showKey: showKey, episode: hit.episode, dateKey: parsedDate)
        UserDefaults.standard.set(episodeKey, forKey: Self.lastAlertedEpisodeKey(forShowKey: showKey))
    }

    private static func alertPresentationShow(original: MediaItem, hydrated: MediaItem) -> MediaItem {
        MediaItem(
            id: original.id,
            tmdbId: hydrated.tmdbId ?? original.tmdbId,
            imdbId: hydrated.imdbId ?? original.imdbId,
            tvdbId: hydrated.tvdbId ?? original.tvdbId,
            title: hydrated.title.isEmpty ? original.title : hydrated.title,
            year: hydrated.year.isEmpty ? original.year : hydrated.year,
            type: original.type,
            catalog: original.catalog,
            description: hydrated.description.isEmpty ? original.description : hydrated.description,
            genres: hydrated.genres.isEmpty ? original.genres : hydrated.genres,
            rating: hydrated.rating.isEmpty ? original.rating : hydrated.rating,
            posterURL: hydrated.posterURL ?? original.posterURL,
            landscapeURL: hydrated.landscapeURL ?? original.landscapeURL,
            logoURL: hydrated.logoURL ?? original.logoURL,
            previewURL: hydrated.previewURL ?? original.previewURL,
            addonName: hydrated.addonName ?? original.addonName,
            addonIconURL: hydrated.addonIconURL ?? original.addonIconURL,
            seasonNumber: original.seasonNumber,
            episodeNumber: original.episodeNumber,
            cast: hydrated.cast.isEmpty ? original.cast : hydrated.cast,
            directors: hydrated.directors.isEmpty ? original.directors : hydrated.directors,
            castMembers: hydrated.castMembers.isEmpty ? original.castMembers : hydrated.castMembers,
            airDateString: original.airDateString,
            episodeDateStrings: original.episodeDateStrings,
            franchiseItems: hydrated.franchiseItems.isEmpty ? original.franchiseItems : hydrated.franchiseItems
        )
    }

    private static func followedShowKey(for item: MediaItem) -> String {
        mediaFavoriteKey(item)
    }

    private static func legacyFollowedShowKey(for item: MediaItem) -> String {
        "\(item.id)::\(item.catalog)::\(item.type)"
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func followedShowKeyAliases(for item: MediaItem) -> Set<String> {
        [followedShowKey(for: item), legacyFollowedShowKey(for: item)]
    }

    private static func normalizedEpisodeAlertProgressKey(_ value: String, storedShowKey: String, canonicalShowKey: String) -> String {
        let prefix = "\(storedShowKey)::"
        guard value.hasPrefix(prefix) else { return value }
        return "\(canonicalShowKey)::" + value.dropFirst(prefix.count)
    }

    private static func episodeAlertProgressKey(showKey: String, episode: MediaItem, dateKey: String) -> String {
        let season = String(format: "%04d", episode.seasonNumber ?? 0)
        let number = String(format: "%04d", episode.episodeNumber ?? 0)
        return "\(showKey)::D\(dateKey)::S\(season)::E\(number)"
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func lastAlertedEpisodeKey(forShowKey showKey: String) -> String {
        "episodeAlertLastAlerted::\(showKey)"
    }

    // vBRDC119: the episode-alert scanner can evaluate hundreds/thousands of episode rows
    // in one pass. Rebuilding two ISO parsers plus eleven DateFormatters for every row was
    // pure CPU/allocation churn. These parser objects are shared behind one lock so the
    // accepted date formats and local-day semantics stay identical without repeated setup.
    private static let episodeAlertDateParserLock = NSLock()
    private static let episodeAlertFractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let episodeAlertISOFormatter = ISO8601DateFormatter()
    private static let episodeAlertDayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let episodeAlertAirDateFormatters: [DateFormatter] = [
        "yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "M/d/yyyy", "dd/MM/yyyy", "d/M/yyyy",
        "yyyy.MM.dd", "MMM d, yyyy", "MMMM d, yyyy", "MMM dd, yyyy", "MMMM dd, yyyy"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    private static func todayKey() -> String {
        episodeAlertDateParserLock.lock()
        defer { episodeAlertDateParserLock.unlock() }
        return episodeAlertDayKeyFormatter.string(from: Date())
    }

    private static func firstEpisodeDateString(from video: StremioVideo) -> String? {
        episodeDateStrings(from: video).first
    }

    private static func episodeDateStrings(from video: StremioVideo) -> [String] {
        ([video.released, video.firstAired, video.airDate, video.premiereDate, video.release_date, video.first_aired, video.air_date] + video.additionalEpisodeDateStrings.map { Optional($0) })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func bestEpisodeInRecentWindow(from episodes: [MediaItem], days: Int) -> (eligible: (episode: MediaItem, dateKey: String)?, newestRawDateStringSeen: String?, newestParsedDate: String?, missingDateCount: Int, parseSuccessCount: Int, parseFailedCount: Int) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: todayStart) ?? todayStart
        // v835: allow a small future grace window for UTC/date-line addon metadata,
        // but do not announce far-future episodes.
        let futureGraceEnd = calendar.date(byAdding: .day, value: 2, to: todayStart) ?? Date()
        var newestRawDateStringSeen: String? = nil
        var newestParsedDate: String? = nil
        var missingDateCount = 0
        var parseSuccessCount = 0
        var parseFailedCount = 0

        let parsedEpisodes = episodes.compactMap { ep -> (MediaItem, Date, String)? in
            let raw = Self.alertEpisodeDateString(for: ep)
            guard !raw.isEmpty else {
                missingDateCount += 1
                return nil
            }
            guard let date = parseEpisodeAirDate(raw) else {
                parseFailedCount += 1
                return nil
            }
            parseSuccessCount += 1
            let localDay = calendar.startOfDay(for: date)
            let dateKey = episodeDateKey(localDay)
            if newestParsedDate == nil || dateKey > (newestParsedDate ?? "") {
                newestParsedDate = dateKey
                newestRawDateStringSeen = raw
            }
            return (ep, localDay, dateKey)
        }

        let airedOrGrace = parsedEpisodes.filter { $0.1 < futureGraceEnd }
        let maxKnownSeason = airedOrGrace.compactMap { $0.0.seasonNumber }.filter { $0 > 0 }.max()
        let latestSeasonEpisodes: [(MediaItem, Date, String)]
        if let maxKnownSeason {
            latestSeasonEpisodes = airedOrGrace.filter { ($0.0.seasonNumber ?? 0) == maxKnownSeason }
        } else {
            latestSeasonEpisodes = airedOrGrace
        }

        let eligiblePool = latestSeasonEpisodes.filter { $0.1 >= windowStart && $0.1 < futureGraceEnd }
        let eligible = eligiblePool.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let ls = lhs.0.seasonNumber ?? 0, rs = rhs.0.seasonNumber ?? 0
            if ls != rs { return ls > rs }
            let le = lhs.0.episodeNumber ?? 0, re = rhs.0.episodeNumber ?? 0
            if le != re { return le > re }
            return lhs.0.id > rhs.0.id
        }.first.map { (episode: $0.0, dateKey: $0.2) }
        return (eligible, newestRawDateStringSeen, newestParsedDate, missingDateCount, parseSuccessCount, parseFailedCount)
    }

    private static func alertEpisodeDateString(for episode: MediaItem) -> String {
        ([episode.airDateString] + episode.episodeDateStrings.map { Optional($0) })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func episodeDateKey(_ date: Date) -> String {
        episodeAlertDateParserLock.lock()
        defer { episodeAlertDateParserLock.unlock() }
        return episodeAlertDayKeyFormatter.string(from: date)
    }

    private static func parseEpisodeAirDate(_ raw: String?) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        episodeAlertDateParserLock.lock()
        defer { episodeAlertDateParserLock.unlock() }
        if let d = episodeAlertFractionalISOFormatter.date(from: value) { return d }
        if let d = episodeAlertISOFormatter.date(from: value) { return d }
        for formatter in episodeAlertAirDateFormatters {
            if let d = formatter.date(from: value) { return d }
        }
        return nil
    }

    private static func sendEpisodeNotification(show: MediaItem, episode: MediaItem) {
        let season = episode.seasonNumber.map { "S\($0)" } ?? ""
        let ep = episode.episodeNumber.map { "E\($0)" } ?? ""
        let message = "\(show.title) \(season)\(ep) is available today."
        #if os(tvOS)
        // tvOS does not expose UNMutableNotificationContent.title/body/sound the same way iOS does.
        // Keep the app-open/resume scanner active and log the verified alert hit; the in-app Details alert UI remains the tvOS-safe presentation path.
        print("New Episode Alert: \(message)")
        #else
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "New Episode Alert"
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: "episode_alert_\(show.id)_\(episode.id)_\(todayKey())", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.add(request)
        }
        #endif
    }

    func loadManifest(urlString: String) async {
        guard !vodExclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return }
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            status = "Enter a valid Stremio manifest URL."
            return
        }
        if !allInOneCatalogsEnabled, isAllInOneManifestURL(clean) {
            status = "All-in-One Catalogs are turned off. Turn the setting on before loading this server."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await fetchRows(from: clean)
            if result.rows.isEmpty {
                status = result.kind == "stream-only" ? "Added stream-only addon \(result.name). It will work in Find Links but does not create Home rows." : "No catalog rows returned from \(result.name). Existing rows kept."
            } else if allInOneCatalogsEnabled && !isAllInOneManifestURL(clean) {
                // Phase 12A: testing/loading a personal URL must never replace the
                // enabled built-in catalog. The URL remains saved for use when the
                // person turns All-in-One off.
                status = "Loaded \(result.name) successfully. Your built-in catalog remains visible; turn All-in-One off to browse this personal catalog."
            } else if updateVisibleCatalogRows(result.rows) {
                status = "Loaded \(result.rows.count) rows from \(result.name)."
            } else {
                status = "The returned catalog was incomplete. Existing rows kept."
            }
        } catch {
            status = "Catalog load failed: \(error.localizedDescription)"
        }
    }

    static func firstYear(from releaseInfo: String?) -> String {
        guard let text = releaseInfo,
              let range = text.range(of: #"\b(?:18|19|20)\d{2}\b"#, options: .regularExpression) else { return "" }
        return String(text[range])
    }

    static func previewURL(from meta: StremioMeta) -> String? {
        if let direct = meta.previewVideo, direct.hasPrefix("http") { return direct }
        if let direct = meta.preview, direct.hasPrefix("http") { return direct }
        if let direct = meta.trailer, direct.hasPrefix("http") { return direct }
        if let yt = meta.trailers?.compactMap({ trailer -> String? in
            let source = trailer.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !source.isEmpty else { return nil }
            if source.hasPrefix("http") { return source }
            if source.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil {
                return "https://www.youtube.com/watch?v=\(source)"
            }
            return nil
        }).first { return yt }
        if let video = meta.videos?.first(where: { ($0.url ?? $0.src ?? $0.source ?? "").hasPrefix("http") }) {
            return video.url ?? video.src ?? video.source
        }
        // Some Stremio manifests expose YouTube trailer IDs; those are kept as metadata only
        // because Internal player needs a direct playable video URL.
        return nil
    }

    static func highest(_ url: String?) -> String? {
        PremiumArtworkURL.upgraded(url)
    }

    static func demoRows() -> [MediaRow] {
        // v838: production startup must never publish sample/demo catalog artwork.
        // Real catalog rows come from saved Stremio/TMDB providers or the persisted
        // catalog cache only.
        return []
    }

}
