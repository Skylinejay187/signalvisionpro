import Foundation

/// Direct, Home-Assistant-free transport from Debrid Channels to a self-hosted
/// Debrid Now Showing server. Configuration lives in UserDefaults so it can be
/// included in Debrid Channels profile backup/restore.
final class DebridNowShowingDirectPushManager {
    static let shared = DebridNowShowingDirectPushManager()

    static let serverURLDefaultsKey = "debridNowShowingServerURLV1"
    static let pushTokenDefaultsKey = "debridNowShowingPushTokenV1"
    static let statusDefaultsKey = "debridNowShowingPushStatusV1"
    static let lastSuccessDefaultsKey = "debridNowShowingPushLastSuccessV1"

    private struct Snapshot {
        var sessionID: UUID
        var title: String
        var subtitle: String = ""
        var contentType: String = "movie"
        var state: String = "playing"
        var duration: Double = 0
        var position: Double = 0
        var year: Int?
        var season: Int?
        var episode: Int?
        var tmdbID: Int?
        var imdbID: String?
        var artworkURL: String = ""
        var channel: String = ""
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    private init() {
        if UserDefaults.standard.string(forKey: Self.statusDefaultsKey) == nil {
            UserDefaults.standard.set("Not configured", forKey: Self.statusDefaultsKey)
        }
    }

    var isConfigured: Bool {
        endpointURL(path: "/api/push") != nil
    }

    func claimVOD(sessionID: UUID, title: String, duration: Double, elapsed: Double, isPlaying: Bool) {
        let next = Snapshot(
            sessionID: sessionID,
            title: title,
            contentType: "movie",
            state: isPlaying ? "playing" : "paused",
            duration: safe(duration),
            position: safe(elapsed)
        )
        lock.lock(); snapshot = next; lock.unlock()
        sendCurrent(reason: "VOD claim")
    }

    func enrichVOD(
        sessionID: UUID,
        title: String,
        artist: String?,
        albumTitle: String?,
        externalContentID: String?,
        contentType: String,
        artworkURL: URL?
    ) {
        lock.lock()
        guard var current = snapshot, current.sessionID == sessionID else { lock.unlock(); return }
        current.title = title
        current.contentType = contentType
        current.artworkURL = artworkURL?.absoluteString ?? current.artworkURL
        applyExternalID(externalContentID, to: &current)
        if contentType == "episode" {
            current.subtitle = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            applyEpisodeLabel(albumTitle, to: &current)
        } else {
            current.subtitle = ""
            current.year = extractYear(albumTitle) ?? current.year
        }
        snapshot = current
        lock.unlock()
        sendCurrent(reason: "VOD metadata")
    }

    func updateVODTiming(sessionID: UUID, title: String, duration: Double, elapsed: Double, isPlaying: Bool) {
        lock.lock()
        guard var current = snapshot, current.sessionID == sessionID else { lock.unlock(); return }
        current.title = title.isEmpty ? current.title : title
        current.duration = safe(duration)
        current.position = safe(elapsed)
        current.state = isPlaying ? "playing" : "paused"
        snapshot = current
        lock.unlock()
        sendCurrent(reason: isPlaying ? "playing" : "paused")
    }

    func publishLive(
        sessionID: UUID,
        title: String,
        channelName: String,
        subtitle: String?,
        duration: Double,
        elapsed: Double,
        externalContentID: String?,
        artworkURL: URL?,
        isPlaying: Bool
    ) {
        var next = Snapshot(
            sessionID: sessionID,
            title: title,
            subtitle: subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            contentType: "live",
            state: isPlaying ? "playing" : "paused",
            duration: safe(duration),
            position: safe(elapsed),
            artworkURL: artworkURL?.absoluteString ?? "",
            channel: channelName
        )
        applyExternalID(externalContentID, to: &next)
        lock.lock(); snapshot = next; lock.unlock()
        sendCurrent(reason: "Live TV")
    }

    func updatePlaybackState(sessionID: UUID, isPlaying: Bool) {
        lock.lock()
        guard var current = snapshot, current.sessionID == sessionID else { lock.unlock(); return }
        current.state = isPlaying ? "playing" : "paused"
        snapshot = current
        lock.unlock()
        sendCurrent(reason: current.state)
    }

    func release(sessionID: UUID) {
        lock.lock()
        guard snapshot?.sessionID == sessionID else { lock.unlock(); return }
        snapshot = nil
        lock.unlock()
        sendPayload(["clear": true, "idle": true, "state": "idle", "sourceLabel": "Debrid Channels"], reason: "Idle")
    }

    func verifyConfiguration(completion: @escaping (String) -> Void) {
        guard let url = endpointURL(path: "/api/push/verify") else {
            let text = "Enter the Debrid Now Showing server URL first."
            setStatus(text)
            completion(text)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        request.httpBody = Data("{}".utf8)
        session.dataTask(with: request) { data, response, error in
            let text: String
            if let error {
                text = "Direct push test failed: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (object["sourcePriority"] as? String) == "home_assistant" {
                    text = "Connected, but Docker is Home Assistant only • choose Hybrid or Direct"
                } else {
                    text = "✓ Debrid Now Showing direct push connected"
                }
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                text = "Direct push rejected: token does not match the Docker"
            } else if let http = response as? HTTPURLResponse {
                text = "Direct push test returned HTTP \(http.statusCode)"
            } else {
                text = "Direct push test failed: no HTTP response"
            }
            self.setStatus(text)
            DispatchQueue.main.async { completion(text) }
            _ = data
        }.resume()
    }

    private func sendCurrent(reason: String) {
        lock.lock(); let current = snapshot; lock.unlock()
        guard let current else { return }
        var body: [String: Any] = [
            "state": current.state,
            "title": current.title,
            "contentType": current.contentType,
            "duration": current.duration,
            "position": current.position,
            "sourceLabel": "Debrid Channels",
            "appName": "Debrid Channels",
            "positionUpdatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if !current.subtitle.isEmpty { body["subtitle"] = current.subtitle }
        if let year = current.year { body["year"] = year }
        if let season = current.season { body["season"] = season }
        if let episode = current.episode { body["episode"] = episode }
        if let tmdbID = current.tmdbID { body["tmdbId"] = tmdbID }
        if let imdbID = current.imdbID, !imdbID.isEmpty { body["imdbId"] = imdbID }
        if !current.artworkURL.isEmpty { body["artwork"] = current.artworkURL }
        if !current.channel.isEmpty { body["channel"] = current.channel }
        sendPayload(body, reason: reason)
    }

    private func sendPayload(_ body: [String: Any], reason: String) {
        guard let url = endpointURL(path: "/api/push") else {
            setStatus("Not configured")
            return
        }
        guard JSONSerialization.isValidJSONObject(body), let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DebridChannels/vBRDC220", forHTTPHeaderField: "User-Agent")
        applyAuthorization(to: &request)
        request.httpBody = payload
        session.dataTask(with: request) { _, response, error in
            if let error {
                self.setStatus("Direct push offline • \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.setStatus("Direct push failed • no HTTP response")
                return
            }
            if (200..<300).contains(http.statusCode) {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSuccessDefaultsKey)
                self.setStatus("✓ Direct push active • \(reason)")
            } else if http.statusCode == 401 {
                self.setStatus("Direct push rejected • token mismatch")
            } else if http.statusCode == 202 {
                self.setStatus("Direct push ignored • Docker is Home Assistant only")
            } else {
                self.setStatus("Direct push HTTP \(http.statusCode)")
            }
        }.resume()
    }

    private func endpointURL(path: String) -> URL? {
        var raw = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "http://\(raw)" }
        guard var components = URLComponents(string: raw), components.host != nil else { return nil }
        if components.port == nil { components.port = 8088 }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func applyAuthorization(to request: inout URLRequest) {
        let token = UserDefaults.standard.string(forKey: Self.pushTokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Debrid-Now-Showing-Token")
    }

    private func setStatus(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.statusDefaultsKey)
    }

    private func safe(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private func applyExternalID(_ raw: String?, to current: inout Snapshot) {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.hasPrefix("tmdb:") {
            let pieces = value.split(separator: ":")
            if let last = pieces.last, let id = Int(last) { current.tmdbID = id }
        } else if value.hasPrefix("imdb:") {
            current.imdbID = String(value.dropFirst("imdb:".count))
        }
    }

    private func extractYear(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let pattern = #"(?:19|20)\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range, in: raw) else { return nil }
        return Int(raw[range])
    }

    private func applyEpisodeLabel(_ raw: String?, to current: inout Snapshot) {
        guard let raw else { return }
        let pattern = #"S(\d{1,2})E(\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let seasonRange = Range(match.range(at: 1), in: raw),
              let episodeRange = Range(match.range(at: 2), in: raw) else { return }
        current.season = Int(raw[seasonRange])
        current.episode = Int(raw[episodeRange])
    }
}
