import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CatalogHeroMetadataSnapshot: Hashable, Sendable {
    let runtimeMinutes: Int?
    let releaseYear: String?
    let releaseDate: String?
    let genres: [String]
    let seasonCount: Int?
    let certification: String?
    let budget: Int?
    let overview: String?
    // vBRDC203/vBRDC210: append TMDB images to the existing focused-hero metadata request so
    // account-derived Resume/Trakt cards can recover complete visual identity without
    // waiting for another catalog surface to happen to hydrate them.
    let posterURL: String?
    let landscapeURL: String?
    let logoURL: String?
}

actor CatalogHeroMetadataCache {
    static let shared = CatalogHeroMetadataCache()

    private struct CacheEntry {
        let value: CatalogHeroMetadataSnapshot?
        let expiresAt: Date
    }

    private var entries: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CatalogHeroMetadataSnapshot?, Never>] = [:]
    private let ttl: TimeInterval = 6 * 60 * 60
    private let maximumEntries = 192

    func metadata(
        itemID: String,
        tmdbID: String?,
        imdbID: String?,
        title: String,
        year: String,
        type: String,
        apiKey: String
    ) async -> CatalogHeroMetadataSnapshot? {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return nil }
        pruneExpiredAndOverflow(now: Date())

        let cacheKey = [itemID, tmdbID ?? "", imdbID ?? "", type, year, title]
            .joined(separator: "|")
            .lowercased()

        if let cached = entries[cacheKey], cached.expiresAt > Date() {
            return cached.value
        }
        if let task = inFlight[cacheKey] {
            return await task.value
        }

        let task = Task<CatalogHeroMetadataSnapshot?, Never> {
            await Self.fetchMetadata(
                itemID: itemID,
                tmdbID: tmdbID,
                imdbID: imdbID,
                title: title,
                year: year,
                type: type,
                apiKey: cleanKey
            )
        }
        inFlight[cacheKey] = task
        let value = await task.value
        inFlight[cacheKey] = nil
        entries[cacheKey] = CacheEntry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        pruneExpiredAndOverflow(now: Date())
        return value
    }

    func suspendNetworkWork() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
    }

    func handleMemoryPressure() {
        suspendNetworkWork()
        entries.removeAll(keepingCapacity: false)
        print("[CatalogHeroMetadata][Phase7] released metadata cache for memory pressure")
    }

    func performMaintenance() {
        pruneExpiredAndOverflow(now: Date())
    }

    private func pruneExpiredAndOverflow(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
        guard entries.count > maximumEntries else { return }
        let retained = entries.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(maximumEntries)
        entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private static func fetchMetadata(
        itemID: String,
        tmdbID: String?,
        imdbID: String?,
        title: String,
        year: String,
        type: String,
        apiKey: String
    ) async -> CatalogHeroMetadataSnapshot? {
        struct TMDBReference: Decodable { let id: Int? }
        struct TMDBFindResponse: Decodable {
            let movie_results: [TMDBReference]?
            let tv_results: [TMDBReference]?
        }
        struct TMDBSearchResponse: Decodable { let results: [TMDBReference]? }
        struct TMDBGenre: Decodable { let name: String? }
        struct MovieReleaseEntry: Decodable {
            let certification: String?
            let release_date: String?
            let type: Int?
        }
        struct MovieReleaseCountry: Decodable {
            let iso_3166_1: String?
            let release_dates: [MovieReleaseEntry]?
        }
        struct MovieReleaseDates: Decodable { let results: [MovieReleaseCountry]? }
        struct TVContentRating: Decodable {
            let iso_3166_1: String?
            let rating: String?
        }
        struct TVContentRatings: Decodable { let results: [TVContentRating]? }
        struct TMDBImage: Decodable {
            let file_path: String?
            let iso_639_1: String?
            let vote_average: Double?
            let vote_count: Int?
        }
        struct TMDBImages: Decodable { let logos: [TMDBImage]? }
        struct MovieDetail: Decodable {
            let runtime: Int?
            let release_date: String?
            let poster_path: String?
            let backdrop_path: String?
            let genres: [TMDBGenre]?
            let budget: Int?
            let release_dates: MovieReleaseDates?
            let overview: String?
            let images: TMDBImages?
        }
        struct TVDetail: Decodable {
            let episode_run_time: [Int]?
            let first_air_date: String?
            let poster_path: String?
            let backdrop_path: String?
            let genres: [TMDBGenre]?
            let number_of_seasons: Int?
            let content_ratings: TVContentRatings?
            let overview: String?
            let images: TMDBImages?
        }

        func request<T: Decodable>(_ type: T.Type, url: URL) async -> T? {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return nil }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                return nil
            }
        }

        func makeURL(path: String, query: [URLQueryItem] = []) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.themoviedb.org"
            components.path = "/3/\(path)"
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: "en-US")
            ] + query
            return components.url
        }

        let normalizedType = type.lowercased()
        let isTV = normalizedType.contains("series") || normalizedType.contains("show") || normalizedType == "tv"
        var kind = isTV ? "tv" : "movie"
        var resolvedID: String? = tmdbID?.trimmingCharacters(in: .whitespacesAndNewlines)

        if resolvedID?.isEmpty != false {
            let parts = itemID.split(separator: ":").map(String.init)
            if parts.count >= 3, parts[0].lowercased() == "tmdb" {
                kind = (parts[1].lowercased() == "tv" || isTV) ? "tv" : "movie"
                resolvedID = parts[2]
            }
        }

        if resolvedID?.isEmpty != false {
            let candidateIMDb: String? = {
                let clean = imdbID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if clean.lowercased().hasPrefix("tt") { return clean }
                if itemID.lowercased().hasPrefix("tt") { return itemID }
                if let range = itemID.range(of: #"tt\d{6,}"#, options: .regularExpression) {
                    return String(itemID[range])
                }
                return nil
            }()

            if let candidateIMDb,
               let url = makeURL(
                    path: "find/\(candidateIMDb)",
                    query: [URLQueryItem(name: "external_source", value: "imdb_id")]
               ),
               let found = await request(TMDBFindResponse.self, url: url) {
                if let movieID = found.movie_results?.compactMap(\.id).first {
                    kind = "movie"
                    resolvedID = String(movieID)
                } else if let tvID = found.tv_results?.compactMap(\.id).first {
                    kind = "tv"
                    resolvedID = String(tvID)
                }
            }
        }

        if resolvedID?.isEmpty != false {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return nil }
            var queryItems = [
                URLQueryItem(name: "query", value: cleanTitle),
                URLQueryItem(name: "include_adult", value: "false")
            ]
            let cleanYear = String(year.filter(\.isNumber).prefix(4))
            if !cleanYear.isEmpty {
                queryItems.append(URLQueryItem(name: kind == "tv" ? "first_air_date_year" : "year", value: cleanYear))
            }
            if let url = makeURL(path: "search/\(kind)", query: queryItems),
               let search = await request(TMDBSearchResponse.self, url: url),
               let firstID = search.results?.compactMap(\.id).first {
                resolvedID = String(firstID)
            }
        }

        func preferredMovieCertification(_ countries: [MovieReleaseCountry]) -> String? {
            let ordered = countries.sorted { lhs, rhs in
                let lhsUS = lhs.iso_3166_1?.uppercased() == "US"
                let rhsUS = rhs.iso_3166_1?.uppercased() == "US"
                return lhsUS && !rhsUS
            }
            for country in ordered {
                let entries = country.release_dates ?? []
                let preferred = entries.sorted { lhs, rhs in
                    let lhsPriority = lhs.type == 3 ? 0 : (lhs.type == 4 ? 1 : 2)
                    let rhsPriority = rhs.type == 3 ? 0 : (rhs.type == 4 ? 1 : 2)
                    return lhsPriority < rhsPriority
                }
                if let value = preferred
                    .compactMap({ $0.certification?.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }) {
                    return value.uppercased()
                }
            }
            return nil
        }

        func preferredTVCertification(_ ratings: [TVContentRating]) -> String? {
            let ordered = ratings.sorted { lhs, rhs in
                let lhsUS = lhs.iso_3166_1?.uppercased() == "US"
                let rhsUS = rhs.iso_3166_1?.uppercased() == "US"
                return lhsUS && !rhsUS
            }
            return ordered
                .compactMap { $0.rating?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })?
                .uppercased()
        }

        func preferredLogoURL(_ images: TMDBImages?) -> String? {
            let logos = images?.logos ?? []
            let preferred = logos.sorted { lhs, rhs in
                let lhsEnglish = (lhs.iso_639_1 ?? "") == "en"
                let rhsEnglish = (rhs.iso_639_1 ?? "") == "en"
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                let lhsVotes = lhs.vote_count ?? 0
                let rhsVotes = rhs.vote_count ?? 0
                if lhsVotes != rhsVotes { return lhsVotes > rhsVotes }
                return (lhs.vote_average ?? 0) > (rhs.vote_average ?? 0)
            }.first
            guard let path = preferred?.file_path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            return "https://image.tmdb.org/t/p/original\(path)"
        }

        let appendToResponse = kind == "tv" ? "content_ratings,images" : "release_dates,images"
        guard let resolvedID, !resolvedID.isEmpty,
              let detailURL = makeURL(
                path: "\(kind)/\(resolvedID)",
                query: [
                    URLQueryItem(name: "append_to_response", value: appendToResponse),
                    URLQueryItem(name: "include_image_language", value: "en,null")
                ]
              ) else { return nil }

        if kind == "tv", let detail = await request(TVDetail.self, url: detailURL) {
            return CatalogHeroMetadataSnapshot(
                runtimeMinutes: detail.episode_run_time?.first(where: { $0 > 0 }),
                releaseYear: detail.first_air_date.flatMap(Self.yearPrefix),
                releaseDate: detail.first_air_date,
                genres: detail.genres?.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [],
                seasonCount: detail.number_of_seasons,
                certification: preferredTVCertification(detail.content_ratings?.results ?? []),
                budget: nil,
                overview: detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
                posterURL: detail.poster_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                landscapeURL: detail.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                logoURL: preferredLogoURL(detail.images)
            )
        }

        if let detail = await request(MovieDetail.self, url: detailURL) {
            return CatalogHeroMetadataSnapshot(
                runtimeMinutes: detail.runtime,
                releaseYear: detail.release_date.flatMap(Self.yearPrefix),
                releaseDate: detail.release_date,
                genres: detail.genres?.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [],
                seasonCount: nil,
                certification: preferredMovieCertification(detail.release_dates?.results ?? []),
                budget: detail.budget,
                overview: detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
                posterURL: detail.poster_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                landscapeURL: detail.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                logoURL: preferredLogoURL(detail.images)
            )
        }
        return nil
    }

    private static func yearPrefix(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return String(digits.prefix(4))
    }
}
