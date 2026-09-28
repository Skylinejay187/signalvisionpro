import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// User-owned FebBox credentials remain on the Apple device. The backend receives the
/// cookie only in the body of an individual resolver/verification request and must treat
/// it as transient request data (never persistence, cache material, or log content).
enum BackupStreamingCredentialStore {
    private static let service = "com.channelsdebrid.tvos.backupstreaming"
    private static let account = "febbox-ui-cookie"
    private static let lock = NSLock()
    private static var cachedCookie: String?

    static func readFebBoxCookie() -> String {
        lock.lock()
        if let cachedCookie {
            lock.unlock()
            return cachedCookie
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value: String
        if status == errSecSuccess,
           let data = item as? Data,
           let decoded = String(data: data, encoding: .utf8) {
            value = decoded
        } else {
            value = ""
        }
        lock.lock()
        cachedCookie = value
        lock.unlock()
        return value
    }

    @discardableResult
    static func saveFebBoxCookie(_ raw: String) -> Bool {
        let clean = normalizedCookieValue(raw)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let success: Bool
        if clean.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            success = status == errSecSuccess || status == errSecItemNotFound
        } else {
            let data = Data(clean.utf8)
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                success = true
            } else if updateStatus == errSecItemNotFound {
                var add = baseQuery
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                success = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            } else {
                success = false
            }
        }

        if success {
            lock.lock()
            cachedCookie = clean
            lock.unlock()
        }
        return success
    }

    /// Deletes any stale FebBox token that survived an uninstall because Keychain items
    /// are not automatically scoped to the lifetime of the app container. Normal app
    /// upgrades do not call this; the fresh-install boundary owns that decision.
    @discardableResult
    static func purgeForFreshInstall() -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(baseQuery as CFDictionary)
        let success = status == errSecSuccess || status == errSecItemNotFound
        if success {
            lock.lock()
            cachedCookie = ""
            lock.unlock()
        }
        return success
    }

    /// Accepts either the value copied from the `ui` row or a pasted `ui=...` token.
    /// Never accepts a full browser cookie jar; that keeps accidental credential sharing
    /// out of the app and sends only the one FebBox account token the resolver needs.
    static func normalizedCookieValue(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("ui=") {
            clean.removeFirst(3)
        }
        if let semicolon = clean.firstIndex(of: ";") {
            clean = String(clean[..<semicolon])
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BackupStreamingAccountStatus: Equatable {
    let valid: Bool
    let message: String
    let remainingMB: Double?
    let trafficLimitMB: Double?
    let trafficUsedMB: Double?

    var remainingDisplay: String {
        guard let remainingMB else { return "Unknown" }
        if remainingMB >= 1024 {
            return String(format: "%.1f GB", remainingMB / 1024.0)
        }
        return String(format: "%.0f MB", max(0, remainingMB))
    }
}

private struct BackupStreamingResolveRequest: Encodable {
    let schemaVersion: Int
    let tmdbId: String?
    let imdbId: String?
    let mediaType: String
    let title: String
    let year: String
    let season: Int?
    let episode: Int?
    let febboxCookie: String
}

private struct BackupStreamingVerifyRequest: Encodable {
    let schemaVersion: Int
    let febboxCookie: String
}

private struct BackupStreamingResolvedSource: Decodable {
    let provider: String?
    let title: String?
    let url: String?
    let quality: String?
    let size: String?
    let codecs: [String]?
    let language: String?
    // vBRDC089: the backend may return safe provider request hints, but never the
    // user's FebBox ui cookie itself. The Apple TV reconstructs that Cookie header
    // from the credential it already owns in Keychain.
    let headers: [String: String]?
    let referer: String?
    let region: String?
}

private struct BackupStreamingResolveResponse: Decodable {
    let schemaVersion: Int?
    let status: String?
    let message: String?
    let streams: [BackupStreamingResolvedSource]
}

private struct BackupStreamingVerifyResponse: Decodable {
    let schemaVersion: Int?
    let valid: Bool?
    let status: String?
    let message: String?
    let remainingMB: Double?
    let trafficLimitMB: Double?
    let trafficUsedMB: Double?
}

enum BackupStreamingClientError: LocalizedError {
    case backendNotConfigured
    case invalidResponse
    case responseTooLarge
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "The Debrid Channels backend URL is not configured."
        case .invalidResponse:
            return "The FebBox service returned an invalid response."
        case .responseTooLarge:
            return "The FebBox response exceeded the safe size limit."
        case .backendRejected(let message):
            return message
        }
    }
}

enum BackupStreamingClient {
    static let febBoxEnabledKey = "optionalFebBoxEnabledV1"
    private static let maximumResponseBytes = 4_000_000

    /// Resolves the user's personal FebBox source independently of Nuvio plugins and
    /// Stremio addons. The `ui` cookie remains request-scoped and is never persisted by
    /// the backend or included in visible diagnostics.
    static func resolveFebBox(backendBaseURL: String, item: MediaItem, febboxCookie: String) async throws -> [StreamLink] {
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/backup-streaming/febbox/resolve")
        let cleanCookie = BackupStreamingCredentialStore.normalizedCookieValue(febboxCookie)
        guard !cleanCookie.isEmpty else { return [] }
        let payload = BackupStreamingResolveRequest(
            schemaVersion: 1,
            tmdbId: item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty,
            imdbId: item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty,
            mediaType: normalizedMediaType(item.type),
            title: item.title,
            year: item.year,
            season: item.seasonNumber,
            episode: item.episodeNumber,
            febboxCookie: cleanCookie
        )
        let response: BackupStreamingResolveResponse = try await postJSON(endpoint: endpoint, payload: payload)
        let responseStatus = response.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if responseStatus == "unavailable" || responseStatus == "error" {
            let safeMessage = response.message?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty
                ?? "FebBox service is unavailable."
            throw BackupStreamingClientError.backendRejected(safeMessage)
        }

        var seen = Set<String>()
        return response.streams.compactMap { source -> StreamLink? in
            guard let rawURL = source.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = URL(string: rawURL),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  seen.insert(rawURL).inserted else { return nil }
            let provider = source.provider?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty ?? "FebBox"
            let codecText = (source.codecs ?? []).filter { !$0.isEmpty }.joined(separator: " • ")
            let languageText = source.language?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty
            let baseTitle = source.title?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty ?? item.title
            let details = [codecText.backupNonEmpty, languageText].compactMap { $0 }.joined(separator: " • ")
            let displayTitle = details.isEmpty ? baseTitle : "\(baseTitle) • \(details)"
            var playbackHeaders = sanitizedPlaybackHeaders(source.headers ?? [:])
            if playbackHeaders.keys.first(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) == nil {
                playbackHeaders["User-Agent"] = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
            }
            if playbackHeaders.keys.first(where: { $0.caseInsensitiveCompare("Accept") == .orderedSame }) == nil {
                playbackHeaders["Accept"] = "*/*"
            }
            if let referer = source.referer?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty {
                playbackHeaders["Referer"] = referer
                if let components = URLComponents(string: referer), let scheme = components.scheme, let host = components.host {
                    playbackHeaders["Origin"] = "\(scheme)://\(host)"
                }
            }
            if playbackHeaders.keys.first(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }) == nil {
                playbackHeaders["Referer"] = "https://www.febbox.com/"
            }
            if playbackHeaders.keys.first(where: { $0.caseInsensitiveCompare("Origin") == .orderedSame }) == nil {
                playbackHeaders["Origin"] = "https://www.febbox.com"
            }
            let region = source.region?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty ?? "USA7"
            // The cookie remains local: backend resolution never echoes it. Playback needs
            // the same ui + oss_group context that successfully opened /file/player.
            playbackHeaders["Cookie"] = "ui=\(cleanCookie); oss_group=\(region)"
            return StreamLink(
                title: displayTitle,
                url: rawURL,
                quality: source.quality?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty ?? "Auto",
                size: source.size?.trimmingCharacters(in: .whitespacesAndNewlines).backupNonEmpty ?? "Unknown size",
                source: provider,
                providerService: "FebBox",
                infoHash: nil,
                fileIndex: nil,
                subtitleURLs: [],
                requestHeaders: playbackHeaders.map { StreamRequestHeader(name: $0.key, value: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                isExternalURL: false
            )
        }
    }

    static func verifyFebBox(backendBaseURL: String, cookie: String) async throws -> BackupStreamingAccountStatus {
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/backup-streaming/febbox/verify")
        let cleanCookie = BackupStreamingCredentialStore.normalizedCookieValue(cookie)
        guard !cleanCookie.isEmpty else {
            return BackupStreamingAccountStatus(valid: false, message: "Enter your FebBox ui cookie first.", remainingMB: nil, trafficLimitMB: nil, trafficUsedMB: nil)
        }
        let response: BackupStreamingVerifyResponse = try await postJSON(
            endpoint: endpoint,
            payload: BackupStreamingVerifyRequest(schemaVersion: 1, febboxCookie: cleanCookie)
        )
        return BackupStreamingAccountStatus(
            valid: response.valid ?? false,
            message: response.status ?? response.message ?? ((response.valid ?? false) ? "FebBox cookie verified" : "FebBox cookie could not be verified"),
            remainingMB: response.remainingMB,
            trafficLimitMB: response.trafficLimitMB,
            trafficUsedMB: response.trafficUsedMB
        )
    }

    private static func sanitizedPlaybackHeaders(_ source: [String: String]) -> [String: String] {
        let blocked = Set(["host", "content-length", "transfer-encoding", "range", "content-range", "cookie"])
        var result: [String: String] = [:]
        for (rawName, rawValue) in source.prefix(64) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128, !blocked.contains(name.lowercased()),
                  !value.isEmpty, value.utf8.count <= 8192,
                  !name.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f || $0.value == 58 }),
                  !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else { continue }
            result[name] = value
        }
        return result
    }

    private static func normalizedMediaType(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("series") || lower.contains("show") || lower == "tv" || lower == "episode" { return "tv" }
        return "movie"
    }

    private static func endpointURL(baseURL: String, path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw BackupStreamingClientError.backendNotConfigured
        }
        return url
    }

    private static func postJSON<Request: Encodable, Response: Decodable>(endpoint: URL, payload: Request) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/FebBox", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else { throw BackupStreamingClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw BackupStreamingClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw BackupStreamingClientError.backendRejected("FebBox service failed with HTTP \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BackupStreamingClientError.invalidResponse
        }
    }
}

private extension String {
    var backupNonEmpty: String? { isEmpty ? nil : self }
}
