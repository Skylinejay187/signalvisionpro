import Foundation

struct CastExplorerCredit: Identifiable, Hashable {
    let id: String
    let tmdbID: Int
    let mediaType: String
    let title: String
    let character: String?
    let year: String?
    let posterURL: String?
    let popularity: Double
    let voteAverage: Double
    let isUpcoming: Bool
}

// Phase 15: Cast Explorer credits now carry a canonical app media identity so a
// selected credit can enter the exact same Details/Source Intelligence/playback
// pipeline as a Search/TMDB result. No separate resolver or player path is created.
extension CastExplorerCredit {
    var mediaItem: MediaItem {
        let normalizedType = mediaType.lowercased() == "movie" ? "movie" : "series"
        let identityType = normalizedType == "movie" ? "movie" : "tv"
        let cleanCharacter = character?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = cleanCharacter.isEmpty ? "Cast Explorer credit" : "Cast Explorer credit • \(cleanCharacter)"
        let formattedRating = voteAverage > 0 ? String(format: "%.1f", voteAverage) : ""
        return MediaItem(
            id: "tmdb:\(identityType):\(tmdbID)",
            tmdbId: String(tmdbID),
            title: title,
            year: year ?? "",
            type: normalizedType,
            catalog: "Cast Explorer",
            description: description,
            genres: normalizedType == "movie" ? ["Movie"] : ["TV Show"],
            rating: formattedRating,
            posterURL: posterURL,
            landscapeURL: posterURL,
            logoURL: nil
        )
    }
}

struct CastExplorerSnapshot: Hashable {
    let personID: Int?
    let name: String
    let profileURL: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let homepage: String?
    let tmdbPopularity: Double?
    let imdbPersonID: String?
    let wikidataID: String?
    let reportedNetWorthUSD: Double?
    let netWorthAsOf: String?
    let occupations: [String]
    let citizenships: [String]
    let education: [String]
    let awards: [String]
    let spouses: [String]
    let partners: [String]
    let children: [String]
    let parents: [String]
    let siblings: [String]
    let knownFor: [CastExplorerCredit]
    let movies: [CastExplorerCredit]
    let shows: [CastExplorerCredit]
    let upcoming: [CastExplorerCredit]
}

actor CastExplorerRepository {
    static let shared = CastExplorerRepository()

    private struct CacheEntry {
        let snapshot: CastExplorerSnapshot
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var order: [String] = []
    private let maximumEntries = 24
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    func snapshot(for member: CastMember, currentItem: MediaItem, tmdbAPIKey: String) async -> CastExplorerSnapshot? {
        let key = cacheKey(member: member, currentItem: currentItem)
        if let entry = cache[key], Date().timeIntervalSince(entry.storedAt) < ttl {
            touch(key)
            return entry.snapshot
        }

        let snapshot = await CastExplorerService.load(member: member, currentItem: currentItem, tmdbAPIKey: tmdbAPIKey)
        if let snapshot {
            cache[key] = CacheEntry(snapshot: snapshot, storedAt: Date())
            touch(key)
            trimIfNeeded()
        }
        return snapshot
    }

    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    private func cacheKey(member: CastMember, currentItem: MediaItem) -> String {
        let person = member.tmdbPersonId.map(String.init) ?? member.name.lowercased()
        return "\(person)|\(currentItem.tmdbId ?? currentItem.id)"
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trimIfNeeded() {
        while order.count > maximumEntries {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

private enum CastExplorerService {
    private struct TMDBSearchResponse: Decodable { let results: [TMDBSearchPerson] }
    private struct TMDBSearchPerson: Decodable {
        let id: Int
        let name: String
        let popularity: Double?
    }

    private struct TMDBPersonResponse: Decodable {
        let id: Int
        let name: String
        let biography: String?
        let birthday: String?
        let deathday: String?
        let place_of_birth: String?
        let known_for_department: String?
        let popularity: Double?
        let profile_path: String?
        let homepage: String?
        let combined_credits: TMDBCombinedCredits?
        let external_ids: TMDBPersonExternalIDs?
    }

    private struct TMDBPersonExternalIDs: Decodable {
        let imdb_id: String?
    }

    private struct TMDBCombinedCredits: Decodable { let cast: [TMDBCombinedCredit]? }
    private struct TMDBCombinedCredit: Decodable {
        let id: Int
        let media_type: String?
        let title: String?
        let name: String?
        let character: String?
        let poster_path: String?
        let release_date: String?
        let first_air_date: String?
        let vote_average: Double?
        let vote_count: Int?
        let popularity: Double?
    }

    private struct WikidataSearchResponse: Decodable { let search: [WikidataSearchItem] }
    private struct WikidataSearchItem: Decodable {
        let id: String
        let label: String?
        let description: String?
    }

    private struct WikidataLabelsResponse: Decodable { let entities: [String: WikidataLabelEntity] }
    private struct WikidataLabelEntity: Decodable { let labels: [String: WikidataLabelValue]? }
    private struct WikidataLabelValue: Decodable { let value: String }

    private struct WikidataFacts: Sendable {
        var qid: String? = nil
        var netWorthUSD: Double? = nil
        var netWorthAsOf: String? = nil
        var occupations: [String] = []
        var citizenships: [String] = []
        var education: [String] = []
        var awards: [String] = []
        var spouses: [String] = []
        var partners: [String] = []
        var children: [String] = []
        var parents: [String] = []
        var siblings: [String] = []
    }

    static func load(member: CastMember, currentItem: MediaItem, tmdbAPIKey: String) async -> CastExplorerSnapshot? {
        let cleanKey = tmdbAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let personID: Int?
        if let id = member.tmdbPersonId {
            personID = id
        } else if !cleanKey.isEmpty {
            personID = await resolveTMDBPersonID(name: member.name, apiKey: cleanKey)
        } else {
            personID = nil
        }

        var person: TMDBPersonResponse? = nil
        if let personID, !cleanKey.isEmpty {
            person = await loadTMDBPerson(id: personID, apiKey: cleanKey)
        }

        // Wikidata is open structured data and is optional. It is queried only after the
        // user explicitly opens Cast Explorer, never because a cast portrait merely exists.
        // vBRDC106: TMDB owns the Cast Explorer filmography. Optional Wikidata facts
        // get a short bounded enrichment window and can never hold Known For / Movies / TV
        // rows behind multi-second open-data requests.
        let wikidata = await loadWikidataFactsBounded(
            name: person?.name ?? member.name,
            birthday: person?.birthday
        )

        let credits = normalizedCredits(person?.combined_credits?.cast ?? [], currentItem: currentItem)
        let movies = credits.filter { $0.mediaType == "movie" && !$0.isUpcoming }
        let shows = credits.filter { $0.mediaType == "tv" && !$0.isUpcoming }
        let upcoming = credits.filter(\.isUpcoming)
        let knownFor = credits
            .filter { !$0.isUpcoming }
            .sorted { lhs, rhs in
                if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
                return lhs.voteAverage > rhs.voteAverage
            }
            .prefix(12)

        let fallbackProfile = member.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = person?.profile_path.map { "https://image.tmdb.org/t/p/h632\($0)" } ?? (fallbackProfile?.isEmpty == false ? fallbackProfile : nil)
        let biography = person?.biography?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Return a partial open-data snapshot even when no TMDB key is configured.
        let hasUsefulData = person != nil || wikidata.qid != nil || !credits.isEmpty
        guard hasUsefulData else { return nil }

        return CastExplorerSnapshot(
            personID: person?.id ?? personID,
            name: person?.name ?? member.name,
            profileURL: profile,
            biography: biography?.isEmpty == false ? biography : nil,
            birthday: person?.birthday,
            deathday: person?.deathday,
            placeOfBirth: person?.place_of_birth,
            knownForDepartment: person?.known_for_department,
            homepage: person?.homepage,
            tmdbPopularity: person?.popularity,
            imdbPersonID: person?.external_ids?.imdb_id,
            wikidataID: wikidata.qid,
            reportedNetWorthUSD: wikidata.netWorthUSD,
            netWorthAsOf: wikidata.netWorthAsOf,
            occupations: wikidata.occupations,
            citizenships: wikidata.citizenships,
            education: wikidata.education,
            awards: wikidata.awards,
            spouses: wikidata.spouses,
            partners: wikidata.partners,
            children: wikidata.children,
            parents: wikidata.parents,
            siblings: wikidata.siblings,
            knownFor: Array(knownFor),
            movies: movies,
            shows: shows,
            upcoming: upcoming
        )
    }

    private static func resolveTMDBPersonID(name: String, apiKey: String) async -> Int? {
        guard let url = tmdbURL(path: "search/person", apiKey: apiKey, extra: [
            URLQueryItem(name: "query", value: name),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "page", value: "1")
        ]) else { return nil }
        guard let response: TMDBSearchResponse = await fetch(url, timeout: 7) else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return response.results
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cleanName })?.id
            ?? response.results.first?.id
    }

    private static func loadTMDBPerson(id: Int, apiKey: String) async -> TMDBPersonResponse? {
        guard let url = tmdbURL(path: "person/\(id)", apiKey: apiKey, extra: [
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "append_to_response", value: "combined_credits,external_ids")
        ]) else { return nil }
        return await fetch(url, timeout: 8)
    }

    private static func normalizedCredits(_ raw: [TMDBCombinedCredit], currentItem: MediaItem) -> [CastExplorerCredit] {
        let today = isoDateString(Date())
        var seen = Set<String>()
        var output: [CastExplorerCredit] = []

        for credit in raw {
            let mediaType = (credit.media_type ?? "").lowercased()
            guard mediaType == "movie" || mediaType == "tv" else { continue }
            let title = (mediaType == "movie" ? credit.title : credit.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            let key = "\(mediaType):\(credit.id)"
            guard seen.insert(key).inserted else { continue }
            let date = (mediaType == "movie" ? credit.release_date : credit.first_air_date)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isUpcoming = date.map { !$0.isEmpty && $0 > today } ?? false
            let year = date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
            let poster = credit.poster_path.map { "https://image.tmdb.org/t/p/w342\($0)" }
            output.append(CastExplorerCredit(
                id: key,
                tmdbID: credit.id,
                mediaType: mediaType,
                title: title,
                character: credit.character?.trimmingCharacters(in: .whitespacesAndNewlines),
                year: year,
                posterURL: poster,
                popularity: max(0, credit.popularity ?? 0),
                voteAverage: max(0, credit.vote_average ?? 0),
                isUpcoming: isUpcoming
            ))
        }

        return output.sorted { lhs, rhs in
            if lhs.isUpcoming != rhs.isUpcoming { return !lhs.isUpcoming }
            if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
            return lhs.voteAverage > rhs.voteAverage
        }
    }

    private static func loadWikidataFactsBounded(name: String, birthday: String?) async -> WikidataFacts {
        await withTaskGroup(of: WikidataFacts.self, returning: WikidataFacts.self) { group in
            group.addTask {
                await loadWikidataFacts(name: name, birthday: birthday)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                return WikidataFacts()
            }
            let first = await group.next() ?? WikidataFacts()
            group.cancelAll()
            return first
        }
    }

    private static func loadWikidataFacts(name: String, birthday: String?) async -> WikidataFacts {
        guard let qid = await searchWikidataQID(name: name) else { return WikidataFacts() }
        guard let url = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json"),
              let data = await fetchData(url, timeout: 7),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any] else {
            var fallback = WikidataFacts(); fallback.qid = qid; return fallback
        }

        // If TMDB supplied a birthday, reject a same-name Wikidata match whose birth year
        // plainly disagrees. This avoids attaching celebrity facts to the wrong person.
        if let birthday, let expectedYear = yearPrefix(birthday),
           let wdBirth = firstTimeClaim("P569", entity: entity), let wdYear = yearPrefix(wdBirth),
           expectedYear != wdYear {
            return WikidataFacts()
        }

        let occupationIDs = entityIDs("P106", entity: entity, limit: 4)
        let citizenshipIDs = entityIDs("P27", entity: entity, limit: 3)
        let educationIDs = entityIDs("P69", entity: entity, limit: 6)
        let awardIDs = entityIDs("P166", entity: entity, limit: 10)
        let spouseIDs = entityIDs("P26", entity: entity, limit: 6)
        let partnerIDs = entityIDs("P451", entity: entity, limit: 6)
        let childIDs = entityIDs("P40", entity: entity, limit: 12)
        let parentIDs = entityIDs("P22", entity: entity, limit: 4) + entityIDs("P25", entity: entity, limit: 4)
        let siblingIDs = entityIDs("P3373", entity: entity, limit: 10)
        let allIDs = Array(Set(occupationIDs + citizenshipIDs + educationIDs + awardIDs + spouseIDs + partnerIDs + childIDs + parentIDs + siblingIDs))
        let labels = await labelsForEntities(allIDs)
        let netWorth = reportedNetWorth(entity: entity)

        return WikidataFacts(
            qid: qid,
            netWorthUSD: netWorth.amount,
            netWorthAsOf: netWorth.asOf,
            occupations: occupationIDs.compactMap { labels[$0] },
            citizenships: citizenshipIDs.compactMap { labels[$0] },
            education: educationIDs.compactMap { labels[$0] },
            awards: awardIDs.compactMap { labels[$0] },
            spouses: spouseIDs.compactMap { labels[$0] },
            partners: partnerIDs.compactMap { labels[$0] },
            children: childIDs.compactMap { labels[$0] },
            parents: parentIDs.compactMap { labels[$0] },
            siblings: siblingIDs.compactMap { labels[$0] }
        )
    }

    private static func searchWikidataQID(name: String) async -> String? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: name),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "type", value: "item"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url, let response: WikidataSearchResponse = await fetch(url, timeout: 7) else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = response.search.filter { ($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == clean }
        let personLike = exact.first(where: {
            let text = ($0.description ?? "").lowercased()
            return ["actor", "actress", "film", "television", "performer", "director", "comedian", "singer"].contains(where: text.contains)
        })
        return personLike?.id ?? exact.first?.id
    }

    private static func entityIDs(_ property: String, entity: [String: Any], limit: Int) -> [String] {
        guard let claims = entity["claims"] as? [String: Any], let entries = claims[property] as? [[String: Any]] else { return [] }
        var result: [String] = []
        for entry in entries {
            guard let mainsnak = entry["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let value = datavalue["value"] as? [String: Any],
                  let id = value["id"] as? String else { continue }
            if !result.contains(id) { result.append(id) }
            if result.count >= limit { break }
        }
        return result
    }

    private static func firstTimeClaim(_ property: String, entity: [String: Any]) -> String? {
        guard let claims = entity["claims"] as? [String: Any], let entries = claims[property] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let mainsnak = entry["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let value = datavalue["value"] as? [String: Any],
                  let time = value["time"] as? String else { continue }
            return time
        }
        return nil
    }

    private static func reportedNetWorth(entity: [String: Any]) -> (amount: Double?, asOf: String?) {
        guard let claims = entity["claims"] as? [String: Any], let entries = claims["P2218"] as? [[String: Any]] else { return (nil, nil) }
        for entry in entries {
            guard let mainsnak = entry["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let value = datavalue["value"] as? [String: Any],
                  let amountText = value["amount"] as? String,
                  let amount = Double(amountText), amount >= 0 else { continue }
            let unit = value["unit"] as? String
            // Wikidata Q4917 is United States dollar. Hide other currencies rather than
            // pretending every reported quantity is USD.
            guard unit?.hasSuffix("/Q4917") == true else { continue }
            var asOf: String? = nil
            if let qualifiers = entry["qualifiers"] as? [String: Any],
               let points = qualifiers["P585"] as? [[String: Any]],
               let first = points.first,
               let datavalue = first["datavalue"] as? [String: Any],
               let timeValue = datavalue["value"] as? [String: Any],
               let time = timeValue["time"] as? String {
                asOf = yearPrefix(time)
            }
            return (amount, asOf)
        }
        return (nil, nil)
    }

    private static func labelsForEntities(_ ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: ids.prefix(50).joined(separator: "|")),
            URLQueryItem(name: "props", value: "labels"),
            URLQueryItem(name: "languages", value: "en"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url, let response: WikidataLabelsResponse = await fetch(url, timeout: 7) else { return [:] }
        var output: [String: String] = [:]
        for (id, entity) in response.entities {
            if let label = entity.labels?["en"]?.value, !label.isEmpty { output[id] = label }
        }
        return output
    }

    private static func tmdbURL(path: String, apiKey: String, extra: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + extra
        return components?.url
    }

    private static func fetch<T: Decodable>(_ url: URL, timeout: TimeInterval) async -> T? {
        guard let data = await fetchData(url, timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func fetchData(_ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1136 CastExplorer", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func yearPrefix(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return String(digits.prefix(4))
    }
}
