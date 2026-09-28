import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TraktPersonalTitleStatus: Hashable {
    let inWatchlist: Bool
    let isFavorite: Bool
    let recentlyWatched: Bool
}

/// vBRDC196: Account-scoped Trakt catalog fabric. Trakt supplies list/order/identity;
/// Debrid Channels keeps ownership of cards, metadata, details and playback.
/// Trakt image CDN URLs are intentionally not hotlinked. Existing Debrid Channels artwork
/// is reused first; only unmatched Trakt identities receive a bounded TMDB metadata lookup.
final class TraktCatalogService {
    static let shared = TraktCatalogService()

    private struct Seed: Hashable {
        let key: String
        let kind: String          // movie | show
        let title: String
        let year: Int?
        let traktID: Int?
        let imdbID: String?
        let tmdbID: Int?
        let tvdbID: Int?
        let overview: String
        let genres: [String]
        let rating: Double?
        let season: Int?
        let episode: Int?
    }

    private struct Endpoint {
        let id: String
        let title: String
        let kind: String
        let path: String
        let authenticated: Bool
        let personalBucket: String?
    }

    private struct RelatedCacheEntry {
        let createdAt: Date
        let items: [MediaItem]
    }

    private let lock = NSLock()
    private var watchlistKeys = Set<String>()
    private var favoriteKeys = Set<String>()
    private var recentKeys = Set<String>()
    private var relatedCache: [String: RelatedCacheEntry] = [:]
    private var tmdbResolvedCache: [String: MediaItem] = [:]
    // vBRDC202: Trakt refreshes can touch hundreds of identities over a long session.
    // Keep metadata helpers bounded so account browsing never becomes an unbounded
    // process-lifetime memory owner.
    private let relatedCacheLimit = 32
    private let tmdbResolvedCacheLimit = 96

    private init() {}

    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func resetAccountState() {
        withLock {
            watchlistKeys.removeAll(keepingCapacity: false)
            favoriteKeys.removeAll(keepingCapacity: false)
            recentKeys.removeAll(keepingCapacity: false)
            relatedCache.removeAll(keepingCapacity: false)
            tmdbResolvedCache.removeAll(keepingCapacity: false)
        }
    }

    func personalStatus(for item: MediaItem) -> TraktPersonalTitleStatus {
        let keys = canonicalKeys(for: item)
        return withLock {
            TraktPersonalTitleStatus(
                inWatchlist: !watchlistKeys.isDisjoint(with: keys),
                isFavorite: !favoriteKeys.isDisjoint(with: keys),
                recentlyWatched: !recentKeys.isDisjoint(with: keys)
            )
        }
    }

    /// vBRDC197: update the local account-membership snapshot immediately after a
    /// successful watchlist mutation so Media Information does not wait for the next
    /// full Trakt catalog refresh to reflect the button state.
    func setWatchlistState(for item: MediaItem, enabled: Bool) {
        let keys = canonicalKeys(for: item)
        withLock {
            if enabled {
                watchlistKeys.formUnion(keys)
            } else {
                watchlistKeys.subtract(keys)
            }
        }
    }

    func fetchCatalogRows(
        existingItems: [MediaItem],
        tmdbApiKey: String,
        forcePlaybackRefresh: Bool = false,
        skipPlaybackRefresh: Bool = false
    ) async -> [MediaRow] {
        guard TraktSyncManager.shared.isConnected else { return [] }

        // vBRDC197: manual Sync Resume already refreshed/materialized playback just
        // before asking for shelves. Do not immediately repeat the same two playback
        // requests; only force again when the snapshot is not fresh.
        let playbackWasJustSynced = TraktSyncManager.shared.lastSyncDate.map { Date().timeIntervalSince($0) < 4 } ?? false
        if !skipPlaybackRefresh, (!forcePlaybackRefresh || !playbackWasJustSynced) {
            await TraktSyncManager.shared.refreshPlaybackProgress(force: forcePlaybackRefresh)
        }

        let endpoints: [Endpoint] = [
            Endpoint(id: "trakt-movie-watchlist", title: "Trakt Watchlist", kind: "movie", path: "/users/me/watchlist/movies?extended=full&limit=24", authenticated: true, personalBucket: "watchlist"),
            Endpoint(id: "trakt-show-watchlist", title: "Trakt Watchlist", kind: "show", path: "/users/me/watchlist/shows?extended=full&limit=24", authenticated: true, personalBucket: "watchlist"),
            Endpoint(id: "trakt-movie-history", title: "Watch History • Trakt", kind: "movie", path: "/users/me/history/movies?extended=full&limit=30", authenticated: true, personalBucket: "recent"),
            Endpoint(id: "trakt-show-history", title: "Watch History • Trakt", kind: "show", path: "/users/me/history/shows?extended=full&limit=30", authenticated: true, personalBucket: "recent"),
            Endpoint(id: "trakt-movie-favorites", title: "Trakt Favorites", kind: "movie", path: "/users/me/favorites/movies?extended=full&limit=24", authenticated: true, personalBucket: "favorite"),
            Endpoint(id: "trakt-show-favorites", title: "Trakt Favorites", kind: "show", path: "/users/me/favorites/shows?extended=full&limit=24", authenticated: true, personalBucket: "favorite"),
            Endpoint(id: "trakt-movie-recommended", title: "Recommended for You • Trakt", kind: "movie", path: "/recommendations/movies?extended=full&limit=24", authenticated: true, personalBucket: nil),
            Endpoint(id: "trakt-show-recommended", title: "Recommended for You • Trakt", kind: "show", path: "/recommendations/shows?extended=full&limit=24", authenticated: true, personalBucket: nil),
            Endpoint(id: "trakt-movie-trending", title: "Trending on Trakt", kind: "movie", path: "/movies/trending?extended=full&limit=24", authenticated: false, personalBucket: nil),
            Endpoint(id: "trakt-show-trending", title: "Trending on Trakt", kind: "show", path: "/shows/trending?extended=full&limit=24", authenticated: false, personalBucket: nil),
            Endpoint(id: "trakt-movie-popular", title: "Popular on Trakt", kind: "movie", path: "/movies/popular?extended=full&limit=24", authenticated: false, personalBucket: nil),
            Endpoint(id: "trakt-show-popular", title: "Popular on Trakt", kind: "show", path: "/shows/popular?extended=full&limit=24", authenticated: false, personalBucket: nil),
            Endpoint(id: "trakt-movie-anticipated", title: "Anticipated on Trakt", kind: "movie", path: "/movies/anticipated?extended=full&limit=24", authenticated: false, personalBucket: nil),
            Endpoint(id: "trakt-show-anticipated", title: "Anticipated on Trakt", kind: "show", path: "/shows/anticipated?extended=full&limit=24", authenticated: false, personalBucket: nil)
        ]

        var fetched: [String: [Seed]] = [:]
        // vBRDC202: do not fan all account endpoints out at once. The previous 14-request
        // burst could coincide with catalog artwork decode and produce a visible tvOS stall.
        // Four concurrent requests keeps refresh fast while bounding sockets/JSON buffers.
        let endpointBatchSize = 4
        for start in stride(from: 0, to: endpoints.count, by: endpointBatchSize) {
            let batch = Array(endpoints[start..<min(start + endpointBatchSize, endpoints.count)])
            await withTaskGroup(of: (Endpoint, [Seed]).self) { group in
                for endpoint in batch {
                    group.addTask {
                        do {
                            let data = endpoint.authenticated
                                ? try await TraktSyncManager.shared.catalogAuthenticatedGET(path: endpoint.path)
                                : try await TraktSyncManager.shared.catalogPublicGET(path: endpoint.path)
                            return (endpoint, Self.parseSeeds(data: data, kind: endpoint.kind))
                        } catch {
                            return (endpoint, [])
                        }
                    }
                }
                for await (endpoint, seeds) in group {
                    fetched[endpoint.id] = seeds
                }
            }
            await Task.yield()
        }

        // Continue Watching is the same authoritative cloud playback state used by Resume.
        let continueSeeds = TraktSyncManager.shared.isEnabled ? TraktSyncManager.shared.cloudResumePointsSnapshot().compactMap(Self.seed(from:)) : []
        let movieContinue = continueSeeds.filter { $0.kind == "movie" }
        let showContinue = continueSeeds.filter { $0.kind == "show" }

        // Cache account state for the optional Spotlight Hub without adding title-by-title calls.
        var newWatch = Set<String>()
        var newFavorite = Set<String>()
        var newRecent = Set<String>()
        for endpoint in endpoints {
            guard let bucket = endpoint.personalBucket else { continue }
            let keys = Set((fetched[endpoint.id] ?? []).flatMap(Self.canonicalKeys(for:)))
            switch bucket {
            case "watchlist": newWatch.formUnion(keys)
            case "favorite": newFavorite.formUnion(keys)
            case "recent": newRecent.formUnion(keys)
            default: break
            }
        }
        withLock {
            watchlistKeys = newWatch
            favoriteKeys = newFavorite
            recentKeys = newRecent
        }

        let rowSeeds: [(String, String, String, [Seed])] = [
            ("trakt-movie-continue", "Continue Watching • Trakt", "movie", movieContinue),
            ("trakt-show-continue", "Continue Watching • Trakt", "show", showContinue),
            ("trakt-movie-watchlist", "Trakt Watchlist", "movie", fetched["trakt-movie-watchlist"] ?? []),
            ("trakt-show-watchlist", "Trakt Watchlist", "show", fetched["trakt-show-watchlist"] ?? []),
            ("trakt-movie-history", "Watch History • Trakt", "movie", fetched["trakt-movie-history"] ?? []),
            ("trakt-show-history", "Watch History • Trakt", "show", fetched["trakt-show-history"] ?? []),
            ("trakt-movie-favorites", "Trakt Favorites", "movie", fetched["trakt-movie-favorites"] ?? []),
            ("trakt-show-favorites", "Trakt Favorites", "show", fetched["trakt-show-favorites"] ?? []),
            ("trakt-movie-recommended", "Recommended for You • Trakt", "movie", fetched["trakt-movie-recommended"] ?? []),
            ("trakt-show-recommended", "Recommended for You • Trakt", "show", fetched["trakt-show-recommended"] ?? []),
            ("trakt-movie-trending", "Trending on Trakt", "movie", fetched["trakt-movie-trending"] ?? []),
            ("trakt-show-trending", "Trending on Trakt", "show", fetched["trakt-show-trending"] ?? []),
            ("trakt-movie-popular", "Popular on Trakt", "movie", fetched["trakt-movie-popular"] ?? []),
            ("trakt-show-popular", "Popular on Trakt", "show", fetched["trakt-show-popular"] ?? []),
            ("trakt-movie-anticipated", "Anticipated on Trakt", "movie", fetched["trakt-movie-anticipated"] ?? []),
            ("trakt-show-anticipated", "Anticipated on Trakt", "show", fetched["trakt-show-anticipated"] ?? [])
        ]

        let orderedUniqueSeeds = Self.uniqueSeeds(rowSeeds.flatMap { $0.3 })
        let resolved = await resolveSeeds(
            orderedUniqueSeeds,
            existingItems: existingItems,
            tmdbApiKey: tmdbApiKey,
            tmdbLookupLimit: 18
        )

        return rowSeeds.compactMap { id, title, kind, seeds in
            var seen = Set<String>()
            let items = seeds.compactMap { seed -> MediaItem? in
                guard var item = resolved[seed.key], seen.insert(seed.key).inserted else { return nil }
                // vBRDC196: row identity is authoritative. A cached/resolved item may carry
                // provider-specific type text, so normalize and verify it before publication.
                item.type = kind == "movie" ? "movie" : "series"
                if kind == "movie" {
                    item.seasonNumber = nil
                    item.episodeNumber = nil
                } else if seed.season != nil || seed.episode != nil {
                    item.seasonNumber = seed.season
                    item.episodeNumber = seed.episode
                }
                item.catalog = title
                item.addonName = "Trakt"
                return item
            }.filter { item in
                kind == "movie" ? item.type == "movie" : item.type == "series"
            }
            guard !items.isEmpty else { return nil }
            return MediaRow(
                id: id,
                title: title,
                items: Array(items.prefix(24)),
                presentation: Self.presentation(for: title, kind: kind)
            )
        }
    }

    func relatedItems(for item: MediaItem, existingItems: [MediaItem], tmdbApiKey: String) async -> [MediaItem] {
        guard TraktSyncManager.shared.isConnected else { return [] }
        let cacheKey = canonicalKeys(for: item).sorted().first ?? item.id
        if let cachedItems = withLock({ () -> [MediaItem]? in
            guard let cached = relatedCache[cacheKey], Date().timeIntervalSince(cached.createdAt) < 900 else { return nil }
            return cached.items
        }) {
            return cachedItems
        }

        let kind = Self.kind(for: item)
        let identifier = Self.cleanIMDb(item.imdbId)
            ?? Self.cleanInteger(item.tmdbId).map(String.init)
        guard let identifier, !identifier.isEmpty else { return [] }
        do {
            let path = kind == "movie"
                ? "/movies/\(identifier)/related?extended=full&limit=8"
                : "/shows/\(identifier)/related?extended=full&limit=8"
            let data = try await TraktSyncManager.shared.catalogPublicGET(path: path)
            let seeds = Array(Self.parseSeeds(data: data, kind: kind).prefix(8))
            let resolved = await resolveSeeds(seeds, existingItems: existingItems, tmdbApiKey: tmdbApiKey, tmdbLookupLimit: 8)
            let items = seeds.compactMap { resolved[$0.key] }.prefix(4).map { $0 }
            withLock {
                relatedCache[cacheKey] = RelatedCacheEntry(createdAt: Date(), items: items)
                if relatedCache.count > relatedCacheLimit {
                    let overflow = relatedCache.count - relatedCacheLimit
                    for key in relatedCache.sorted(by: { $0.value.createdAt < $1.value.createdAt }).prefix(overflow).map(\.key) {
                        relatedCache.removeValue(forKey: key)
                    }
                }
            }
            return items
        } catch {
            return []
        }
    }

    // MARK: - Resolution

    private func resolveSeeds(
        _ seeds: [Seed],
        existingItems: [MediaItem],
        tmdbApiKey: String,
        tmdbLookupLimit: Int
    ) async -> [String: MediaItem] {
        let lookup = Self.existingLookup(existingItems)
        var result: [String: MediaItem] = [:]
        var priorityLogoHydration: [Seed] = []
        var unresolved: [Seed] = []
        for seed in seeds {
            if let existing = Self.match(seed: seed, lookup: lookup) {
                let rebuilt = Self.rebuilt(existing: existing, from: seed)
                result[seed.key] = rebuilt
                // vBRDC203: account rows frequently reuse an already-visible catalog card.
                // That is perfect for instant poster/backdrop first paint, but those base cards
                // can still lack the title-logo that the focused hero expects. Put matched
                // Continue Watching/Resume identities at the front of the SAME bounded TMDB
                // hydration lane instead of treating "matched poster" as "fully hydrated".
                if rebuilt.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                   seed.tmdbID != nil {
                    priorityLogoHydration.append(seed)
                }
            } else {
                unresolved.append(seed)
            }
        }

        let key = tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, tmdbLookupLimit > 0 else { return result }
        var seenHydration = Set<String>()
        let candidates = Array((priorityLogoHydration + unresolved).filter { seenHydration.insert($0.key).inserted }.prefix(tmdbLookupLimit))
        // vBRDC202/vBRDC203: keep TMDB artwork/logo hydration bounded. Four concurrent
        // title lookups avoid a socket/decode burst while still forcing themed identity into
        // the highest-priority Continue Watching rows quickly enough for first focus.
        let lookupBatchSize = 4
        for start in stride(from: 0, to: candidates.count, by: lookupBatchSize) {
            let batch = Array(candidates[start..<min(start + lookupBatchSize, candidates.count)])
            await withTaskGroup(of: (String, MediaItem?).self) { group in
                for seed in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (seed.key, nil) }
                        return (seed.key, await self.tmdbItem(for: seed, apiKey: key))
                    }
                }
                for await (seedKey, hydrated) in group {
                    guard let hydrated else { continue }
                    if var existing = result[seedKey] {
                        if existing.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                            existing.logoURL = hydrated.logoURL
                        }
                        if existing.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                            existing.posterURL = hydrated.posterURL
                        }
                        if existing.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                            existing.landscapeURL = hydrated.landscapeURL
                        }
                        if existing.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            existing.description = hydrated.description
                        }
                        if existing.rating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            existing.rating = hydrated.rating
                        }
                        result[seedKey] = existing
                    } else {
                        result[seedKey] = hydrated
                    }
                }
            }
            await Task.yield()
        }
        return result
    }

    private func tmdbItem(for seed: Seed, apiKey: String) async -> MediaItem? {
        guard let tmdbID = seed.tmdbID, tmdbID > 0 else { return nil }
        let cacheKey = "\(seed.kind)|\(tmdbID)"
        if let cached = withLock({ tmdbResolvedCache[cacheKey] }) {
            return Self.rebuilt(existing: cached, from: seed)
        }

        let endpoint = seed.kind == "movie" ? "movie" : "tv"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(endpoint)/\(tmdbID)?api_key=\(apiKey)&language=en-US&append_to_response=images&include_image_language=en,null") else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS/vBRDC220 TraktCatalog", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let posterPath = json["poster_path"] as? String,
                  !posterPath.isEmpty else { return nil }

            let title = ((json["title"] as? String) ?? (json["name"] as? String) ?? seed.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let date = (json["release_date"] as? String) ?? (json["first_air_date"] as? String) ?? ""
            let year = seed.year ?? Int(String(date.prefix(4)))
            let overview = ((json["overview"] as? String) ?? seed.overview).trimmingCharacters(in: .whitespacesAndNewlines)
            let rating = (json["vote_average"] as? NSNumber)?.doubleValue ?? seed.rating
            let backdropPath = json["backdrop_path"] as? String
            let logoURL: String? = {
                guard let images = json["images"] as? [String: Any],
                      let logos = images["logos"] as? [[String: Any]], !logos.isEmpty else { return nil }
                let ranked = logos.sorted { lhs, rhs in
                    let lhsEnglish = (lhs["iso_639_1"] as? String) == "en"
                    let rhsEnglish = (rhs["iso_639_1"] as? String) == "en"
                    if lhsEnglish != rhsEnglish { return lhsEnglish }
                    let lhsVotes = (lhs["vote_count"] as? NSNumber)?.intValue ?? 0
                    let rhsVotes = (rhs["vote_count"] as? NSNumber)?.intValue ?? 0
                    if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }
                    return ((lhs["vote_average"] as? NSNumber)?.doubleValue ?? 0) > ((rhs["vote_average"] as? NSNumber)?.doubleValue ?? 0)
                }
                guard let path = (ranked.first?["file_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
                return "https://image.tmdb.org/t/p/original\(path)"
            }()
            var item = MediaItem(
                id: "trakt-\(seed.kind)-\(seed.traktID ?? tmdbID)",
                tmdbId: String(tmdbID),
                imdbId: seed.imdbID,
                tvdbId: seed.tvdbID.map(String.init),
                title: title.isEmpty ? seed.title : title,
                year: year.map(String.init) ?? "",
                type: seed.kind == "movie" ? "movie" : "series",
                catalog: "Trakt",
                description: overview,
                genres: seed.genres,
                rating: rating.map { String(format: "%.1f", $0) } ?? "",
                posterURL: "https://image.tmdb.org/t/p/original\(posterPath)",
                landscapeURL: backdropPath.map { "https://image.tmdb.org/t/p/original\($0)" },
                logoURL: logoURL,
                addonName: "Trakt",
                seasonNumber: seed.season,
                episodeNumber: seed.episode
            )
            item = Self.rebuilt(existing: item, from: seed)
            withLock {
                tmdbResolvedCache[cacheKey] = item
                if tmdbResolvedCache.count > tmdbResolvedCacheLimit {
                    let overflow = tmdbResolvedCache.count - tmdbResolvedCacheLimit
                    for key in Array(tmdbResolvedCache.keys.prefix(overflow)) {
                        tmdbResolvedCache.removeValue(forKey: key)
                    }
                }
            }
            return item
        } catch {
            return nil
        }
    }

    private static func rebuilt(existing: MediaItem, from seed: Seed) -> MediaItem {
        var item = existing
        if item.tmdbId?.isEmpty ?? true, let tmdb = seed.tmdbID { item.tmdbId = String(tmdb) }
        if item.imdbId?.isEmpty ?? true { item.imdbId = seed.imdbID }
        if item.tvdbId?.isEmpty ?? true, let tvdb = seed.tvdbID { item.tvdbId = String(tvdb) }
        if item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !seed.overview.isEmpty { item.description = seed.overview }
        if item.genres.isEmpty, !seed.genres.isEmpty { item.genres = seed.genres }
        if item.rating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rating = seed.rating { item.rating = String(format: "%.1f", rating) }
        item.type = seed.kind == "movie" ? "movie" : "series"
        item.addonName = "Trakt"
        if let season = seed.season { item.seasonNumber = season }
        if let episode = seed.episode { item.episodeNumber = episode }
        return item
    }

    private static func existingLookup(_ items: [MediaItem]) -> [String: MediaItem] {
        var output: [String: MediaItem] = [:]
        for item in items where item.addonName?.lowercased() != "trakt" {
            for key in canonicalKeys(for: item) where output[key] == nil {
                output[key] = item
            }
        }
        return output
    }

    private static func match(seed: Seed, lookup: [String: MediaItem]) -> MediaItem? {
        for key in canonicalKeys(for: seed) {
            if let item = lookup[key] { return item }
        }
        return nil
    }

    // MARK: - Parsing / identity

    private static func parseSeeds(data: Data, kind: String) -> [Seed] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var output: [Seed] = []
        var seen = Set<String>()
        for row in rows {
            let media: [String: Any]?
            if let nested = row[kind == "movie" ? "movie" : "show"] as? [String: Any] {
                media = nested
            } else if row["title"] != nil || row["ids"] != nil {
                media = row
            } else {
                media = nil
            }
            guard let media, let seed = seed(from: media, kind: kind), seen.insert(seed.key).inserted else { continue }
            output.append(seed)
        }
        return output
    }

    private static func seed(from media: [String: Any], kind: String) -> Seed? {
        let title = ((media["title"] as? String) ?? (media["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let ids = media["ids"] as? [String: Any] ?? [:]
        let trakt = (ids["trakt"] as? NSNumber)?.intValue
        let tmdb = (ids["tmdb"] as? NSNumber)?.intValue
        let tvdb = (ids["tvdb"] as? NSNumber)?.intValue
        let imdb = cleanIMDb(ids["imdb"] as? String)
        let year = (media["year"] as? NSNumber)?.intValue
        let overview = (media["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let genres = (media["genres"] as? [String]) ?? []
        let rating = (media["rating"] as? NSNumber)?.doubleValue
        let canonical = canonicalKey(kind: kind, title: title, year: year, traktID: trakt, imdbID: imdb, tmdbID: tmdb)
        return Seed(key: canonical, kind: kind, title: title, year: year, traktID: trakt, imdbID: imdb, tmdbID: tmdb, tvdbID: tvdb, overview: overview, genres: genres, rating: rating, season: nil, episode: nil)
    }

    private static func seed(from point: TraktCloudResumePoint) -> Seed? {
        if point.kind == "movie" {
            let title = point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let key = canonicalKey(kind: "movie", title: title, year: point.year, traktID: nil, imdbID: cleanIMDb(point.imdbID), tmdbID: point.tmdbID)
            return Seed(key: key, kind: "movie", title: title, year: point.year, traktID: nil, imdbID: cleanIMDb(point.imdbID), tmdbID: point.tmdbID, tvdbID: nil, overview: "", genres: [], rating: nil, season: nil, episode: nil)
        }
        let title = (point.showTitle ?? point.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let imdb = cleanIMDb(point.showIMDbID ?? point.imdbID)
        let tmdb = point.showTMDBID ?? point.tmdbID
        let key = canonicalKey(kind: "show", title: title, year: point.showYear ?? point.year, traktID: nil, imdbID: imdb, tmdbID: tmdb)
        return Seed(key: key, kind: "show", title: title, year: point.showYear ?? point.year, traktID: nil, imdbID: imdb, tmdbID: tmdb, tvdbID: nil, overview: "", genres: [], rating: nil, season: point.season, episode: point.episode)
    }

    private static func uniqueSeeds(_ seeds: [Seed]) -> [Seed] {
        var seen = Set<String>()
        return seeds.filter { seen.insert($0.key).inserted }
    }

    private static func canonicalKeys(for seed: Seed) -> [String] {
        var keys: [String] = [seed.key]
        if let tmdb = seed.tmdbID { keys.append("tmdb|\(seed.kind)|\(tmdb)") }
        if let imdb = seed.imdbID { keys.append("imdb|\(imdb.lowercased())") }
        keys.append("title|\(seed.kind)|\(normalize(seed.title))|\(seed.year.map(String.init) ?? "")")
        return Array(Set(keys))
    }

    private func canonicalKeys(for item: MediaItem) -> Set<String> {
        Set(Self.canonicalKeys(for: item))
    }

    private static func canonicalKeys(for item: MediaItem) -> [String] {
        let kind = kind(for: item)
        var keys: [String] = []
        if let tmdb = cleanInteger(item.tmdbId) { keys.append("tmdb|\(kind)|\(tmdb)") }
        if let imdb = cleanIMDb(item.imdbId) { keys.append("imdb|\(imdb.lowercased())") }
        keys.append("title|\(kind)|\(normalize(item.title))|\(Int(item.year).map(String.init) ?? "")")
        return keys
    }

    private static func canonicalKey(kind: String, title: String, year: Int?, traktID: Int?, imdbID: String?, tmdbID: Int?) -> String {
        if let tmdbID { return "tmdb|\(kind)|\(tmdbID)" }
        if let imdbID { return "imdb|\(imdbID.lowercased())" }
        if let traktID { return "trakt|\(kind)|\(traktID)" }
        return "title|\(kind)|\(normalize(title))|\(year.map(String.init) ?? "")"
    }

    private static func kind(for item: MediaItem) -> String {
        let lower = item.type.lowercased()
        if item.seasonNumber != nil || item.episodeNumber != nil || lower.contains("series") || lower.contains("show") || lower.contains("episode") || lower == "tv" { return "show" }
        return "movie"
    }

    private static func cleanInteger(_ value: String?) -> Int? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int(clean)
    }

    private static func cleanIMDb(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard clean.lowercased().hasPrefix("tt"), clean.count >= 4 else { return nil }
        return clean
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : Character(" ") }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func presentation(for title: String, kind: String) -> CatalogRowPresentation {
        CatalogRowPresentation(
            shortName: title,
            description: "Synced from the connected Trakt account",
            rowKind: "trakt",
            providerName: "Trakt",
            themeLogoURL: nil,
            providerBadgeURL: nil,
            backgroundURL: nil,
            theme: CatalogRowVisualTheme(
                style: "trakt",
                accentHex: "#ED1C24",
                secondaryHex: "#8A1018",
                symbol: kind == "movie" ? "film.fill" : "tv.fill",
                labelStyle: "provider"
            )
        )
    }
}
