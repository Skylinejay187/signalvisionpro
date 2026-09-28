import Foundation

struct SignalTrailerPlaybackSource: Sendable {
    let videoURL: URL
    let audioURL: URL?
    let requestHeaders: [String: String]
    let qualityLabel: String
    let diagnostics: String
}

/// App-native trailer resolution modeled on NuvioTVOS's public tvOS resolver architecture:
/// Trailerio direct CDN first, then YouTube Innertube player responses from native clients,
/// with HD HLS/progressive preferred and split adaptive video+audio as the final HD path.
/// No cookie, Docker, yt-dlp, or per-user proxy is required for this lane.
actor SignalYouTubeTrailerResolver {
    static let shared = SignalYouTubeTrailerResolver()

    private struct TrailerioResponse: Decodable {
        struct Meta: Decodable {
            struct Link: Decodable { let trailers: String?; let provider: String? }
            let links: [Link]?
        }
        let meta: Meta?
    }

    private struct Client {
        let key: String
        let id: String
        let version: String
        let userAgent: String
        let context: [String: Any]
        let priority: Int
    }

    private struct StreamCandidate {
        let clientKey: String
        let url: URL
        let height: Int
        let score: Double
        let ext: String
        let priority: Int
    }

    private struct HLSCandidate {
        let clientKey: String
        let manifestURL: URL
        let height: Int
        let bandwidth: Int
        let priority: Int
    }

    // This is the same public fallback Innertube key used by NuvioTVOS's current tvOS resolver.
    // It is a YouTube client key, not a user's account credential.
    private static let fallbackAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private static let maxHeight = 1080
    private static let defaultUserAgent = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let clients: [Client] = [
        Client(
            key: "ios", id: "5", version: "20.10.1",
            userAgent: "com.google.ios.youtube/20.10.1 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
            context: ["clientName":"IOS", "clientVersion":"20.10.1", "deviceModel":"iPhone16,2", "osName":"iPhone", "osVersion":"17.4.0.21E219", "platform":"MOBILE", "hl":"en", "gl":"US"],
            priority: 0
        ),
        Client(
            key: "android", id: "3", version: "20.10.35",
            userAgent: "com.google.android.youtube/20.10.35 (Linux; U; Android 14; en_US) gzip",
            context: ["clientName":"ANDROID", "clientVersion":"20.10.35", "osName":"Android", "osVersion":"14", "platform":"MOBILE", "androidSdkVersion":34, "hl":"en", "gl":"US"],
            priority: 1
        ),
        Client(
            key: "android_vr", id: "28", version: "1.56.21",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1) gzip",
            context: ["clientName":"ANDROID_VR", "clientVersion":"1.56.21", "deviceMake":"Oculus", "deviceModel":"Quest 3", "osName":"Android", "osVersion":"12", "platform":"MOBILE", "androidSdkVersion":32, "hl":"en", "gl":"US"],
            priority: 2
        )
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 14
        config.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: config)
    }()

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 2.5
        return URLSession(configuration: config)
    }()

    private var cache: [String: (SignalTrailerPlaybackSource, Date)] = [:]
    private var trailerioCache: [String: SignalTrailerPlaybackSource] = [:]

    func resolve(for item: MediaItem) async -> SignalTrailerPlaybackSource? {
        let cacheKey = "\(item.id)|\(item.previewURL ?? "")"
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.1) < 1800 { return cached.0 }

        // Nuvio path 1: direct Trailerio CDN source when IMDb identity exists.
        if let imdb = canonicalIMDb(item.imdbId ?? item.id),
           let source = await resolveTrailerio(imdbID: imdb, isSeries: item.type.lowercased().contains("series") || item.type.lowercased().contains("show") || item.type.lowercased().contains("tv")) {
            cache[cacheKey] = (source, Date())
            return source
        }

        // Nuvio path 2: exact YouTube identity from catalog metadata, then native Innertube.
        guard let videoID = youtubeVideoID(from: item.previewURL) else { return nil }
        if let source = await resolveInnertube(videoID: videoID) {
            cache[cacheKey] = (source, Date())
            return source
        }
        return nil
    }

    private func resolveTrailerio(imdbID: String, isSeries: Bool) async -> SignalTrailerPlaybackSource? {
        if let cached = trailerioCache[imdbID] { return cached }
        let mediaType = isSeries ? "series" : "movie"
        guard let url = URL(string: "https://trailerio.cc/meta/\(mediaType)/\(imdbID).json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Signal-tvOS/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TrailerioResponse.self, from: data),
              let links = decoded.meta?.links else { return nil }

        let candidates = links.compactMap { link -> (URL, String, Int)? in
            guard let raw = link.trailers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let provider = link.provider ?? "Trailerio"
            return (url, provider, trailerioScore(provider: provider, url: raw))
        }.sorted { $0.2 > $1.2 }

        for (url, provider, _) in candidates.prefix(6) where await reachable(url: url, headers: [:]) {
            let source = SignalTrailerPlaybackSource(videoURL: url, audioURL: nil, requestHeaders: [:], qualityLabel: provider, diagnostics: "TRAILER: \(provider) [Trailerio]")
            trailerioCache[imdbID] = source
            return source
        }
        return nil
    }

    private func trailerioScore(provider: String, url: String) -> Int {
        let p = provider.lowercased(); let u = url.lowercased(); var score = 0
        if p.contains("apple tv") { score += 1000 }
        else if p.contains("rotten tomatoes") || p.contains("fandango") { score += 800 }
        else if p.contains("plex") { score += 700 }
        else if p.contains("mubi") { score += 500 }
        else if p.contains("imdb") { score += 300 }
        if p.contains("1080") { score += 300 } else if p.contains("720") { score += 200 }
        if p.contains("4k") || p.contains("2160") { score -= 100 } // Signal intentionally caps at 1080p.
        if u.contains(".m3u8") || u.contains(".mp4") { score += 100 }
        return score
    }

    private func resolveInnertube(videoID: String) async -> SignalTrailerPlaybackSource? {
        var hls: [HLSCandidate] = []
        var progressive: [StreamCandidate] = []
        var adaptiveVideo: [StreamCandidate] = []
        var adaptiveAudio: [StreamCandidate] = []

        for client in Self.clients {
            guard !Task.isCancelled,
                  let json = try? await playerResponse(videoID: videoID, client: client),
                  ((json["playabilityStatus"] as? [String: Any])?["status"] as? String) == "OK",
                  let streaming = json["streamingData"] as? [String: Any] else { continue }

            if let rawManifest = streaming["hlsManifestUrl"] as? String,
               let manifest = URL(string: rawManifest),
               let candidate = try? await hlsCandidate(manifest: manifest, client: client) {
                hls.append(candidate)
            }

            for format in (streaming["formats"] as? [[String: Any]]) ?? [] {
                guard let raw = format["url"] as? String, let url = URL(string: raw) else { continue }
                let mime = format["mimeType"] as? String ?? ""
                guard mime.contains("video/") else { continue }
                let height = numericInt(format["height"]) ?? qualityHeight(format["qualityLabel"] as? String) ?? 0
                guard height > 0, height <= Self.maxHeight else { continue }
                progressive.append(StreamCandidate(clientKey: client.key, url: url, height: height, score: videoScore(height: height, fps: numericInt(format["fps"]) ?? 0, bitrate: numericDouble(format["bitrate"]) ?? 0), ext: mime.contains("webm") ? "webm" : "mp4", priority: client.priority))
            }

            for format in (streaming["adaptiveFormats"] as? [[String: Any]]) ?? [] {
                guard let raw = format["url"] as? String, let url = URL(string: raw) else { continue }
                let mime = format["mimeType"] as? String ?? ""
                if mime.contains("video/") {
                    let height = numericInt(format["height"]) ?? qualityHeight(format["qualityLabel"] as? String) ?? 0
                    guard height > 0, height <= Self.maxHeight else { continue }
                    adaptiveVideo.append(StreamCandidate(clientKey: client.key, url: url, height: height, score: videoScore(height: height, fps: numericInt(format["fps"]) ?? 0, bitrate: numericDouble(format["bitrate"]) ?? 0), ext: mime.contains("webm") ? "webm" : "mp4", priority: client.priority))
                } else if mime.contains("audio/") {
                    adaptiveAudio.append(StreamCandidate(clientKey: client.key, url: url, height: 0, score: numericDouble(format["bitrate"]) ?? 0, ext: mime.contains("webm") ? "webm" : "m4a", priority: client.priority))
                }
            }
        }

        hls.sort { ($0.height, $0.bandwidth, -$0.priority) > ($1.height, $1.bandwidth, -$1.priority) }
        progressive.sort(by: streamSort)
        adaptiveVideo.sort(by: streamSort)
        adaptiveAudio.sort(by: streamSort)

        // Nuvio priority: HD HLS first.
        if let candidate = hls.first(where: { $0.height >= 720 && $0.height <= Self.maxHeight }) {
            return SignalTrailerPlaybackSource(videoURL: candidate.manifestURL, audioURL: nil, requestHeaders: headers(for: candidate.clientKey), qualityLabel: "\(candidate.height)p (HLS)", diagnostics: "TRAILER: \(candidate.height)p (HLS) [\(candidate.clientKey)]")
        }
        // Then HD progressive MP4.
        for candidate in progressive where candidate.height >= 720 {
            let headers = headers(for: candidate.clientKey)
            if await reachable(url: candidate.url, headers: headers) {
                return SignalTrailerPlaybackSource(videoURL: candidate.url, audioURL: nil, requestHeaders: headers, qualityLabel: "\(candidate.height)p (MP4)", diagnostics: "TRAILER: \(candidate.height)p (MP4) [\(candidate.clientKey)]")
            }
        }
        // vBRDC293: prefer a reachable muxed fallback before split adaptive A/V. The
        // Trailer button still gets HD HLS / HD progressive first, but automatic playback
        // no longer falls into KSPlayer simply because only adaptive 1080p was available.
        // A muxed 360/480/720 stream is substantially safer than a black trailer surface.
        for candidate in progressive {
            let h = headers(for: candidate.clientKey)
            if await reachable(url: candidate.url, headers: h) {
                return SignalTrailerPlaybackSource(videoURL: candidate.url, audioURL: nil, requestHeaders: h, qualityLabel: "\(candidate.height)p (MP4 Muxed)", diagnostics: "TRAILER: \(candidate.height)p (MP4 Muxed) [\(candidate.clientKey)]")
            }
        }
        // Then adaptive only when no muxed/HLS source exists. Explicit KSPlayer remains
        // capable of this lane; Auto normally avoids reaching it.
        for minimum in [1080, 720] {
            for video in adaptiveVideo where video.height >= minimum {
                let vHeaders = headers(for: video.clientKey)
                guard await reachable(url: video.url, headers: vHeaders) else { continue }
                for audio in adaptiveAudio.prefix(8) where await reachable(url: audio.url, headers: headers(for: audio.clientKey)) {
                    return SignalTrailerPlaybackSource(videoURL: video.url, audioURL: audio.url, requestHeaders: vHeaders, qualityLabel: "\(video.height)p (Adaptive)", diagnostics: "TRAILER: \(video.height)p (Adaptive) [\(video.clientKey)]")
                }
            }
        }
        // Any HLS before final fallback.
        if let candidate = hls.first {
            return SignalTrailerPlaybackSource(videoURL: candidate.manifestURL, audioURL: nil, requestHeaders: headers(for: candidate.clientKey), qualityLabel: "\(candidate.height)p (HLS)", diagnostics: "TRAILER: \(candidate.height)p (HLS) fallback [\(candidate.clientKey)]")
        }
        return nil
    }

    private func playerResponse(videoID: String, client: Client) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(Self.fallbackAPIKey)") else { throw URLError(.badURL) }
        let payload: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": client.context],
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]]
        ]
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(client.id, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return json
    }

    private func hlsCandidate(manifest: URL, client: Client) async throws -> HLSCandidate {
        var request = URLRequest(url: manifest, timeoutInterval: 6)
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var bestHeight = 0; var bestBandwidth = 0
        for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let upper = line.uppercased()
            if let range = upper.range(of: "RESOLUTION="), let x = upper[range.upperBound...].split(separator: ",").first?.split(separator: "X"), x.count == 2, let height = Int(x[1]), height <= Self.maxHeight {
                var bandwidth = 0
                if let br = upper.range(of: "BANDWIDTH="), let raw = upper[br.upperBound...].split(separator: ",").first { bandwidth = Int(raw) ?? 0 }
                if height > bestHeight || (height == bestHeight && bandwidth > bestBandwidth) { bestHeight = height; bestBandwidth = bandwidth }
            }
        }
        if bestHeight == 0 && text.contains("#EXTM3U") { bestHeight = Self.maxHeight; bestBandwidth = 5_000_000 }
        return HLSCandidate(clientKey: client.key, manifestURL: manifest, height: bestHeight, bandwidth: bestBandwidth, priority: client.priority)
    }

    private func headers(for clientKey: String) -> [String: String] {
        guard let client = Self.clients.first(where: { $0.key == clientKey }) else { return ["User-Agent": Self.defaultUserAgent] }
        return ["User-Agent": client.userAgent, "Accept-Language": "en-US,en;q=0.9"]
    }

    private func reachable(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (k,v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode) || http.statusCode == 206
        } catch { return false }
    }

    private func streamSort(_ lhs: StreamCandidate, _ rhs: StreamCandidate) -> Bool {
        if lhs.height != rhs.height { return lhs.height > rhs.height }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.priority < rhs.priority
    }

    private func videoScore(height: Int, fps: Int, bitrate: Double) -> Double { Double(height) * 1_000_000 + Double(fps) * 10_000 + bitrate }
    private func numericInt(_ value: Any?) -> Int? { if let i = value as? Int { return i }; if let d = value as? Double { return Int(d) }; if let n = value as? NSNumber { return n.intValue }; return nil }
    private func numericDouble(_ value: Any?) -> Double? { if let d = value as? Double { return d }; if let i = value as? Int { return Double(i) }; if let n = value as? NSNumber { return n.doubleValue }; return nil }
    private func qualityHeight(_ raw: String?) -> Int? { guard let raw, let range = raw.range(of: #"\d{3,4}"#, options: .regularExpression) else { return nil }; return Int(raw[range]) }

    private func canonicalIMDb(_ raw: String?) -> String? {
        guard let raw, let range = raw.range(of: #"tt\d{5,}"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(raw[range]).lowercased()
    }

    private func youtubeVideoID(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil { return raw }
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        func valid(_ value: String?) -> String? { guard let value, value.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil else { return nil }; return value }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") { return valid(url.path.split(separator: "/").first.map(String.init)) }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let id = c.queryItems?.first(where: { $0.name.lowercased() == "v" })?.value, let good = valid(id) { return good }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["embed","shorts","live"].contains($0.lowercased()) }), i + 1 < parts.count { return valid(parts[i+1]) }
        return nil
    }
}
