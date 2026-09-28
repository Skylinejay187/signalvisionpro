import Foundation

/// Architecture migration step 7.
///
/// Keeps Source Intelligence ranking/provider logic in one place so CatalogStore can
/// keep owning network state, playback handoff, and published UI state.
enum SourceIntelligenceManager {
    static func configuredMaximumLinks() -> Int {
        // v984: the Settings screen exposes exactly two supported limits. Treat every
        // legacy, missing, or invalid value as the recommended 25-link mode so the
        // resolver and picker cannot silently fall back to an uncapped 300-link scan.
        let raw = UserDefaults.standard.integer(forKey: "sourceIntelligenceMaximumLinks")
        return raw == 50 ? 50 : 25
    }

    private enum EpisodeTokenState {
        case exactEpisode
        case matchingSeasonPack
        case wrongEpisodeOrSeason
        case generic
    }

    static func prioritizedEnglishStreams(_ streams: [StremioStream]) -> [StremioStream] {
        streams.enumerated().sorted { lhs, rhs in
            let l = englishPriority(lhs.element)
            let r = englishPriority(rhs.element)
            if l.englishRank != r.englishRank { return l.englishRank < r.englishRank }
            if l.foreignRank != r.foreignRank { return l.foreignRank < r.foreignRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func providerCanonical(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    static func isKnownProvider(_ value: String) -> Bool {
        let canonical = providerCanonical(value)
        return ["mediafusion", "torrentio", "comet", "debrido", "debridio", "torbox", "realdebrid", "alldebrid", "premiumize", "debridlink", "easydebrid", "offcloud", "putio", "debrider"].contains { canonical.contains($0) }
    }

    static func providerMatches(selection: String, provider: String, manifestURL: String) -> Bool {
        let cleanSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSelection.isEmpty, cleanSelection != "All Providers" else { return true }
        let providerKey = providerCanonical(provider + " " + manifestURL)
        if cleanSelection == "Other detected providers" { return !isKnownProvider(providerKey) }
        return providerKey.contains(providerCanonical(cleanSelection))
    }

    /// Returns the debrid service carried by a configured manifest or individual stream.
    /// Several addons (Torrentio, Comet, Debrido, MediaFusion) can expose the same addon
    /// name for different accounts, so the addon name alone is not a stable provider key.
    static func debridServiceLabel(manifestURL: String, sourceName: String, stream: StremioStream? = nil) -> String? {
        let streamText = [stream?.title, stream?.name, stream?.behaviorHints?.filename, stream?.url, stream?.externalUrl]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if let streamService = uniqueDebridService(in: streamText) {
            return streamService
        }

        let decodedConfig = decodedBase64URLConfigurationText(from: manifestURL) ?? ""
        let manifestText = [sourceName, manifestURL, decodedConfig].joined(separator: " ").lowercased()
        return uniqueDebridService(in: manifestText)
    }

    private static func uniqueDebridService(in haystack: String) -> String? {
        guard !haystack.isEmpty else { return nil }
        let serviceMarkers: [(label: String, markers: [String])] = [
            ("TorBox", ["torbox=", "\"service\":\"torbox\"", "\"service\": \"torbox\"", "\"provider\":\"torbox\"", "\"provider\": \"torbox\"", " torbox", "[tb+]", " tb+", "[tb "]),
            ("Real-Debrid", ["realdebrid=", "real-debrid", "real debrid", "\"service\":\"realdebrid\"", "\"service\": \"realdebrid\"", "\"provider\":\"realdebrid\"", "\"provider\": \"realdebrid\"", "[rd+]", " rd+", "[rd "]),
            ("AllDebrid", ["alldebrid=", "all-debrid", "all debrid", "\"service\":\"alldebrid\"", "\"provider\":\"alldebrid\"", "[ad+]", " ad+"]),
            ("Premiumize", ["premiumize=", "\"service\":\"premiumize\"", "\"provider\":\"premiumize\"", " premiumize", "[pm+]", " pm+"]),
            ("Debrid-Link", ["debridlink=", "debrid-link", "\"service\":\"debridlink\"", "\"provider\":\"debridlink\""]),
            ("EasyDebrid", ["easydebrid=", "easy-debrid", "\"service\":\"easydebrid\"", "\"provider\":\"easydebrid\""]),
            ("Offcloud", ["offcloud=", "off-cloud", "\"service\":\"offcloud\"", "\"provider\":\"offcloud\"", " offcloud"]),
            ("Put.io", ["putio=", "put.io", "\"service\":\"putio\"", "\"provider\":\"putio\""]),
            ("Debrider", ["debrider=", "\"service\":\"debrider\"", "\"provider\":\"debrider\""])
        ]
        let matches = serviceMarkers.compactMap { entry in
            entry.markers.contains { haystack.contains($0) } ? entry.label : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func providerDisplayName(sourceName: String, manifestURL: String, stream: StremioStream? = nil) -> String {
        let cleanSource = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleanSource.isEmpty ? "Unknown Provider" : cleanSource
        guard let service = debridServiceLabel(manifestURL: manifestURL, sourceName: base, stream: stream) else { return base }
        guard !providerCanonical(base).contains(providerCanonical(service)) else { return base }
        return "\(base) • \(service)"
    }

    private static func decodedBase64URLConfigurationText(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL) else { return nil }
        let components = url.path.split(separator: "/").map(String.init)
        guard let manifestIndex = components.lastIndex(where: { $0.lowercased() == "manifest.json" }), manifestIndex > 0 else { return nil }

        // Configured Stremio addons can use standard Base64(JSON), including '=' padding
        // and literal '/' characters. Preserve those paths so manually added configured
        // addons keep accurate provider/service labels without any managed adapter.
        // First preserve the complete encoded path before manifest.json (including any
        // Base64 '/' characters), then try progressively wider component tails for other
        // configured-addon URL shapes.
        var candidates: [String] = []
        if let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
           let range = path.range(of: "/manifest.json", options: [.backwards, .caseInsensitive]) {
            let prefix = String(path[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !prefix.isEmpty { candidates.append(prefix) }
        }
        let prior = Array(components[..<manifestIndex])
        if !prior.isEmpty {
            for start in stride(from: prior.count - 1, through: 0, by: -1) {
                let candidate = prior[start...].joined(separator: "/")
                if !candidates.contains(candidate) { candidates.append(candidate) }
            }
        }

        for rawCandidate in candidates {
            let candidate = rawCandidate.removingPercentEncoding ?? rawCandidate
            // Ordinary Torrentio-style key=value|... paths will simply fail Base64/JSON.
            var base64 = candidate.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let remainder = base64.count % 4
            if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
            guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
                  let text = String(data: data, encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" else { continue }
            return text
        }
        return nil
    }

    static func balancedProviderLinks(_ rankedLinks: [StreamLink], limit: Int) -> [StreamLink] {
        guard limit > 0, rankedLinks.count > 1 else { return Array(rankedLinks.prefix(max(limit, 0))) }
        var providerOrder: [String] = []
        var grouped: [String: [StreamLink]] = [:]
        for link in rankedLinks {
            let rawProvider = link.providerDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = providerCanonical(rawProvider.isEmpty ? link.source : rawProvider)
            if grouped[key] == nil {
                providerOrder.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(link)
        }
        guard providerOrder.count > 1 else { return Array(rankedLinks.prefix(limit)) }
        var result: [StreamLink] = []
        var offsets: [String: Int] = Dictionary(uniqueKeysWithValues: providerOrder.map { ($0, 0) })
        while result.count < limit {
            var appendedThisPass = false
            for provider in providerOrder {
                guard result.count < limit else { break }
                let offset = offsets[provider] ?? 0
                let links = grouped[provider] ?? []
                guard links.indices.contains(offset) else { continue }
                result.append(links[offset])
                offsets[provider] = offset + 1
                appendedThisPass = true
            }
            if !appendedThisPass { break }
        }
        return result
    }

    static func sortedLinks(_ links: [StreamLink], for item: MediaItem? = nil) -> [StreamLink] {
        links.sorted { lhs, rhs in
            let lEpisodeRank = episodeRank(lhs, item: item)
            let rEpisodeRank = episodeRank(rhs, item: item)
            if lEpisodeRank.season != rEpisodeRank.season { return lEpisodeRank.season < rEpisodeRank.season }
            if lEpisodeRank.episode != rEpisodeRank.episode { return lEpisodeRank.episode < rEpisodeRank.episode }
            if lEpisodeRank.pack != rEpisodeRank.pack { return lEpisodeRank.pack < rEpisodeRank.pack }
            if lEpisodeRank.title != rEpisodeRank.title { return lEpisodeRank.title < rEpisodeRank.title }

            let lRank = (
                lhs.sourceIntelligenceIsCached ? 0 : 1,
                lhs.sourceIntelligenceLanguageRank,
                lhs.sourceIntelligenceResolutionRank,
                lhs.sourceIntelligenceSizeGB,
                lhs.sourceIntelligenceReliabilityRank,
                lhs.title.lowercased()
            )
            let rRank = (
                rhs.sourceIntelligenceIsCached ? 0 : 1,
                rhs.sourceIntelligenceLanguageRank,
                rhs.sourceIntelligenceResolutionRank,
                rhs.sourceIntelligenceSizeGB,
                rhs.sourceIntelligenceReliabilityRank,
                rhs.title.lowercased()
            )
            if lRank.0 != rRank.0 { return lRank.0 < rRank.0 }
            if lRank.1 != rRank.1 { return lRank.1 < rRank.1 }
            if lRank.2 != rRank.2 { return lRank.2 < rRank.2 }
            if lRank.3 != rRank.3 { return lRank.3 < rRank.3 }
            if lRank.4 != rRank.4 { return lRank.4 < rRank.4 }
            return lRank.5 < rRank.5
        }
    }

    private static func englishPriority(_ stream: StremioStream) -> (englishRank: Int, foreignRank: Int) {
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

    private static func episodeRank(_ link: StreamLink, item: MediaItem?) -> (title: Int, season: Int, episode: Int, pack: Int) {
        guard let item, let season = item.seasonNumber, let episode = item.episodeNumber else {
            return (0, 0, 0, 0)
        }
        let haystack = link.sourceIntelligenceHaystack
        let titleRank = titleMatches(linkTitle: haystack, itemTitle: item.title) ? 0 : 1
        let token = episodeTokenState(haystack, season: season, episode: episode)
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

    private static func titleMatches(linkTitle: String, itemTitle: String) -> Bool {
        let needle = canonicalTitle(itemTitle)
        guard needle.count >= 3 else { return true }
        let haystack = canonicalTitle(linkTitle)
        return haystack.contains(needle)
    }

    private static func canonicalTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\bs\d{1,2}[ ._-]*e\d{1,3}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{1,2}x\d{1,3}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func episodeTokenState(_ raw: String, season: Int, episode: Int) -> EpisodeTokenState {
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
}
