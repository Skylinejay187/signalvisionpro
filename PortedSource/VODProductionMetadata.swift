import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct VODProductionCompany: Identifiable, Hashable, Codable {
    var id: String { name.lowercased() + "|" + (logoURL ?? "") }
    let name: String
    let logoURL: String?
}

struct VODCraftCredit: Identifiable, Hashable {
    var id: String { role.lowercased() + "|" + name.lowercased() }
    let role: String
    let name: String
    let profileURL: String?
}

// vBRDC192 Spotlight Hub: TMDB-backed extras that are intentionally different
// from Production & Ratings. These are passive presentation models only; they
// never start a second playback engine or background poller.
struct VODSpotlightVideo: Identifiable, Hashable {
    var id: String { site.lowercased() + "|" + key.lowercased() }
    let name: String
    let key: String
    let site: String
    let type: String
    let official: Bool
    let thumbnailURL: String?
}

struct VODWatchProvider: Identifiable, Hashable {
    var id: String { "\(providerID)|\(category.lowercased())" }
    let providerID: Int
    let name: String
    let logoURL: String?
    let category: String
}

struct VODReviewHighlight: Hashable {
    let author: String
    let content: String
    let rating: Double?
}

struct VODProductionMetadataSnapshot: Hashable {
    var certification: String? = nil
    var budget: Int? = nil
    var revenue: Int? = nil
    var status: String? = nil
    var runtimeMinutes: Int? = nil
    var releaseDate: String? = nil
    var countries: [String] = []
    var languages: [String] = []
    var studios: [VODProductionCompany] = []
    var networks: [VODProductionCompany] = []
    var landscapeArtworkURLs: [String] = []
    var landscapeArtworkAspectRatios: [String: Double] = [:]
    var titleLogoURL: String? = nil

    // vBRDC192 Spotlight Hub: official video extras, local-region watch
    // providers, and a concise TMDB community review highlight.
    var spotlightVideos: [VODSpotlightVideo] = []
    var watchProviders: [VODWatchProvider] = []
    var reviewHighlight: VODReviewHighlight? = nil

    // vBRDC191 legacy craft-credit payload remains source-compatible for one
    // build, but the Behind the Scenes presentation was retired in vBRDC192.
    // different from the existing Production & Ratings information.
    var craftCredits: [VODCraftCredit] = []

    // vBRDC190 legacy specialty artwork fields remain decode-compatible for one build,
    // but the Collector Showcase UI/request path was retired in vBRDC191.
    var clearArtURLs: [String] = []
    var characterArtURLs: [String] = []
    var discArtURLs: [String] = []
    var collectionArtworkURL: String? = nil
    var tagline: String? = nil
    var originalTitle: String? = nil
    var collectionName: String? = nil
    var creatorNames: [String] = []

    static let empty = VODProductionMetadataSnapshot()

    var hasUsefulContent: Bool {
        certification != nil || budget != nil || revenue != nil || status != nil || runtimeMinutes != nil || releaseDate != nil || !countries.isEmpty || !languages.isEmpty || !studios.isEmpty || !networks.isEmpty || !landscapeArtworkURLs.isEmpty || !landscapeArtworkAspectRatios.isEmpty || titleLogoURL != nil || !spotlightVideos.isEmpty || !watchProviders.isEmpty || reviewHighlight != nil || !craftCredits.isEmpty || !clearArtURLs.isEmpty || !characterArtURLs.isEmpty || !discArtURLs.isEmpty || collectionArtworkURL != nil || tagline != nil || originalTitle != nil || collectionName != nil || !creatorNames.isEmpty
    }
}

enum VODProductionMetadataService {
    private struct TMDBReference: Decodable { let id: Int? }
    private struct FindResponse: Decodable {
        let movie_results: [TMDBReference]?
        let tv_results: [TMDBReference]?
    }
    private struct SearchResponse: Decodable { let results: [TMDBReference]? }
    private struct Company: Decodable {
        let name: String?
        let logo_path: String?
    }
    private struct Creator: Decodable { let name: String? }
    private struct CrewMember: Decodable {
        let name: String?
        let job: String?
        let department: String?
        let profile_path: String?
    }
    private struct Credits: Decodable { let crew: [CrewMember]? }
    private struct VideoResult: Decodable {
        let id: String?
        let name: String?
        let key: String?
        let site: String?
        let type: String?
        let official: Bool?
        let size: Int?
        let published_at: String?
    }
    private struct Videos: Decodable { let results: [VideoResult]? }
    private struct Provider: Decodable {
        let provider_id: Int?
        let provider_name: String?
        let logo_path: String?
        let display_priority: Int?
    }
    private struct ProviderRegion: Decodable {
        let link: String?
        let flatrate: [Provider]?
        let free: [Provider]?
        let ads: [Provider]?
        let rent: [Provider]?
        let buy: [Provider]?
    }
    private struct WatchProviders: Decodable { let results: [String: ProviderRegion]? }
    private struct ReviewAuthorDetails: Decodable {
        let name: String?
        let username: String?
        let rating: Double?
    }
    private struct Review: Decodable {
        let author: String?
        let content: String?
        let author_details: ReviewAuthorDetails?
        let created_at: String?
    }
    private struct Reviews: Decodable { let results: [Review]? }
    private struct Collection: Decodable {
        let name: String?
        let poster_path: String?
        let backdrop_path: String?
    }
    private struct ExternalIDs: Decodable { let tvdb_id: Int? }
    private struct Country: Decodable {
        let iso_3166_1: String?
        let name: String?
    }
    private struct Language: Decodable {
        let english_name: String?
        let name: String?
    }
    private struct ArtworkImage: Decodable {
        let file_path: String?
        let width: Int?
        let height: Int?
        let aspect_ratio: Double?
        let vote_average: Double?
        let vote_count: Int?
        let iso_639_1: String?
    }
    private struct ArtworkImages: Decodable {
        let backdrops: [ArtworkImage]?
        let logos: [ArtworkImage]?
    }
    private struct MovieReleaseEntry: Decodable {
        let certification: String?
        let type: Int?
    }
    private struct MovieReleaseCountry: Decodable {
        let iso_3166_1: String?
        let release_dates: [MovieReleaseEntry]?
    }
    private struct MovieReleaseDates: Decodable { let results: [MovieReleaseCountry]? }
    private struct TVContentRating: Decodable {
        let iso_3166_1: String?
        let rating: String?
    }
    private struct TVContentRatings: Decodable { let results: [TVContentRating]? }
    private struct MovieDetail: Decodable {
        let budget: Int?
        let revenue: Int?
        let status: String?
        let runtime: Int?
        let release_date: String?
        let production_companies: [Company]?
        let production_countries: [Country]?
        let spoken_languages: [Language]?
        let release_dates: MovieReleaseDates?
        let images: ArtworkImages?
        let tagline: String?
        let original_title: String?
        let belongs_to_collection: Collection?
        let credits: Credits?
        let videos: Videos?
        let reviews: Reviews?
        let watchProviders: WatchProviders?

        private enum CodingKeys: String, CodingKey {
            case budget, revenue, status, runtime, release_date, production_companies, production_countries, spoken_languages, release_dates, images, tagline, original_title, belongs_to_collection, credits, videos, reviews
            case watchProviders = "watch/providers"
        }
    }
    private struct EpisodeSummary: Decodable { let runtime: Int? }
    private struct TVDetail: Decodable {
        let status: String?
        let episode_run_time: [Int]?
        let first_air_date: String?
        let origin_country: [String]?
        let production_companies: [Company]?
        let networks: [Company]?
        let spoken_languages: [Language]?
        let content_ratings: TVContentRatings?
        let last_episode_to_air: EpisodeSummary?
        let images: ArtworkImages?
        let tagline: String?
        let original_name: String?
        let created_by: [Creator]?
        let external_ids: ExternalIDs?
        let credits: Credits?
        let videos: Videos?
        let reviews: Reviews?
        let watchProviders: WatchProviders?

        private enum CodingKeys: String, CodingKey {
            case status, episode_run_time, first_air_date, origin_country, production_companies, networks, spoken_languages, content_ratings, last_episode_to_air, images, tagline, original_name, created_by, external_ids, credits, videos, reviews
            case watchProviders = "watch/providers"
        }
    }

    private struct FanartImage: Decodable {
        let url: String?
        let lang: String?
        let likes: String?

        var score: Int { Int(likes ?? "0") ?? 0 }
    }
    private struct FanartMovieResponse: Decodable {
        let hdmovieclearart: [FanartImage]?
        let movieart: [FanartImage]?
        let moviedisc: [FanartImage]?
        let moviebanner: [FanartImage]?
    }
    private struct FanartTVResponse: Decodable {
        let hdclearart: [FanartImage]?
        let clearart: [FanartImage]?
        let characterart: [FanartImage]?
        let tvbanner: [FanartImage]?
    }
    private struct FanartSpecialtyArtwork {
        var clearArt: [String] = []
        var characterArt: [String] = []
        var discArt: [String] = []
    }

    static func fetch(
        itemID: String,
        tmdbID explicitTMDBID: String?,
        imdbID explicitIMDbID: String?,
        title: String,
        year: String,
        type: String,
        seasonNumber: Int?,
        episodeNumber: Int?,
        apiKey: String,
        fanartApiKey: String = "",
        includeSpotlight: Bool = false
    ) async -> VODProductionMetadataSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }

        let lowerType = type.lowercased()
        let isTV = seasonNumber != nil || episodeNumber != nil || lowerType.contains("series") || lowerType.contains("show") || lowerType.contains("episode") || lowerType == "tv"
        var kind = isTV ? "tv" : "movie"
        var tmdbID = explicitTMDBID?.trimmingCharacters(in: .whitespacesAndNewlines)

        let idParts = itemID.split(separator: ":").map(String.init)
        if tmdbID?.isEmpty != false, idParts.count >= 3, idParts[0].lowercased() == "tmdb" {
            kind = (idParts[1].lowercased() == "tv" || isTV) ? "tv" : "movie"
            tmdbID = idParts[2]
        }

        let imdbID: String? = {
            let explicit = explicitIMDbID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if explicit.lowercased().hasPrefix("tt") { return explicit }
            if itemID.lowercased().hasPrefix("tt") { return String(itemID.split(separator: ":").first ?? Substring(itemID)) }
            if let range = itemID.range(of: #"tt\d{6,}"#, options: .regularExpression) { return String(itemID[range]) }
            return nil
        }()

        if tmdbID?.isEmpty != false, let imdbID,
           let url = makeURL(path: "find/\(imdbID)", apiKey: key, query: [URLQueryItem(name: "external_source", value: "imdb_id")]),
           let found = await request(FindResponse.self, url: url) {
            if isTV, let value = found.tv_results?.compactMap(\.id).first {
                kind = "tv"
                tmdbID = String(value)
            } else if let value = found.movie_results?.compactMap(\.id).first {
                kind = "movie"
                tmdbID = String(value)
            } else if let value = found.tv_results?.compactMap(\.id).first {
                kind = "tv"
                tmdbID = String(value)
            }
        }

        if tmdbID?.isEmpty != false {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanTitle.count >= 2 else { return .empty }
            var query = [
                URLQueryItem(name: "query", value: cleanTitle),
                URLQueryItem(name: "include_adult", value: "false")
            ]
            let cleanYear = String(year.filter(\.isNumber).prefix(4))
            if !cleanYear.isEmpty {
                query.append(URLQueryItem(name: kind == "tv" ? "first_air_date_year" : "year", value: cleanYear))
            }
            if let url = makeURL(path: "search/\(kind)", apiKey: key, query: query),
               let found = await request(SearchResponse.self, url: url),
               let value = found.results?.compactMap(\.id).first {
                tmdbID = String(value)
            }
        }

        guard let tmdbID, !tmdbID.isEmpty else { return .empty }
        // vBRDC193: Spotlight Hub no longer surfaces passive video-card thumbnails.
        // Keep the bounded TMDB request focused on genuinely useful provider/review data.
        let tvAppend = includeSpotlight
            ? "content_ratings,images,external_ids,reviews,watch/providers"
            : "content_ratings,images,external_ids"
        let movieAppend = includeSpotlight
            ? "release_dates,images,reviews,watch/providers"
            : "release_dates,images"
        if kind == "tv" {
            guard let url = makeURL(
                path: "tv/\(tmdbID)",
                apiKey: key,
                query: [
                    URLQueryItem(name: "append_to_response", value: tvAppend),
                    URLQueryItem(name: "include_image_language", value: "en,null")
                ]
            ), let detail = await request(TVDetail.self, url: url) else { return .empty }

            let artwork = artwork(detail.images)
            let spotlight: [VODSpotlightVideo] = []
            let providers = includeSpotlight ? watchProviders(detail.watchProviders) : []
            let review = includeSpotlight ? reviewHighlight(detail.reviews) : nil
            return VODProductionMetadataSnapshot(
                certification: preferredTVRating(detail.content_ratings?.results ?? []),
                budget: nil,
                revenue: nil,
                status: clean(detail.status),
                runtimeMinutes: detail.last_episode_to_air?.runtime ?? detail.episode_run_time?.first(where: { $0 > 0 }),
                releaseDate: clean(detail.first_air_date),
                countries: unique((detail.origin_country ?? []).map { $0.uppercased() }),
                languages: unique((detail.spoken_languages ?? []).compactMap { clean($0.english_name) ?? clean($0.name) }),
                studios: companies(detail.production_companies ?? []),
                networks: companies(detail.networks ?? []),
                landscapeArtworkURLs: artwork.landscape,
                landscapeArtworkAspectRatios: artwork.aspectRatios,
                titleLogoURL: artwork.logo,
                spotlightVideos: spotlight,
                watchProviders: providers,
                reviewHighlight: review,
                craftCredits: [],
                clearArtURLs: [],
                characterArtURLs: [],
                discArtURLs: [],
                collectionArtworkURL: nil,
                tagline: clean(detail.tagline),
                originalTitle: clean(detail.original_name),
                collectionName: nil,
                creatorNames: unique((detail.created_by ?? []).compactMap { clean($0.name) })
            )
        }

        guard let url = makeURL(
            path: "movie/\(tmdbID)",
            apiKey: key,
            query: [
                URLQueryItem(name: "append_to_response", value: movieAppend),
                URLQueryItem(name: "include_image_language", value: "en,null")
            ]
        ), let detail = await request(MovieDetail.self, url: url) else { return .empty }

        let artwork = artwork(detail.images)
        let spotlight: [VODSpotlightVideo] = []
        let providers = includeSpotlight ? watchProviders(detail.watchProviders) : []
        let review = includeSpotlight ? reviewHighlight(detail.reviews) : nil
        let collectionArtworkURL = clean(detail.belongs_to_collection?.backdrop_path)
            .map { "https://image.tmdb.org/t/p/w780\($0)" }
            ?? clean(detail.belongs_to_collection?.poster_path).map { "https://image.tmdb.org/t/p/w500\($0)" }
        return VODProductionMetadataSnapshot(
            certification: preferredMovieRating(detail.release_dates?.results ?? []),
            budget: positive(detail.budget),
            revenue: positive(detail.revenue),
            status: clean(detail.status),
            runtimeMinutes: positive(detail.runtime),
            releaseDate: clean(detail.release_date),
            countries: unique((detail.production_countries ?? []).compactMap { clean($0.iso_3166_1)?.uppercased() ?? clean($0.name) }),
            languages: unique((detail.spoken_languages ?? []).compactMap { clean($0.english_name) ?? clean($0.name) }),
            studios: companies(detail.production_companies ?? []),
            networks: [],
            landscapeArtworkURLs: artwork.landscape,
            titleLogoURL: artwork.logo,
            spotlightVideos: spotlight,
            watchProviders: providers,
            reviewHighlight: review,
            craftCredits: [],
            clearArtURLs: [],
            characterArtURLs: [],
            discArtURLs: [],
            collectionArtworkURL: collectionArtworkURL,
            tagline: clean(detail.tagline),
            originalTitle: clean(detail.original_title),
            collectionName: clean(detail.belongs_to_collection?.name),
            creatorNames: []
        )
    }

    private static func spotlightVideos(_ videos: Videos?) -> [VODSpotlightVideo] {
        let all = videos?.results ?? []
        let preferredTypes = ["Featurette", "Clip", "Bloopers", "Teaser", "Behind the Scenes"]
        let priority = Dictionary(uniqueKeysWithValues: preferredTypes.enumerated().map { ($1.lowercased(), $0) })

        func make(_ video: VideoResult) -> VODSpotlightVideo? {
            guard let name = clean(video.name),
                  let key = clean(video.key),
                  let site = clean(video.site),
                  let type = clean(video.type) else { return nil }
            let lowerSite = site.lowercased()
            guard lowerSite == "youtube" || lowerSite == "vimeo" else { return nil }
            let thumbnail: String? = lowerSite == "youtube"
                ? "https://i.ytimg.com/vi/\(key)/hqdefault.jpg"
                : nil
            return VODSpotlightVideo(
                name: name,
                key: key,
                site: site,
                type: type,
                official: video.official ?? false,
                thumbnailURL: thumbnail
            )
        }

        let ranked = all.sorted { lhs, rhs in
            let lt = (lhs.type ?? "").lowercased()
            let rt = (rhs.type ?? "").lowercased()
            let lp = priority[lt] ?? 99
            let rp = priority[rt] ?? 99
            if lp != rp { return lp < rp }
            if (lhs.official ?? false) != (rhs.official ?? false) { return lhs.official ?? false }
            if (lhs.size ?? 0) != (rhs.size ?? 0) { return (lhs.size ?? 0) > (rhs.size ?? 0) }
            return (lhs.published_at ?? "") > (rhs.published_at ?? "")
        }

        var seen = Set<String>()
        var extras = ranked.compactMap(make).filter { video in
            let type = video.type.lowercased()
            guard priority[type] != nil else { return false }
            return seen.insert(video.id).inserted
        }
        if extras.count < 3 {
            for video in ranked.compactMap(make) where video.type.lowercased() == "trailer" || video.type.lowercased() == "teaser" {
                if seen.insert(video.id).inserted { extras.append(video) }
                if extras.count >= 3 { break }
            }
        }
        return Array(extras.prefix(3))
    }

    private static func watchProviders(_ payload: WatchProviders?) -> [VODWatchProvider] {
        let region = (Locale.current.regionCode ?? "US").uppercased()
        guard let results = payload?.results,
              let selected = results[region] ?? results["US"] ?? results.values.first else { return [] }

        let groups: [(String, [Provider]?)] = [
            ("STREAM", selected.flatrate),
            ("FREE", selected.free),
            ("WITH ADS", selected.ads),
            ("RENT", selected.rent),
            ("BUY", selected.buy)
        ]
        var output: [VODWatchProvider] = []
        var seen = Set<Int>()
        for (category, providers) in groups {
            for provider in (providers ?? []).sorted(by: { ($0.display_priority ?? 999) < ($1.display_priority ?? 999) }) {
                guard let id = provider.provider_id,
                      let name = clean(provider.provider_name),
                      seen.insert(id).inserted else { continue }
                let logo = clean(provider.logo_path).map { "https://image.tmdb.org/t/p/w185\($0)" }
                output.append(VODWatchProvider(providerID: id, name: name, logoURL: logo, category: category))
                if output.count >= 5 { return output }
            }
        }
        return output
    }

    private static func reviewHighlight(_ payload: Reviews?) -> VODReviewHighlight? {
        let candidates = (payload?.results ?? []).compactMap { review -> VODReviewHighlight? in
            guard let raw = clean(review.content) else { return nil }
            let stripped = raw
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: " ", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLower = raw.lowercased()
            guard stripped.count >= 40,
                  !rawLower.contains("http://"),
                  !rawLower.contains("https://"),
                  !rawLower.contains("www.") else { return nil }
            let author = clean(review.author_details?.name)
                ?? clean(review.author)
                ?? clean(review.author_details?.username)
                ?? "TMDB Member"
            let limit = 176
            let excerpt = stripped.count > limit
                ? String(stripped.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
                : stripped
            return VODReviewHighlight(author: author, content: excerpt, rating: review.author_details?.rating)
        }
        return candidates.sorted { lhs, rhs in
            if (lhs.rating ?? -1) != (rhs.rating ?? -1) { return (lhs.rating ?? -1) > (rhs.rating ?? -1) }
            return lhs.content.count > rhs.content.count
        }.first
    }

    private static func craftCredits(_ crew: [CrewMember]) -> [VODCraftCredit] {
        struct CraftSpec { let role: String; let jobs: [String] }
        let specs: [CraftSpec] = [
            .init(role: "CINEMATOGRAPHY", jobs: ["Director of Photography", "Cinematography"]),
            .init(role: "ORIGINAL SCORE", jobs: ["Original Music Composer", "Music"]),
            .init(role: "EDITING", jobs: ["Editor"]),
            .init(role: "PRODUCTION DESIGN", jobs: ["Production Design", "Production Designer"]),
            .init(role: "COSTUME DESIGN", jobs: ["Costume Design", "Costume Designer"]),
            .init(role: "VISUAL EFFECTS", jobs: ["Visual Effects Supervisor", "VFX Supervisor"]),
            .init(role: "SOUND", jobs: ["Sound Designer", "Supervising Sound Editor", "Sound Re-Recording Mixer"]),
            .init(role: "SCREENPLAY", jobs: ["Screenplay", "Teleplay", "Writer"])
        ]
        var output: [VODCraftCredit] = []
        var usedPeople = Set<String>()
        for spec in specs {
            let accepted = Set(spec.jobs.map { $0.lowercased() })
            let matches = crew.filter { member in
                guard let job = clean(member.job)?.lowercased() else { return false }
                return accepted.contains(job)
            }
            var names: [String] = []
            var firstProfileURL: String? = nil
            for member in matches {
                guard let name = clean(member.name) else { continue }
                let personKey = name.lowercased()
                guard !usedPeople.contains(personKey) else { continue }
                usedPeople.insert(personKey)
                names.append(name)
                if firstProfileURL == nil, let path = clean(member.profile_path) {
                    firstProfileURL = "https://image.tmdb.org/t/p/w185\(path)"
                }
                if names.count >= 2 { break }
            }
            if !names.isEmpty {
                output.append(VODCraftCredit(role: spec.role, name: names.joined(separator: " • "), profileURL: firstProfileURL))
            }
            if output.count >= 8 { break }
        }
        return output
    }

    private static func fanartSpecialtyArtwork(kind: String, tmdbID: String, tvdbID: Int?, apiKey: String) async -> FanartSpecialtyArtwork {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return FanartSpecialtyArtwork() }
        let normalizedKind = kind.lowercased() == "tv" ? "tv" : "movie"
        let fanartID: String
        if normalizedKind == "tv" {
            guard let tvdbID, tvdbID > 0 else { return FanartSpecialtyArtwork() }
            fanartID = String(tvdbID)
        } else {
            fanartID = tmdbID
        }
        let endpoint = normalizedKind == "tv" ? "tv" : "movies"
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://webservice.fanart.tv/v3/\(endpoint)/\(fanartID)?api_key=\(encodedKey)") else {
            return FanartSpecialtyArtwork()
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS-vBRDC193-SpotlightHub", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, data.count <= 5_000_000 else { return FanartSpecialtyArtwork() }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return FanartSpecialtyArtwork() }
            if normalizedKind == "tv" {
                let decoded = try JSONDecoder().decode(FanartTVResponse.self, from: data)
                return FanartSpecialtyArtwork(
                    clearArt: rankedFanartURLs([decoded.hdclearart, decoded.clearart], limit: 4),
                    characterArt: rankedFanartURLs([decoded.characterart], limit: 4),
                    discArt: []
                )
            }
            let decoded = try JSONDecoder().decode(FanartMovieResponse.self, from: data)
            return FanartSpecialtyArtwork(
                clearArt: rankedFanartURLs([decoded.hdmovieclearart, decoded.movieart], limit: 4),
                characterArt: [],
                discArt: rankedFanartURLs([decoded.moviedisc], limit: 3)
            )
        } catch {
            return FanartSpecialtyArtwork()
        }
    }

    private static func rankedFanartURLs(_ groups: [[FanartImage]?], limit: Int) -> [String] {
        let ranked = groups.flatMap { $0 ?? [] }.sorted { lhs, rhs in
            let leftLang = (lhs.lang ?? "").lowercased()
            let rightLang = (rhs.lang ?? "").lowercased()
            let leftPreferred = leftLang == "en" || leftLang == "00" || leftLang.isEmpty
            let rightPreferred = rightLang == "en" || rightLang == "00" || rightLang.isEmpty
            if leftPreferred != rightPreferred { return leftPreferred && !rightPreferred }
            return lhs.score > rhs.score
        }
        var seen = Set<String>()
        let urls: [String] = ranked.compactMap { image -> String? in
            guard let raw = clean(image.url),
                  (raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://")),
                  seen.insert(raw.lowercased()).inserted else { return nil }
            if raw.lowercased().hasPrefix("http://") { return "https://" + String(raw.dropFirst("http://".count)) }
            return raw
        }
        return Array(urls.prefix(max(1, limit)))
    }


    private static func artwork(_ images: ArtworkImages?) -> (landscape: [String], aspectRatios: [String: Double], logo: String?) {
        // Prefer language-neutral backdrops. TMDB language-tagged backdrop art is commonly
        // promotional copy (for example countdowns such as “10 days” or “tomorrow”).
        // Keeping null-language art avoids those time-sensitive banners while preserving
        // official backdrops/fanart that can be shown fully in the Production panel.
        let backdropValues = (images?.backdrops ?? [])
            .filter { image in
                guard clean(image.file_path) != nil else { return false }
                guard clean(image.iso_639_1) == nil else { return false }
                let width = image.width ?? 0
                let height = image.height ?? 0
                let aspect = image.aspect_ratio ?? (height > 0 ? Double(width) / Double(height) : 0)
                guard aspect >= 1.45 else { return false }
                return width == 0 || width >= 780
            }
            .sorted { lhs, rhs in
                let leftVotes = lhs.vote_count ?? 0
                let rightVotes = rhs.vote_count ?? 0
                if leftVotes != rightVotes { return leftVotes > rightVotes }
                let leftScore = lhs.vote_average ?? 0
                let rightScore = rhs.vote_average ?? 0
                if leftScore != rightScore { return leftScore > rightScore }
                return (lhs.width ?? 0) > (rhs.width ?? 0)
            }

        var seenBackdropPaths = Set<String>()
        var aspectRatios: [String: Double] = [:]
        let landscape = backdropValues.compactMap { image -> String? in
            guard let path = clean(image.file_path), seenBackdropPaths.insert(path.lowercased()).inserted else { return nil }
            let url = "https://image.tmdb.org/t/p/w1280\(path)"
            let width = image.width ?? 0
            let height = image.height ?? 0
            let ratio = image.aspect_ratio ?? (height > 0 ? Double(width) / Double(height) : 0)
            if ratio > 0 { aspectRatios[url] = ratio }
            return url
        }

        let logo = (images?.logos ?? [])
            .filter { clean($0.file_path) != nil }
            .sorted { lhs, rhs in
                let leftEnglish = lhs.iso_639_1?.lowercased() == "en" ? 1 : 0
                let rightEnglish = rhs.iso_639_1?.lowercased() == "en" ? 1 : 0
                if leftEnglish != rightEnglish { return leftEnglish > rightEnglish }
                let leftVotes = lhs.vote_count ?? 0
                let rightVotes = rhs.vote_count ?? 0
                if leftVotes != rightVotes { return leftVotes > rightVotes }
                let leftScore = lhs.vote_average ?? 0
                let rightScore = rhs.vote_average ?? 0
                if leftScore != rightScore { return leftScore > rightScore }
                return (lhs.width ?? 0) > (rhs.width ?? 0)
            }
            .compactMap { clean($0.file_path) }
            .first
            .map { "https://image.tmdb.org/t/p/w500\($0)" }

        return (landscape, aspectRatios, logo)
    }

    private static func request<T: Decodable>(_ type: T.Type, url: URL) async -> T? {
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS-v1112-CompactProductionPanel", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private static func makeURL(path: String, apiKey: String, query: [URLQueryItem]) -> URL? {
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

    private static func companies(_ values: [Company]) -> [VODProductionCompany] {
        var seen = Set<String>()
        return values.compactMap { company in
            guard let name = clean(company.name), seen.insert(name.lowercased()).inserted else { return nil }
            let logoURL = clean(company.logo_path).map { "https://image.tmdb.org/t/p/w185\($0)" }
            return VODProductionCompany(name: name, logoURL: logoURL)
        }
    }

    private static func preferredMovieRating(_ countries: [MovieReleaseCountry]) -> String? {
        let ordered = countries.sorted { lhs, rhs in
            let leftUS = lhs.iso_3166_1?.uppercased() == "US"
            let rightUS = rhs.iso_3166_1?.uppercased() == "US"
            return leftUS && !rightUS
        }
        for country in ordered {
            let entries = (country.release_dates ?? []).sorted { lhs, rhs in
                let left = lhs.type == 3 ? 0 : (lhs.type == 4 ? 1 : 2)
                let right = rhs.type == 3 ? 0 : (rhs.type == 4 ? 1 : 2)
                return left < right
            }
            if let rating = entries.compactMap({ clean($0.certification) }).first {
                return rating.uppercased()
            }
        }
        return nil
    }

    private static func preferredTVRating(_ ratings: [TVContentRating]) -> String? {
        let ordered = ratings.sorted { lhs, rhs in
            let leftUS = lhs.iso_3166_1?.uppercased() == "US"
            let rightUS = rhs.iso_3166_1?.uppercased() == "US"
            return leftUS && !rightUS
        }
        return ordered.compactMap { clean($0.rating) }.first?.uppercased()
    }

    private static func clean(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
