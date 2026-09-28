import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(Network) && canImport(Security)
import Network
import Security
#endif

/// vBRDC060: TorBox-native Usenet is a first-class provider independent of Torrentio.
///
/// Discovery prefers a configured whitelisted TorBox Search bridge because TorBox now
/// restricts its internal Search API by source IP. Direct device/backend/Newznab routes
/// remain compatibility fallbacks, followed by matching already-owned TorBox Usenet
/// downloads through the Main API. Playback remains native to TorBox or a resolved bridge URL.
/// Playback always stays native to TorBox Main API.
/// Torrentio is never consulted and removing Torrentio never removes or disables this lane.
struct TorBoxUsenetSearchResult: Hashable {
    var hash: String
    var rawTitle: String
    var normalizedTitle: String
    var sizeBytes: Int64
    var tracker: String
    var nzbURL: String
    var age: String
    var cached: Bool
    var owned: Bool
    // vBRDC075: an IP-whitelisted AIOStreams TorBox Search bridge can hand the app
    // a service-resolved Stremio URL directly. Keep it on the native Usenet result so
    // Source Intelligence can show/play the row without pretending it is an NZB URL.
    var directPlaybackURL: String = ""
    var ownedDownloadID: Int? = nil
}

enum TorBoxUsenetError: LocalizedError {
    case missingAPIKey
    case unsupportedIdentity
    case http(Int, String)
    case invalidResponse(String)
    case unavailable(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "TorBox API key is missing."
        case .unsupportedIdentity:
            return "This title does not have an IMDb/TMDB/TVDB identity for TorBox Usenet search."
        case let .http(code, detail):
            return detail.isEmpty ? "TorBox returned HTTP \(code)." : "TorBox returned HTTP \(code): \(detail)"
        case let .invalidResponse(detail):
            return detail.isEmpty ? "TorBox returned an unexpected response." : detail
        case let .unavailable(detail):
            return detail
        case let .timedOut(detail):
            return detail
        }
    }
}

enum TorBoxUsenetClient {
    private static let searchBase = "https://search-api.torbox.app"
    private static let newznabAPI = "https://search-api.torbox.app/newznab/api"
    private static let apiBase = "https://api.torbox.app/v1/api/usenet"

    // vBRDC073: cancellation must remain cancellation all the way through the discovery
    // fallback chain. vBRDC072 converted cancelled URLSession work into ordinary route
    // failures, which allowed the task to continue and create another request after the
    // owning Source Intelligence search had already been retired.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue
    }

    private static func throwIfCancelled(_ error: Error? = nil) throws {
        if Task.isCancelled { throw CancellationError() }
        if let error, isCancellation(error) { throw CancellationError() }
    }

    // vBRDC051: Voyager has shipped more than one Usenet result schema in public
    // clients (for example age as either a String or number, and nzb/nzb_link aliases).
    // Keep parsing deliberately tolerant so one field-type change cannot make the entire
    // provider disappear from Source Intelligence.
    static func search(
        item: MediaItem,
        apiKey: String,
        backendBaseURL: String? = nil,
        bridgeManifestURL: String? = nil,
        session: URLSession = .shared
    ) async throws -> [TorBoxUsenetSearchResult] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TorBoxUsenetError.missingAPIKey }

        // vBRDC075: TorBox Search API access is source-IP-whitelisted. A television
        // device cannot obtain that infrastructure whitelist simply because the account
        // is Pro. Support a user-opted configured AIOStreams Direct Manifest as the first
        // discovery route; trusted public AIOStreams instances are the documented way to
        // reach TorBox Search from a whitelisted host. The app never sends the TorBox key
        // to the bridge here—the configured manifest already owns its service credentials.
        var discoveryErrors: [String] = []
        var completedDiscoveryRoute = false
        let cleanBridge = bridgeManifestURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanBridge.isEmpty {
            do {
                let bridged = try await searchViaConfiguredBridge(
                    item: item,
                    manifestURL: cleanBridge,
                    session: session
                )
                completedDiscoveryRoute = true
                if !bridged.isEmpty { return deduplicated(bridged) }
            } catch {
                try throwIfCancelled(error)
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                discoveryErrors.append("whitelisted bridge: \(message.isEmpty ? "unavailable" : message)")
            }
        }

        // vBRDC075: current working TorBox clients use the native JSON Search API as the
        // primary Usenet discovery surface. In particular, current IDs are expressed as
        // imdb_id / themoviedb_id / thetvdb_id. vBRDC073 still called the older
        // imdb / tmdb / tvdb path and placed that route behind Newznab, so a valid 200/zero
        // Newznab response could hide the one TorBox-native request most likely to return
        // NZBs. Search the current native API first; keep the relay and Newznab only as
        // independent fallback paths.

        do {
            let native = try await searchNativeVoyagerDirect(item: item, apiKey: key, session: session)
            completedDiscoveryRoute = true
            if !native.isEmpty { return deduplicated(native) }
        } catch {
            try throwIfCancelled(error)
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            discoveryErrors.append("native/device: \(message.isEmpty ? "unavailable" : message)")
        }

        if let backendBaseURL {
            do {
                let relayed = try await searchViaBackendRelay(
                    item: item,
                    apiKey: key,
                    backendBaseURL: backendBaseURL,
                    session: session
                )
                completedDiscoveryRoute = true
                if !relayed.isEmpty { return deduplicated(relayed) }
            } catch {
                try throwIfCancelled(error)
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                discoveryErrors.append("native/relay: \(message.isEmpty ? "unavailable" : message)")
            }
        }

        do {
            let newznab = try await searchNewznabDirect(item: item, apiKey: key, session: session)
            completedDiscoveryRoute = true
            if !newznab.isEmpty { return deduplicated(newznab) }
        } catch {
            try throwIfCancelled(error)
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            discoveryErrors.append("newznab/device: \(message.isEmpty ? "unavailable" : message)")
        }

        do {
            let owned = try await searchOwnedLibrary(item: item, apiKey: key, session: session)
            // Main-API library access proves TorBox authentication/processing is alive, but it
            // does NOT prove release discovery is alive. vBRDC073 counted an empty mylist call
            // as a completed discovery route, masking BAD_TOKEN/plan/Search-API errors as a
            // misleading zero-results response. Only a real Search API/Newznab/relay response
            // is allowed to establish completedDiscoveryRoute.
            if !owned.isEmpty { return deduplicated(owned) }
        } catch {
            try throwIfCancelled(error)
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            discoveryErrors.append("library: \(message.isEmpty ? "unavailable" : message)")
        }

        if completedDiscoveryRoute {
            if cleanBridge.isEmpty {
                throw TorBoxUsenetError.unavailable(
                    "TorBox Search is IP-whitelisted by TorBox. This Apple TV/backend path returned no releases. Configure Settings → Streaming Catalogs → TorBox Pro Search Bridge with a Direct Manifest URL from a trusted whitelisted AIOStreams instance."
                )
            }
            return []
        }
        let detail = discoveryErrors.joined(separator: "; ")
        throw TorBoxUsenetError.unavailable(
            "TorBox Pro Usenet discovery could not be reached. " +
            (detail.isEmpty ? "TorBox Search requires a whitelisted search host; configure the TorBox Pro Search Bridge." : detail)
        )
    }

    // vBRDC075: AIOStreams exposes a normal Stremio stream resource from a configured
    // Direct Manifest. When that configuration contains TorBox Search with Usenet only,
    // every returned stream is a TorBox-backed Usenet result and the whitelisted public
    // instance performs only the restricted discovery step.
    private static func searchViaConfiguredBridge(
        item: MediaItem,
        manifestURL: String,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        let normalizedManifestURL: String = {
            let clean = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.lowercased().hasPrefix("stremio://") {
                return "https://" + String(clean.dropFirst("stremio://".count))
            }
            return clean
        }()
        guard let manifest = URL(string: normalizedManifestURL),
              manifest.scheme?.lowercased() == "https",
              let host = manifest.host, !host.isEmpty else {
            throw TorBoxUsenetError.invalidResponse("TorBox Pro Search Bridge must be a valid HTTPS or stremio:// Direct Manifest URL.")
        }

        var baseString = manifest.absoluteString
        if let range = baseString.range(of: "/manifest.json", options: [.caseInsensitive, .backwards]) {
            baseString = String(baseString[..<range.lowerBound])
        } else if baseString.lowercased().hasSuffix("manifest.json") {
            baseString.removeLast("manifest.json".count)
        } else {
            while baseString.hasSuffix("/") { baseString.removeLast() }
        }
        while baseString.hasSuffix("/") { baseString.removeLast() }
        guard let base = URL(string: baseString),
              base.scheme?.lowercased() == "https",
              base.host?.caseInsensitiveCompare(host) == .orderedSame else {
            throw TorBoxUsenetError.invalidResponse("Could not derive the TorBox Pro Search Bridge stream base from the Direct Manifest URL.")
        }

        let mediaType = isSeriesItem(item) ? "series" : "movie"
        let ids = bridgeStreamIDs(for: item)
        guard !ids.isEmpty else { throw TorBoxUsenetError.unsupportedIdentity }

        var hadValidResponse = false
        var errors: [String] = []
        for streamID in ids {
            try Task.checkCancellation()
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
            guard let encodedID = streamID.addingPercentEncoding(withAllowedCharacters: allowed),
                  let endpoint = URL(string: "\(base.absoluteString)/stream/\(mediaType)/\(encodedID).json") else { continue }
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 22)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxProSearchBridge", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await dataWithTransientRetry(request: request, session: session, maxAttempts: 2)
                try validate(response: response, data: data)
                let decoded = try JSONDecoder().decode(StremioStreamResponse.self, from: data)
                hadValidResponse = true
                let mapped = (decoded.streams ?? []).compactMap { stream -> TorBoxUsenetSearchResult? in
                    let direct = (stream.url ?? stream.externalUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let directURL = URL(string: direct),
                          ["http", "https"].contains(directURL.scheme?.lowercased() ?? "") else { return nil }
                    let title = (stream.title ?? stream.name ?? stream.behaviorHints?.filename ?? "TorBox Usenet")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = title.isEmpty ? item.title : title
                    return TorBoxUsenetSearchResult(
                        hash: "",
                        rawTitle: normalized,
                        normalizedTitle: normalized,
                        sizeBytes: stream.behaviorHints?.videoSize ?? 0,
                        tracker: "AIOStreams TorBox Search Bridge",
                        nzbURL: "",
                        age: "",
                        cached: title.localizedCaseInsensitiveContains("cached"),
                        owned: title.localizedCaseInsensitiveContains("library") || title.localizedCaseInsensitiveContains("owned"),
                        directPlaybackURL: direct
                    )
                }
                if !mapped.isEmpty { return deduplicated(mapped) }
            } catch {
                try throwIfCancelled(error)
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                errors.append("\(streamID): \(detail.isEmpty ? "unavailable" : detail)")
            }
        }

        if hadValidResponse { return [] }
        throw TorBoxUsenetError.unavailable(
            "TorBox Pro Search Bridge did not return a readable Stremio stream response" +
            (errors.isEmpty ? "." : " (\(errors.prefix(2).joined(separator: "; "))).")
        )
    }

    private static func bridgeStreamIDs(for item: MediaItem) -> [String] {
        var values: [String] = []
        func add(_ raw: String) {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !values.contains(clean) else { return }
            values.append(clean)
        }
        let episodeSuffix: String = {
            guard isSeriesItem(item),
                  let season = item.seasonNumber,
                  let episode = item.episodeNumber,
                  episode > 0 else { return "" }
            return ":\(season):\(episode)"
        }()

        let imdb = (item.imdbId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if imdb.lowercased().hasPrefix("tt") { add(imdb + episodeSuffix) }
        let rawID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawID.lowercased().hasPrefix("tt") {
            let base = rawID.split(separator: ":").first.map(String.init) ?? rawID
            add(base + episodeSuffix)
        }
        if let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tmdb.isEmpty {
            add("tmdb:\(tmdb)\(episodeSuffix)")
        }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty {
            add("tvdb:\(tvdb)\(episodeSuffix)")
        }
        return values
    }

    private static func isSeriesItem(_ item: MediaItem) -> Bool {
        let kind = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kind == "series" || kind == "show" || kind == "tv" || item.seasonNumber != nil || item.episodeNumber != nil
    }

    private static func searchNewznabDirect(
        item: MediaItem,
        apiKey: String,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        let query = fullTextSearchQuery(for: item)
        guard !query.isEmpty else { throw TorBoxUsenetError.unsupportedIdentity }

        var urls: [URL] = []
        if let mediaURL = newznabSearchURL(item: item, apiKey: apiKey, generic: false) {
            urls.append(mediaURL)
        }
        if let genericURL = newznabSearchURL(item: item, apiKey: apiKey, generic: true),
           !urls.contains(genericURL) {
            urls.append(genericURL)
        }
        guard !urls.isEmpty else {
            throw TorBoxUsenetError.invalidResponse("Could not build the TorBox Newznab search URL.")
        }

        var errors: [String] = []
        var completed = false
        var collected: [TorBoxUsenetSearchResult] = []
        // Search both Newznab modes. Some indexers return materially different sets for
        // ID/media searches versus q= text searches; stopping after the first non-empty
        // route could hide otherwise valid Usenet releases. vBRDC073 merges/deduplicates
        // both modes and leaves the UI lane uncapped as established by vBRDC072.
        for url in urls {
            try Task.checkCancellation()
            do {
                let results = try await performNewznabSearch(url: url, apiKey: apiKey, session: session)
                completed = true
                collected.append(contentsOf: results)
            } catch {
                try throwIfCancelled(error)
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                errors.append(detail.isEmpty ? "Newznab request failed" : detail)
            }
        }
        if completed { return deduplicated(collected) }
        throw TorBoxUsenetError.unavailable("TorBox Newznab search failed (\(errors.prefix(3).joined(separator: "; "))).")
    }

    private static func newznabSearchURL(item: MediaItem, apiKey: String, generic: Bool) -> URL? {
        guard var components = URLComponents(string: newznabAPI) else { return nil }
        let query = fullTextSearchQuery(for: item)
        let isEpisode = (item.episodeNumber ?? 0) > 0 || item.seasonNumber != nil
        var items: [URLQueryItem] = [
            URLQueryItem(name: "t", value: generic ? "search" : (isEpisode ? "tvsearch" : "movie")),
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "limit", value: "100")
        ]
        if !generic, let identity = searchIdentity(for: item) {
            switch identity.type.lowercased() {
            case "imdb", "imdb_id":
                items.append(URLQueryItem(name: "imdbid", value: identity.id.replacingOccurrences(of: "tt", with: "")))
            case "tmdb", "tmdb_id", "themoviedb_id":
                items.append(URLQueryItem(name: "tmdbid", value: identity.id))
            case "tvdb", "tvdb_id", "thetvdb_id":
                items.append(URLQueryItem(name: "tvdbid", value: identity.id))
            default: break
            }
        }
        if !generic, let season = item.seasonNumber, season >= 0 {
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        if !generic, let episode = item.episodeNumber, episode > 0 {
            items.append(URLQueryItem(name: "ep", value: String(episode)))
        }
        components.queryItems = items
        return components.url
    }

    private static func performNewznabSearch(url: URL, apiKey: String, session: URLSession) async throws -> [TorBoxUsenetSearchResult] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Newznab clients authenticate with `apikey`; keep Bearer as a harmless secondary
        // credential accepted by TorBox surfaces while never persisting either form.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxNewznab", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await searchDataWithTransientRetry(request: request, session: session)
        try validateNewznab(response: response, data: data)
        return try parseNewznabResponse(data)
    }

    private static func validateNewznab(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TorBoxUsenetError.invalidResponse("TorBox Newznab returned no HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(1_024), encoding: .utf8) ?? ""
            let clean = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TorBoxUsenetError.http(http.statusCode, clean)
        }
    }

    private final class NewznabXMLCollector: NSObject, XMLParserDelegate {
        struct Item {
            var title = ""
            var link = ""
            var guid = ""
            var category = ""
            var pubDate = ""
            var enclosureURL = ""
            var enclosureLength: Int64 = 0
            var attributes: [String: String] = [:]
        }

        var items: [Item] = []
        var parserError: Error?
        var serviceErrorCode = ""
        var serviceErrorDescription = ""
        private var current: Item?
        private var element = ""
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            let name = (qName ?? elementName).lowercased()
            element = name
            buffer = ""
            if name == "error" {
                serviceErrorCode = attributeDict["code"] ?? ""
                serviceErrorDescription = attributeDict["description"] ?? attributeDict["message"] ?? ""
            } else if name == "item" {
                current = Item()
            } else if name == "enclosure", current != nil {
                current?.enclosureURL = attributeDict["url"] ?? ""
                current?.enclosureLength = Int64(attributeDict["length"] ?? "") ?? 0
            } else if (name == "newznab:attr" || name.hasSuffix(":attr") || name == "attr"), current != nil,
                      let attrName = attributeDict["name"]?.lowercased(), let value = attributeDict["value"] {
                current?.attributes[attrName] = value
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard current != nil else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = (qName ?? elementName).lowercased()
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if current != nil {
                switch name {
                case "title": current?.title += value
                case "link": current?.link += value
                case "guid": current?.guid += value
                case "category": current?.category += value
                case "pubdate": current?.pubDate += value
                case "item":
                    if let current { items.append(current) }
                    current = nil
                default: break
                }
            }
            element = ""
            buffer = ""
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            parserError = parseError
        }
    }

    private static func parseNewznabResponse(_ data: Data) throws -> [TorBoxUsenetSearchResult] {
        let collector = NewznabXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        let parsed = parser.parse()
        if !parsed {
            let prefix = String(data: data.prefix(512), encoding: .utf8) ?? ""
            if prefix.lowercased().contains("<error") {
                throw TorBoxUsenetError.unavailable("TorBox Newznab rejected the search: \(prefix.replacingOccurrences(of: "\n", with: " "))")
            }
            throw TorBoxUsenetError.invalidResponse("TorBox Newznab returned unreadable XML: \(collector.parserError?.localizedDescription ?? "parse failure")")
        }

        // Newznab <error/> is valid XML, so XMLParser.parse() returns true. vBRDC072
        // therefore misreported authentication/account/service errors as a real zero-link
        // search. Promote the service error before evaluating item count.
        if !collector.serviceErrorCode.isEmpty || !collector.serviceErrorDescription.isEmpty {
            let code = collector.serviceErrorCode.isEmpty ? "unknown" : collector.serviceErrorCode
            let detail = collector.serviceErrorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TorBoxUsenetError.unavailable(
                "TorBox Newznab rejected the search (code \(code))\(detail.isEmpty ? "." : ": \(detail)")"
            )
        }

        return collector.items.compactMap { item in
            let rawTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawNZBURL = (item.enclosureURL.isEmpty ? item.link : item.enclosureURL).trimmingCharacters(in: .whitespacesAndNewlines)
            let nzbURL = normalizedNewznabResultURL(rawNZBURL)
            guard !rawTitle.isEmpty, !nzbURL.isEmpty else { return nil }
            let attrs = item.attributes
            let size = Int64(attrs["size"] ?? "") ?? item.enclosureLength
            let hash = attrs["hash"] ?? attrs["nzbhash"] ?? attrs["usenet_hash"] ?? ((item.guid.contains("://") || item.guid.contains("apikey=")) ? "" : item.guid)
            let tracker = attrs["indexer"] ?? attrs["source"] ?? (item.category.isEmpty ? "TorBox Newznab" : item.category)
            let cached = boolString(attrs["cached"] ?? attrs["cache"])
            let owned = boolString(attrs["owned"] ?? attrs["is_owned"])
            let age = attrs["age"] ?? item.pubDate
            return TorBoxUsenetSearchResult(
                hash: hash,
                rawTitle: rawTitle,
                normalizedTitle: rawTitle,
                sizeBytes: size,
                tracker: tracker,
                nzbURL: nzbURL,
                age: age,
                cached: cached,
                owned: owned,
                ownedDownloadID: nil
            )
        }
    }

    private static func normalizedNewznabResultURL(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        if let absolute = URL(string: clean), let scheme = absolute.scheme?.lowercased(), ["https", "http"].contains(scheme) {
            return absolute.absoluteString
        }
        guard let base = URL(string: newznabAPI),
              let resolved = URL(string: clean, relativeTo: base)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return ""
        }
        return resolved.absoluteString
    }

    private static func boolString(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "cached", "owned"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func searchNativeVoyagerDirect(item: MediaItem, apiKey: String, session: URLSession) async throws -> [TorBoxUsenetSearchResult] {
        let query = fullTextSearchQuery(for: item)
        var errors: [String] = []
        var hadSuccessfulRequest = false

        for includeUserEngines in [false, true] {
            for identity in searchIdentities(for: item) {
                do {
                    let results = try await searchByID(
                        identityType: identity.type,
                        identityID: identity.id,
                        item: item,
                        apiKey: apiKey,
                        includeUserEngines: includeUserEngines,
                        session: session
                    )
                    hadSuccessfulRequest = true
                    if !results.isEmpty { return deduplicated(results) }
                } catch {
                    try throwIfCancelled(error)
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    errors.append("ID/\(identity.type)/\(includeUserEngines ? "extended" : "native"): \(detail.isEmpty ? "unavailable" : detail)")
                }
            }

            if !query.isEmpty {
                do {
                    let results = try await searchByQuery(
                        query,
                        item: item,
                        apiKey: apiKey,
                        includeUserEngines: includeUserEngines,
                        session: session
                    )
                    hadSuccessfulRequest = true
                    if !results.isEmpty { return deduplicated(results) }
                } catch {
                    try throwIfCancelled(error)
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    errors.append("query/\(includeUserEngines ? "extended" : "native"): \(detail.isEmpty ? "unavailable" : detail)")
                }
            }
        }

        if hadSuccessfulRequest { return [] }
        if errors.isEmpty { throw TorBoxUsenetError.unsupportedIdentity }
        throw TorBoxUsenetError.unavailable("TorBox native Usenet search failed (\(errors.prefix(4).joined(separator: "; "))).")
    }

    private static func searchViaBackendRelay(
        item: MediaItem,
        apiKey: String,
        backendBaseURL: String,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        let base = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/torbox/usenet/search"), url.scheme?.lowercased() == "https" else {
            throw TorBoxUsenetError.invalidResponse("Debrid Channels Usenet relay requires a valid HTTPS backend URL.")
        }

        var lastResults: [TorBoxUsenetSearchResult] = []
        var errors: [String] = []
        for includeUserEngines in [false, true] {
            var payload: [String: Any] = [
                "query": fullTextSearchQuery(for: item),
                "metadata": false,
                "checkCache": true,
                "checkOwned": true,
                "searchUserEngines": includeUserEngines,
                "cachedOnly": false
            ]
            // The deployed v694 relay still accepts the historical short ID names.
            // Keep that wire contract for backward compatibility while the on-device
            // primary path above uses TorBox's current external ID spelling.
            if let identity = legacySearchIdentity(for: item) {
                payload["identityType"] = identity.type
                payload["identityID"] = identity.id
            }
            if let season = item.seasonNumber, season >= 0 { payload["season"] = season }
            if let episode = item.episodeNumber, episode > 0 { payload["episode"] = episode }

            var request = URLRequest(url: url, timeoutInterval: 22)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // The token travels only over HTTPS to the user's configured Debrid Channels
            // backend and is never persisted by the search-only relay.
            request.setValue(apiKey, forHTTPHeaderField: "X-TorBox-Token")
            request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxUsenetRelay", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await dataWithTransientRetry(request: request, session: session)
                try validate(response: response, data: data)
                let results = try parseSearchResponse(data)
                lastResults = results
                if !results.isEmpty { return results }
            } catch {
                try throwIfCancelled(error)
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                errors.append("\(includeUserEngines ? "extended" : "native"): \(detail.isEmpty ? "unavailable" : detail)")
            }
        }

        if !errors.isEmpty, lastResults.isEmpty {
            throw TorBoxUsenetError.unavailable("Debrid Channels TorBox Search relay failed (\(errors.prefix(2).joined(separator: "; "))).")
        }
        return lastResults
    }

    private static func searchOwnedLibrary(
        item: MediaItem,
        apiKey: String,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        guard let url = URL(string: "\(apiBase)/mylist?limit=1000") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxUsenetLibrary", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let objects: [[String: Any]]
        if let list = root["data"] as? [[String: Any]] { objects = list }
        else if let one = root["data"] as? [String: Any] { objects = [one] }
        else { objects = [] }

        let titleTokens = normalizedMatchTokens(item.title)
        let expectedEpisode: String? = {
            guard let season = item.seasonNumber, let episode = item.episodeNumber, episode > 0 else { return nil }
            return String(format: "s%02de%02d", season, episode)
        }()
        let expectedYear = item.year.trimmingCharacters(in: .whitespacesAndNewlines)

        return objects.compactMap { download in
            guard let downloadID = integer(download["id"]), downloadID > 0 else { return nil }
            let rawTitle = string(download["name"] ?? download["title"] ?? download["original_name"]) ?? ""
            guard !rawTitle.isEmpty else { return nil }
            let normalized = normalizedMatchText(rawTitle)
            guard !titleTokens.isEmpty, titleTokens.allSatisfy({ normalized.contains($0) }) else { return nil }
            if let expectedEpisode, !normalized.replacingOccurrences(of: " ", with: "").contains(expectedEpisode) { return nil }
            if expectedEpisode == nil, expectedYear.count == 4 {
                let years = normalized.split(separator: " ").map(String.init).filter { token in
                    token.count == 4 && Int(token) != nil
                }
                if !years.isEmpty && !years.contains(expectedYear) { return nil }
            }

            let hash = string(download["hash"] ?? download["md5"] ?? download["download_hash"]) ?? ""
            let fileSizes = (download["files"] as? [[String: Any]] ?? []).compactMap { integer64($0["size"] ?? $0["bytes"]) }
            let size = integer64(download["size"] ?? download["download_size"] ?? download["bytes"]) ?? fileSizes.max() ?? 0
            let finished = bool(download["download_finished"]) ?? false
            let present = bool(download["download_present"]) ?? false
            let cached = bool(download["cached"]) ?? (finished && present)
            return TorBoxUsenetSearchResult(
                hash: hash,
                rawTitle: rawTitle,
                normalizedTitle: rawTitle,
                sizeBytes: max(0, size),
                tracker: "TorBox Library",
                nzbURL: "",
                age: "",
                cached: cached,
                owned: true,
                ownedDownloadID: downloadID
            )
        }
    }

    private static func normalizedMatchText(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let mapped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(mapped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func normalizedMatchTokens(_ value: String) -> [String] {
        let ignored: Set<String> = ["the", "a", "an", "and", "of", "to", "in", "on"]
        return normalizedMatchText(value).split(separator: " ").map(String.init).filter { token in
            token.count >= 2 && !ignored.contains(token)
        }
    }

    private static func searchByID(
        identityType: String,
        identityID: String,
        item: MediaItem,
        apiKey: String,
        includeUserEngines: Bool,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        var components = URLComponents(string: "\(searchBase)/usenet/\(identityType):\(identityID)")!
        components.queryItems = commonSearchQueryItems(for: item, includeUserEngines: includeUserEngines)
        guard let url = components.url else {
            throw TorBoxUsenetError.invalidResponse("Could not build the TorBox Usenet ID search URL.")
        }
        return try await performSearch(url: url, apiKey: apiKey, session: session)
    }

    private static func searchByQuery(
        _ query: String,
        item: MediaItem,
        apiKey: String,
        includeUserEngines: Bool,
        session: URLSession
    ) async throws -> [TorBoxUsenetSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        // Current TorBox documentation defines full-text Usenet search at /usenet/search.
        // vBRDC060-vBRDC069 incorrectly appended the title as a path component. Try the
        // documented query-parameter shape first, then keep the old path shape only as a
        // compatibility fallback for any TorBox edge still serving it.
        var canonical = URLComponents(string: "\(searchBase)/usenet/search")!
        canonical.queryItems = [URLQueryItem(name: "query", value: clean)]
            + commonSearchQueryItems(for: item, includeUserEngines: includeUserEngines)
        guard let canonicalURL = canonical.url else {
            throw TorBoxUsenetError.invalidResponse("Could not build the TorBox Usenet query search URL.")
        }

        var firstError: Error?
        var canonicalSucceeded = false
        do {
            let results = try await performSearch(url: canonicalURL, apiKey: apiKey, session: session)
            canonicalSucceeded = true
            if !results.isEmpty { return results }
        } catch {
            try throwIfCancelled(error)
            firstError = error
        }

        let disallowed = CharacterSet(charactersIn: "/?#")
        let allowed = CharacterSet.urlPathAllowed.subtracting(disallowed)
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty,
              var legacy = URLComponents(string: "\(searchBase)/usenet/search/\(encoded)") else {
            if let firstError { throw firstError }
            return []
        }
        legacy.queryItems = commonSearchQueryItems(for: item, includeUserEngines: includeUserEngines)
        guard let legacyURL = legacy.url else {
            if let firstError { throw firstError }
            return []
        }
        do {
            return try await performSearch(url: legacyURL, apiKey: apiKey, session: session)
        } catch {
            try throwIfCancelled(error)
            // A documented canonical request that successfully returned zero remains a
            // legitimate zero even if the compatibility-only legacy route no longer exists.
            if canonicalSucceeded { return [] }
            if let firstError { throw firstError }
            throw error
        }
    }

    private static func commonSearchQueryItems(for item: MediaItem, includeUserEngines: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "metadata", value: "false"),
            URLQueryItem(name: "check_cache", value: "true"),
            URLQueryItem(name: "check_owned", value: "true"),
            URLQueryItem(name: "search_user_engines", value: includeUserEngines ? "true" : "false")
        ]
        if let season = item.seasonNumber, season >= 0 {
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        if let episode = item.episodeNumber, episode > 0 {
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        return items
    }

    private static func performSearch(url: URL, apiKey: String, session: URLSession) async throws -> [TorBoxUsenetSearchResult] {
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxUsenet", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await searchDataWithTransientRetry(request: request, session: session)
            try validate(response: response, data: data)
            return try parseSearchResponse(data)
        } catch {
            try throwIfCancelled(error)
            guard isDNSResolutionError(error) else {
                if error is TorBoxUsenetError { throw error }
                let host = request.url?.host ?? "TorBox Search"
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                throw TorBoxUsenetError.unavailable("\(host) connection failed: \(detail.isEmpty ? "Unknown network error" : detail)")
            }

            // Some ISP/router DNS filters resolve api.torbox.app but suppress the separate
            // Voyager hostname. Resolve only that TorBox hostname through public DoH and
            // keep HTTPS authentication end-to-end by connecting to the returned IP with
            // TLS SNI still set to search-api.torbox.app. No TorBox token is sent to DoH.
            let fallback = try await voyagerSearchViaDoH(url: url, apiKey: apiKey, session: session)
            guard (200...299).contains(fallback.statusCode) else {
                var detail = ""
                if let root = try? JSONSerialization.jsonObject(with: fallback.body) as? [String: Any] {
                    detail = string(root["detail"] ?? root["error"]) ?? ""
                }
                throw TorBoxUsenetError.http(fallback.statusCode, detail)
            }
            return try parseSearchResponse(fallback.body)
        }
    }

    private static func searchDataWithTransientRetry(
        request: URLRequest,
        session: URLSession,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await session.data(for: request)
            } catch {
                try throwIfCancelled(error)
                attempt += 1
                guard attempt < maxAttempts, isTransientNetworkError(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(350_000_000 * attempt))
            }
        }
    }

    private static func isDNSResolutionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && [URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue].contains(ns.code)
    }

    private struct RawVoyagerHTTPResponse {
        var statusCode: Int
        var body: Data
    }

    private static func voyagerSearchViaDoH(
        url: URL,
        apiKey: String,
        session: URLSession
    ) async throws -> RawVoyagerHTTPResponse {
        #if canImport(Network) && canImport(Security)
        let host = url.host ?? "search-api.torbox.app"
        guard host.caseInsensitiveCompare("search-api.torbox.app") == .orderedSame else {
            throw TorBoxUsenetError.unavailable("DNS fallback is restricted to TorBox Voyager.")
        }
        let addresses = try await resolveIPv4ViaDoH(host: host, session: session)
        guard !addresses.isEmpty else {
            throw TorBoxUsenetError.unavailable("TorBox Voyager could not be resolved through the device DNS or DNS-over-HTTPS.")
        }

        var lastError: Error?
        for address in addresses.prefix(4) {
            try Task.checkCancellation()
            do {
                return try await rawTLSGET(url: url, connectAddress: address, serverName: host, apiKey: apiKey)
            } catch {
                try throwIfCancelled(error)
                lastError = error
            }
        }
        let detail = lastError?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw TorBoxUsenetError.unavailable("TorBox Voyager DNS was recovered, but the secure connection failed: \(detail.isEmpty ? "Unknown TLS/network error" : detail)")
        #else
        throw TorBoxUsenetError.unavailable("TorBox Voyager could not be resolved by this device.")
        #endif
    }

    private static func resolveIPv4ViaDoH(host: String, session: URLSession) async throws -> [String] {
        // Use literal Cloudflare resolver IPs so this fallback does not depend on the same
        // local DNS path that failed for Voyager. The TorBox API key is never included.
        let resolvers = ["1.1.1.1", "1.0.0.1"]
        var lastError: Error?

        for resolver in resolvers {
            try Task.checkCancellation()
            do {
                var components = URLComponents(string: "https://\(resolver)/dns-query")!
                components.queryItems = [
                    URLQueryItem(name: "name", value: host),
                    URLQueryItem(name: "type", value: "A")
                ]
                guard let url = components.url else { continue }
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
                request.setValue("DebridChannels-tvOS/vBRDC075 DoH", forHTTPHeaderField: "User-Agent")
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { continue }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let status = integer(root["Status"]) ?? 0
                guard status == 0 else { continue }
                let answers = root["Answer"] as? [[String: Any]] ?? []
                let values = answers.compactMap { answer -> String? in
                    guard (integer(answer["type"]) ?? 0) == 1 else { return nil }
                    let value = string(answer["data"]) ?? ""
                    return isIPv4Address(value) ? value : nil
                }
                if !values.isEmpty {
                    var seen = Set<String>()
                    return values.filter { seen.insert($0).inserted }
                }
            } catch {
                try throwIfCancelled(error)
                lastError = error
            }
        }

        if let lastError { throw lastError }
        throw TorBoxUsenetError.unavailable("DNS-over-HTTPS returned no IPv4 address for TorBox Voyager.")
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), (0...255).contains(number) else { return false }
            return String(number) == part || (part.count > 1 && part.first == "0")
        }
    }

    #if canImport(Network) && canImport(Security)
    private final class RawTLSBox: @unchecked Sendable {
        let lock = NSLock()
        var completed = false
        var buffer = Data()
        var timeoutWork: DispatchWorkItem?
    }

    private static func rawTLSGET(
        url: URL,
        connectAddress: String,
        serverName: String,
        apiKey: String
    ) async throws -> RawVoyagerHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
            let tcp = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let port = NWEndpoint.Port(rawValue: 443)!
            let connection = NWConnection(host: NWEndpoint.Host(connectAddress), port: port, using: parameters)
            let queue = DispatchQueue(label: "app.debridchannels.torbox-voyager-doh")
            let box = RawTLSBox()

            func finish(_ result: Result<RawVoyagerHTTPResponse, Error>) {
                box.lock.lock()
                guard !box.completed else {
                    box.lock.unlock()
                    return
                }
                box.completed = true
                let timeoutWork = box.timeoutWork
                box.lock.unlock()
                timeoutWork?.cancel()
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        box.lock.lock()
                        box.buffer.append(data)
                        let snapshot = box.buffer
                        box.lock.unlock()
                        if let parsed = try? parseRawHTTPResponse(snapshot, requireCompleteBody: true) {
                            finish(.success(parsed))
                            return
                        }
                    }
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if isComplete {
                        box.lock.lock()
                        let finalData = box.buffer
                        box.lock.unlock()
                        do {
                            finish(.success(try parseRawHTTPResponse(finalData, requireCompleteBody: false)))
                        } catch {
                            finish(.failure(error))
                        }
                        return
                    }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    var target = components?.percentEncodedPath ?? url.path
                    if target.isEmpty { target = "/" }
                    if let query = components?.percentEncodedQuery, !query.isEmpty { target += "?\(query)" }
                    let request = "GET \(target) HTTP/1.1\r\n" +
                        "Host: \(serverName)\r\n" +
                        "Authorization: Bearer \(apiKey)\r\n" +
                        "Accept: application/json\r\n" +
                        "Accept-Encoding: identity\r\n" +
                        "User-Agent: DebridChannels-tvOS/vBRDC075 TorBoxUsenet\r\n" +
                        "Connection: close\r\n\r\n"
                    guard let bytes = request.data(using: .utf8) else {
                        finish(.failure(TorBoxUsenetError.invalidResponse("Could not encode the TorBox Voyager request.")))
                        return
                    }
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)); return }
                        receiveNext()
                    })
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            let timeoutWork = DispatchWorkItem {
                finish(.failure(TorBoxUsenetError.timedOut("TorBox Voyager secure DNS fallback timed out.")))
            }
            box.timeoutWork = timeoutWork
            queue.asyncAfter(deadline: .now() + 18, execute: timeoutWork)
            connection.start(queue: queue)
        }
    }

    private static func parseRawHTTPResponse(_ data: Data, requireCompleteBody: Bool) throws -> RawVoyagerHTTPResponse {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned an incomplete HTTP response.")
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned unreadable HTTP headers.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned no HTTP status.")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned an invalid HTTP status.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body = Data(data[bodyStart...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let decoded = try decodeChunkedBody(body, requireComplete: requireCompleteBody)
            return RawVoyagerHTTPResponse(statusCode: statusCode, body: decoded)
        }
        if let rawLength = headers["content-length"], let length = Int(rawLength) {
            if requireCompleteBody && body.count < length {
                throw TorBoxUsenetError.invalidResponse("TorBox Voyager response body is still arriving.")
            }
            guard body.count >= length else {
                throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned a truncated response.")
            }
            return RawVoyagerHTTPResponse(statusCode: statusCode, body: Data(body.prefix(length)))
        }
        if requireCompleteBody {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager response body is still arriving.")
        }
        return RawVoyagerHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunkedBody(_ data: Data, requireComplete: Bool) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)

        while index < data.endIndex {
            guard let lineRange = data[index...].range(of: crlf) else {
                throw TorBoxUsenetError.invalidResponse(requireComplete ? "TorBox Voyager chunk is still arriving." : "TorBox Voyager returned malformed chunked data.")
            }
            guard let sizeLine = String(data: data[index..<lineRange.lowerBound], encoding: .utf8) else {
                throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned an invalid chunk size.")
            }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned an invalid chunk size.")
            }
            index = lineRange.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else {
                throw TorBoxUsenetError.invalidResponse(requireComplete ? "TorBox Voyager chunk is still arriving." : "TorBox Voyager returned a truncated chunk.")
            }
            let end = data.index(index, offsetBy: size)
            output.append(data[index..<end])
            index = end
            guard data.distance(from: index, to: data.endIndex) >= 2,
                  data[index..<data.index(index, offsetBy: 2)].elementsEqual(crlf) else {
                throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned malformed chunk framing.")
            }
            index = data.index(index, offsetBy: 2)
        }

        throw TorBoxUsenetError.invalidResponse(requireComplete ? "TorBox Voyager chunked body is still arriving." : "TorBox Voyager returned an incomplete chunked body.")
    }
    #endif

    private static func parseSearchResponse(_ data: Data) throws -> [TorBoxUsenetSearchResult] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxUsenetError.invalidResponse("TorBox Voyager returned an unreadable Usenet response.")
        }
        if let success = bool(root["success"]), !success {
            let detail = string(root["detail"] ?? root["error"]) ?? "TorBox Usenet search is unavailable for this account."
            throw TorBoxUsenetError.unavailable(detail)
        }

        // TorBox's envelope is normally { success, data: { nzbs: [...] } }, while
        // some public SDK/test fixtures expose the search payload directly. Accept both.
        let payload = root["data"] ?? root
        let objects: [[String: Any]]
        if let dictionary = payload as? [String: Any] {
            if let list = dictionary["nzbs"] as? [[String: Any]] {
                objects = list
            } else if let list = dictionary["results"] as? [[String: Any]] {
                objects = list
            } else if let list = dictionary["items"] as? [[String: Any]] {
                objects = list
            } else if let list = dictionary["usenet"] as? [[String: Any]] {
                objects = list
            } else if dictionary["raw_title"] != nil || dictionary["title"] != nil || dictionary["name"] != nil {
                objects = [dictionary]
            } else {
                objects = []
            }
        } else if let list = payload as? [[String: Any]] {
            objects = list
        } else {
            objects = []
        }

        return objects.compactMap { entry in
            let rawTitle = string(entry["raw_title"] ?? entry["title"] ?? entry["name"]) ?? ""
            let normalizedTitle = string(entry["title"] ?? entry["name"] ?? entry["raw_title"]) ?? rawTitle
            let hash = string(entry["hash"]) ?? ""
            let nzbURL = string(entry["nzb"] ?? entry["nzb_link"] ?? entry["download_link"] ?? entry["link"]) ?? ""
            guard !rawTitle.isEmpty, !hash.isEmpty || !nzbURL.isEmpty else { return nil }

            var tracker = string(entry["tracker"] ?? entry["source"]) ?? ""
            if tracker.isEmpty, let indexer = entry["indexer"] as? [String: Any] {
                tracker = string(indexer["name"] ?? indexer["title"]) ?? ""
            }

            return TorBoxUsenetSearchResult(
                hash: hash,
                rawTitle: rawTitle,
                normalizedTitle: normalizedTitle,
                sizeBytes: max(0, integer64(entry["size"] ?? entry["bytes"]) ?? 0),
                tracker: tracker,
                nzbURL: nzbURL,
                age: string(entry["age"]) ?? "",
                cached: bool(entry["cached"] ?? entry["is_cached"]) ?? false,
                owned: bool(entry["owned"] ?? entry["is_owned"]) ?? false,
                ownedDownloadID: integer(entry["usenet_id"] ?? entry["usenet_download_id"] ?? entry["download_id"])
            )
        }
    }

    private static func deduplicated(_ results: [TorBoxUsenetSearchResult]) -> [TorBoxUsenetSearchResult] {
        var seen = Set<String>()
        return results.filter { result in
            let key: String
            if !result.directPlaybackURL.isEmpty { key = "direct:\(result.directPlaybackURL.lowercased())" }
            else if !result.hash.isEmpty { key = "hash:\(result.hash.lowercased())" }
            else if !result.nzbURL.isEmpty { key = "nzb:\(result.nzbURL.lowercased())" }
            else { key = "title:\(result.normalizedTitle.lowercased())" }
            return seen.insert(key).inserted
        }
    }

    private static func fullTextSearchQuery(for item: MediaItem) -> String {
        var parts = [item.title.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        if let season = item.seasonNumber, season >= 0 {
            if let episode = item.episodeNumber, episode > 0 {
                parts.append(String(format: "S%02dE%02d", season, episode))
            } else {
                parts.append(String(format: "S%02d", season))
            }
        } else {
            let year = item.year.trimmingCharacters(in: .whitespacesAndNewlines)
            if !year.isEmpty { parts.append(year) }
        }
        return parts.joined(separator: " ")
    }

    static func resolve(_ result: TorBoxUsenetSearchResult, apiKey: String, session: URLSession = .shared) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TorBoxUsenetError.missingAPIKey }

        if !result.directPlaybackURL.isEmpty,
           let direct = URL(string: result.directPlaybackURL),
           ["http", "https"].contains(direct.scheme?.lowercased() ?? "") {
            return direct
        }

        // vBRDC060: Main-API library fallback carries the authoritative TorBox download ID.
        // Use it directly so a matching owned Usenet item remains streamable even when the
        // restricted Voyager Search API cannot be reached from the Apple TV or relay.
        if let ownedID = result.ownedDownloadID, ownedID > 0 {
            let existing = try await getDownload(id: ownedID, apiKey: key, session: session)
            if let playable = try await playableURLIfReady(download: existing, apiKey: key, session: session) {
                return playable
            }
            return try await waitForPlayableDownload(
                id: ownedID,
                timeout: result.cached ? 120 : 600,
                apiKey: key,
                session: session
            )
        }

        // If Voyager says the item is already owned, reuse the existing TorBox job rather
        // than creating a duplicate. It may still be downloading/unpacking, so wait on that
        // job instead of falling through to a second create request.
        if result.owned, !result.hash.isEmpty,
           let existing = try? await existingDownload(hash: result.hash, apiKey: key, session: session) {
            if let playable = try await playableURLIfReady(download: existing, apiKey: key, session: session) {
                return playable
            }
            if let existingID = integer(existing["id"]), existingID > 0 {
                return try await waitForPlayableDownload(
                    id: existingID,
                    timeout: result.cached ? 120 : 600,
                    apiKey: key,
                    session: session
                )
            }
        }

        guard !result.nzbURL.isEmpty else {
            throw TorBoxUsenetError.unavailable("TorBox found this Usenet release but did not expose an NZB handoff URL.")
        }

        let downloadID = try await createDownload(result: result, apiKey: key, session: session)
        return try await waitForPlayableDownload(
            id: downloadID,
            timeout: result.cached ? 120 : 600,
            apiKey: key,
            session: session
        )
    }

    static func qualityLabel(for title: String) -> String {
        let h = title.lowercased()
        var parts: [String] = []
        if h.contains("2160") || h.contains("4k") { parts.append("4K") }
        else if h.contains("1440") { parts.append("1440p") }
        else if h.contains("1080") { parts.append("1080p") }
        else if h.contains("720") { parts.append("720p") }
        else { parts.append("Usenet") }
        if h.contains("remux") { parts.append("REMUX") }
        else if h.contains("web-dl") || h.contains("webdl") { parts.append("WEB-DL") }
        else if h.contains("bluray") || h.contains("blu-ray") { parts.append("BluRay") }
        if h.contains("dolby vision") || h.contains("dovi") || h.contains(".dv.") { parts.append("DV") }
        if h.contains("hdr10+") || h.contains("hdr10plus") { parts.append("HDR10+") }
        else if h.contains("hdr") { parts.append("HDR") }
        return parts.joined(separator: " • ")
    }

    static func sizeLabel(bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Main API

    private static func createDownload(result: TorBoxUsenetSearchResult, apiKey: String, session: URLSession) async throws -> Int {
        var linkFailure: Error?
        do {
            return try await createDownloadFromLink(result: result, apiKey: apiKey, session: session)
        } catch {
            try throwIfCancelled(error)
            linkFailure = error
        }

        // vBRDC070: Newznab `t=get` links are not guaranteed to satisfy TorBox Main API's
        // "accessible link / no redirect" requirement. If link creation fails, fetch the
        // authenticated NZB in-memory and submit it through the API's supported file field.
        // The NZB is never persisted to disk.
        do {
            let nzb = try await fetchNZBForUpload(result: result, apiKey: apiKey, session: session)
            return try await createDownloadFromNZBData(nzb, title: result.rawTitle, apiKey: apiKey, session: session)
        } catch {
            try throwIfCancelled(error)
            let first = linkFailure?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? "link handoff failed"
            let second = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TorBoxUsenetError.unavailable("TorBox could not accept this Newznab release by link or NZB upload. link: \(first); upload: \(second.isEmpty ? "failed" : second)")
        }
    }

    private static func createDownloadFromLink(result: TorBoxUsenetSearchResult, apiKey: String, session: URLSession) async throws -> Int {
        let boundary = "DebridChannels-\(UUID().uuidString)"
        var body = Data()
        appendMultipartText(name: "link", value: result.nzbURL, boundary: boundary, to: &body)
        if !result.rawTitle.isEmpty {
            appendMultipartText(name: "name", value: String(result.rawTitle.prefix(180)), boundary: boundary, to: &body)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return try await performCreateDownload(body: body, boundary: boundary, apiKey: apiKey, session: session)
    }

    private static func fetchNZBForUpload(result: TorBoxUsenetSearchResult, apiKey: String, session: URLSession) async throws -> Data {
        guard var components = URLComponents(string: result.nzbURL),
              components.scheme?.lowercased() == "https", components.host != nil else {
            throw TorBoxUsenetError.unavailable("The Newznab result did not provide a secure NZB URL for upload fallback.")
        }
        if components.host?.lowercased() == "search-api.torbox.app" {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name.caseInsensitiveCompare("apikey") == .orderedSame }) {
                items.append(URLQueryItem(name: "apikey", value: apiKey))
                components.queryItems = items
            }
        }
        guard let url = components.url else {
            throw TorBoxUsenetError.invalidResponse("Could not build the authenticated Newznab download URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-nzb, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("DebridChannels-tvOS/vBRDC075 NZBFetch", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TorBoxUsenetError.http(code, "Newznab NZB download failed.")
        }
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else {
            throw TorBoxUsenetError.invalidResponse("Newznab returned an empty or unexpectedly large NZB file.")
        }
        let prefix = String(data: data.prefix(256), encoding: .utf8)?.lowercased() ?? ""
        guard prefix.contains("<?xml") || prefix.contains("<nzb") else {
            throw TorBoxUsenetError.invalidResponse("Newznab did not return an NZB document.")
        }
        return data
    }

    private static func createDownloadFromNZBData(_ nzb: Data, title: String, apiKey: String, session: URLSession) async throws -> Int {
        let boundary = "DebridChannels-\(UUID().uuidString)"
        var body = Data()
        if !title.isEmpty {
            appendMultipartText(name: "name", value: String(title.prefix(180)), boundary: boundary, to: &body)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"debridchannels.nzb\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-nzb\r\n\r\n".data(using: .utf8)!)
        body.append(nzb)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return try await performCreateDownload(body: body, boundary: boundary, apiKey: apiKey, session: session)
    }

    private static func appendMultipartText(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
    }

    private static func performCreateDownload(body: Data, boundary: String, apiKey: String, session: URLSession) async throws -> Int {
        guard let url = URL(string: "\(apiBase)/createusenetdownload") else {
            throw TorBoxUsenetError.invalidResponse("TorBox Usenet create URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/vBRDC075 TorBoxUsenet", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxUsenetError.invalidResponse("TorBox did not return a Usenet download ID.")
        }
        if let success = root["success"] as? Bool, !success {
            throw TorBoxUsenetError.unavailable(string(root["detail"] ?? root["error"]) ?? "TorBox could not create the Usenet download.")
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let id = integer(payload["usenetdownload_id"] ?? payload["usenet_download_id"] ?? payload["id"]), id > 0 else {
            throw TorBoxUsenetError.invalidResponse("TorBox accepted the NZB but did not return a usable download ID.")
        }
        return id
    }

    private static func existingDownload(hash: String, apiKey: String, session: URLSession) async throws -> [String: Any]? {
        guard let url = URL(string: "\(apiBase)/mylist?limit=1000") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items: [[String: Any]]
        if let list = root["data"] as? [[String: Any]] { items = list }
        else if let one = root["data"] as? [String: Any] { items = [one] }
        else { items = [] }
        return items.first { string($0["hash"])?.caseInsensitiveCompare(hash) == .orderedSame }
    }

    private static func getDownload(id: Int, apiKey: String, session: URLSession) async throws -> [String: Any] {
        var components = URLComponents(string: "\(apiBase)/mylist")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "bypass_cache", value: "true")
        ]
        guard let url = components.url else { throw TorBoxUsenetError.invalidResponse("TorBox Usenet status URL is invalid.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxUsenetError.invalidResponse("TorBox returned an unreadable Usenet status response.")
        }
        if let object = root["data"] as? [String: Any] { return object }
        if let list = root["data"] as? [[String: Any]], let first = list.first { return first }
        throw TorBoxUsenetError.invalidResponse("TorBox did not return the selected Usenet download.")
    }

    private static func waitForPlayableDownload(id: Int, timeout: TimeInterval, apiKey: String, session: URLSession) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var lastState = "preparing"
        while Date() < deadline {
            try Task.checkCancellation()
            let download = try await getDownload(id: id, apiKey: apiKey, session: session)
            lastState = string(download["download_state"]) ?? lastState
            if let playable = try await playableURLIfReady(download: download, apiKey: apiKey, session: session) {
                return playable
            }
            if isFailureState(lastState) {
                throw TorBoxUsenetError.unavailable("TorBox could not prepare this Usenet source (\(lastState)).")
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        throw TorBoxUsenetError.timedOut("TorBox is still preparing this Usenet source (\(lastState)). Try it again after the download finishes in TorBox.")
    }

    private static func playableURLIfReady(download: [String: Any], apiKey: String, session: URLSession) async throws -> URL? {
        let finished = bool(download["download_finished"]) ?? false
        let present = bool(download["download_present"]) ?? false
        let cached = bool(download["cached"]) ?? false
        guard (finished && present) || (cached && present) else { return nil }
        guard let usenetID = integer(download["id"]), usenetID > 0 else { return nil }
        guard let file = preferredVideoFile(from: download), let fileID = integer(file["id"]), fileID >= 0 else { return nil }
        return try await requestDownloadURL(usenetID: usenetID, fileID: fileID, apiKey: apiKey, session: session)
    }

    private static func requestDownloadURL(usenetID: Int, fileID: Int, apiKey: String, session: URLSession) async throws -> URL {
        var components = URLComponents(string: "\(apiBase)/requestdl")!
        var queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "usenet_id", value: String(usenetID)),
            URLQueryItem(name: "zip_link", value: "false")
        ]
        if fileID != 0 {
            queryItems.append(URLQueryItem(name: "file_id", value: String(fileID)))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw TorBoxUsenetError.invalidResponse("TorBox Usenet playback URL is invalid.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithTransientRetry(request: request, session: session)
        try validate(response: response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxUsenetError.invalidResponse("TorBox did not return a stream URL.")
        }
        let raw = string(root["data"]) ?? ((root["data"] as? [String: Any]).flatMap { string($0["link"] ?? $0["url"]) })
        guard let raw, let playable = URL(string: raw), ["http", "https"].contains(playable.scheme?.lowercased() ?? "") else {
            throw TorBoxUsenetError.invalidResponse("TorBox prepared the Usenet download but did not return a playable CDN URL.")
        }
        return playable
    }

    private static func preferredVideoFile(from download: [String: Any]) -> [String: Any]? {
        guard let files = download["files"] as? [[String: Any]], !files.isEmpty else { return nil }
        let videoExtensions = ["mkv", "mp4", "m4v", "mov", "m2ts", "ts", "webm", "avi"]
        let archiveExtensions = ["rar", "zip", "7z", "par2", "nzb", "nfo", "sfv"]
        let candidates = files.filter { file in
            let name = (string(file["name"] ?? file["short_name"]) ?? "").lowercased()
            let ext = name.split(separator: ".").last.map(String.init) ?? ""
            let mime = (string(file["mimetype"]) ?? "").lowercased()
            let sample = name.contains("sample") || name.contains("trailer") || name.contains("proof")
            return !sample && (videoExtensions.contains(ext) || mime.hasPrefix("video/"))
        }
        if let best = candidates.max(by: { (integer64($0["size"]) ?? 0) < (integer64($1["size"]) ?? 0) }) { return best }
        return files
            .filter { file in
                let name = (string(file["name"] ?? file["short_name"]) ?? "").lowercased()
                let ext = name.split(separator: ".").last.map(String.init) ?? ""
                return !archiveExtensions.contains(ext)
            }
            .max(by: { (integer64($0["size"]) ?? 0) < (integer64($1["size"]) ?? 0) })
    }

    private static func isFailureState(_ value: String) -> Bool {
        let h = value.lowercased()
        return ["failed", "error", "dead", "missing", "invalid", "cancelled", "canceled", "repair_failed", "unpack_failed"].contains { h.contains($0) }
    }

    private static func searchIdentities(for item: MediaItem) -> [(type: String, id: String)] {
        // vBRDC075: do not stop at the first catalog identity. A title can legitimately have
        // IMDb + TMDB + TVDB metadata while one TorBox metadata edge is stale or incomplete.
        // Try every authoritative identity available on the MediaItem, with the current
        // external-ID spelling first and TorBox's historical aliases immediately after it.
        var identities: [(type: String, id: String)] = []
        let imdb = (item.imdbId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if imdb.lowercased().hasPrefix("tt"), imdb.count >= 9 {
            identities.append(("imdb_id", imdb))
            identities.append(("imdb", imdb))
        }
        let tmdb = (item.tmdbId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tmdb.isEmpty {
            identities.append(("themoviedb_id", tmdb))
            identities.append(("tmdb_id", tmdb))
            identities.append(("tmdb", tmdb))
        }
        let tvdb = (item.tvdbId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tvdb.isEmpty {
            identities.append(("thetvdb_id", tvdb))
            identities.append(("tvdb_id", tvdb))
            identities.append(("tvdb", tvdb))
        }
        return identities
    }

    private static func searchIdentity(for item: MediaItem) -> (type: String, id: String)? {
        searchIdentities(for: item).first
    }

    private static func legacySearchIdentity(for item: MediaItem) -> (type: String, id: String)? {
        searchIdentities(for: item).first { identity in
            identity.type == "imdb" || identity.type == "tmdb" || identity.type == "tvdb"
        }
    }

    private static func dataWithTransientRetry(request: URLRequest, session: URLSession, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await session.data(for: request)
            } catch {
                try throwIfCancelled(error)
                attempt += 1
                guard attempt < maxAttempts, isTransientNetworkError(error) else {
                    let host = request.url?.host ?? "TorBox endpoint"
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw TorBoxUsenetError.unavailable("\(host) connection failed: \(detail.isEmpty ? "Unknown network error" : detail)")
                }
                let delay = UInt64(350_000_000 * attempt)
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let code: Int
        if let urlError = error as? URLError {
            code = urlError.errorCode
        } else {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return false }
            code = ns.code
        }
        let transientCodes: Set<Int> = [
            URLError.cannotFindHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.notConnectedToInternet.rawValue,
            URLError.timedOut.rawValue
        ]
        return transientCodes.contains(code)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            var detail = ""
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                detail = string(root["detail"] ?? root["error"]) ?? ""
            }
            throw TorBoxUsenetError.http(http.statusCode, detail)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func integer64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
