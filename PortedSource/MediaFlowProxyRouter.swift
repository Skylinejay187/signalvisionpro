import Foundation
import Security
import Combine

enum MediaFlowProxyRouteKind: String {
    case vod
    case liveTV
}

struct MediaFlowProxySnapshot: Equatable {
    let enabled: Bool
    let proxyURLString: String
    let apiPassword: String
    let publicIPOverride: String
    let webBrowserPlayback: Bool

    var trimmedProxyURLString: String {
        proxyURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedPassword: String {
        apiPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedPublicIPOverride: String {
        publicIPOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MediaFlowConnectionTestResult: Equatable {
    let success: Bool
    let status: String
    let detectedIP: String
    let securitySummary: String
}

enum MediaFlowCredentialStore {
    private static let service = "com.channelsdebrid.tvos.mediaflow"
    private static let account = "mediaflow-api-password"
    // Playback SwiftUI bodies can be reevaluated many times per second. Do not perform
    // a synchronous Keychain lookup on every render; read once per process and update
    // the in-memory copy whenever Settings changes the credential.
    private static let cacheLock = NSLock()
    private static var cachedPassword: String?

    static func readPassword() -> String {
        cacheLock.lock()
        if let cachedPassword {
            cacheLock.unlock()
            return cachedPassword
        }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String
        if status == errSecSuccess,
           let data = result as? Data,
           let decoded = String(data: data, encoding: .utf8) {
            value = decoded
        } else {
            value = ""
        }
        cacheLock.lock()
        cachedPassword = value
        cacheLock.unlock()
        return value
    }

    @discardableResult
    static func savePassword(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(lookup as CFDictionary)
        let success: Bool
        if clean.isEmpty {
            success = true
        } else {
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(clean.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            success = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        if success {
            cacheLock.lock()
            cachedPassword = clean
            cacheLock.unlock()
        }
        return success
    }

    /// Fresh installs must not inherit a password from an older installation merely
    /// because the Keychain survived app deletion. Upgrade installs never call this.
    @discardableResult
    static func purgeForFreshInstall() -> Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(lookup as CFDictionary)
        let success = status == errSecSuccess || status == errSecItemNotFound
        if success {
            cacheLock.lock()
            cachedPassword = ""
            cacheLock.unlock()
        }
        return success
    }
}

enum MediaFlowProxyRouter {
    static let enabledKey = "mediaFlowProxyEnabledV1"
    static let proxyURLKey = "mediaFlowProxyURLV1"
    static let publicIPKey = "mediaFlowProxyPublicIPV1"
    static let webBrowserPlaybackKey = "mediaFlowWebBrowserPlaybackV1"
    static let lastDetectedIPKey = "mediaFlowLastDetectedIPV1"
    static let lastStatusKey = "mediaFlowLastStatusV1"
    static let lastTestDateKey = "mediaFlowLastTestDateV1"
    static let lastVerifiedKey = "mediaFlowLastVerifiedV1"

    static func snapshot(defaults: UserDefaults = .standard) -> MediaFlowProxySnapshot {
        MediaFlowProxySnapshot(
            enabled: defaults.bool(forKey: enabledKey),
            proxyURLString: defaults.string(forKey: proxyURLKey) ?? "",
            apiPassword: MediaFlowCredentialStore.readPassword(),
            publicIPOverride: defaults.string(forKey: publicIPKey) ?? "",
            webBrowserPlayback: defaults.bool(forKey: webBrowserPlaybackKey)
        )
    }

    /// vBRDC017: MediaFlow is one app-wide routing policy. Once enabled, there is no
    /// media-category bypass: VOD, addon results, Live TV, Sports, IPTV and previews all
    /// route through the configured MediaFlow instance. `kind` remains only so existing
    /// playback call sites keep their semantic labels without changing their API.
    static func shouldProxy(kind _: MediaFlowProxyRouteKind, snapshot: MediaFlowProxySnapshot? = nil) -> Bool {
        let config = snapshot ?? self.snapshot()
        return config.enabled
    }

    static func configurationError(kind: MediaFlowProxyRouteKind, snapshot: MediaFlowProxySnapshot? = nil) -> String? {
        let config = snapshot ?? self.snapshot()
        guard shouldProxy(kind: kind, snapshot: config) else { return nil }
        guard let baseURL = normalizedBaseURL(config.trimmedProxyURLString) else {
            return "MediaFlow Proxy is enabled, but Proxy URL is missing or invalid. Open Settings → MediaFlow Proxy and enter an http:// or https:// server address."
        }
        guard baseURL.scheme?.lowercased() == "http" || baseURL.scheme?.lowercased() == "https" else {
            return "MediaFlow Proxy URL must use http:// or https://."
        }
        guard !config.trimmedPassword.isEmpty else {
            return "MediaFlow Proxy is enabled, but API Password is missing. Open Settings → MediaFlow Proxy and enter the API_PASSWORD configured on the home MediaFlow server."
        }
        return nil
    }

    /// Returns the URL that the player must open. When MediaFlow is enabled for this
    /// route, an invalid configuration fails closed by returning nil; the caller must
    /// not silently fall back to the device's direct public IP.
    static func playbackURLIfAllowed(
        for sourceURL: URL,
        kind: MediaFlowProxyRouteKind,
        upstreamHeaders: [String: String] = [:]
    ) -> URL? {
        let config = snapshot()
        guard shouldProxy(kind: kind, snapshot: config) else { return sourceURL }
        guard configurationError(kind: kind, snapshot: config) == nil,
              let baseURL = normalizedBaseURL(config.trimmedProxyURLString) else { return nil }
        if isAlreadyWrappedByConfiguredProxy(sourceURL, baseURL: baseURL) { return sourceURL }
        let endpoint: String
        switch mediaType(for: sourceURL) {
        case .hls:
            endpoint = "/proxy/hls/manifest.m3u8"
        case .dash:
            endpoint = "/proxy/mpd/manifest.m3u8"
        case .generic:
            endpoint = "/proxy/stream"
        }
        // vBRDC089: protected In-S/Stremio/FebBox sources often require Referer,
        // Origin, Cookie, Authorization, or a provider-specific User-Agent. When
        // MediaFlow owns the network hop those values must be encoded as h_* upstream
        // parameters; sending them only to the Apple TV player would authenticate the
        // proxy request itself but leave MediaFlow's destination request anonymous.
        return makeProxyURL(
            baseURL: baseURL,
            endpoint: endpoint,
            destination: sourceURL,
            apiPassword: config.trimmedPassword,
            headers: upstreamHeaders
        )
    }

    /// Provider headers belong to the destination host. When MediaFlow is active they
    /// are already encoded into the proxy URL and should not also be emitted as headers
    /// to the proxy server itself. Direct playback keeps them unchanged.
    static func playerRequestHeaders(
        for kind: MediaFlowProxyRouteKind,
        upstreamHeaders: [String: String]
    ) -> [String: String] {
        let config = snapshot()
        return shouldProxy(kind: kind, snapshot: config) ? [:] : upstreamHeaders
    }

    /// Wraps an API/debrid request through MediaFlow's /proxy/forward endpoint. This is
    /// intentionally separate from media streaming: the original HTTP method/body are
    /// preserved and upstream headers are encoded as MediaFlow h_* parameters.
    static func forwardRequestIfAllowed(
        _ original: URLRequest,
        kind: MediaFlowProxyRouteKind = .vod
    ) -> URLRequest? {
        let config = snapshot()
        guard shouldProxy(kind: kind, snapshot: config) else { return original }
        guard configurationError(kind: kind, snapshot: config) == nil,
              let destination = original.url,
              let baseURL = normalizedBaseURL(config.trimmedProxyURLString),
              let proxyURL = makeProxyURL(
                baseURL: baseURL,
                endpoint: "/proxy/forward",
                destination: destination,
                apiPassword: config.trimmedPassword,
                headers: original.allHTTPHeaderFields ?? [:]
              ) else { return nil }

        var forwarded = URLRequest(
            url: proxyURL,
            cachePolicy: original.cachePolicy,
            timeoutInterval: original.timeoutInterval
        )
        forwarded.httpMethod = original.httpMethod
        forwarded.httpBody = original.httpBody
        forwarded.httpShouldHandleCookies = false
        if let contentType = original.value(forHTTPHeaderField: "Content-Type") {
            // Keep an inbound content type as well so the forward endpoint can consume
            // the request body normally; the same value is also sent upstream via h_*.
            forwarded.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        forwarded.setValue("DebridChannels-tvOS/MediaFlow", forHTTPHeaderField: "User-Agent")
        return forwarded
    }

    /// Live TV bootstrap is GET/HEAD-only and may legitimately target a private home-LAN
    /// address (Channels DVR / HDHomeRun / local XMLTV). MediaFlow's generic
    /// `/proxy/forward` endpoint intentionally rejects RFC-1918/loopback destinations, so
    /// it is the wrong route for this job. Use the normal stream relay for lineup/API/M3U
    /// GETs and the dedicated EPG relay for XMLTV/Gracenote. Those endpoints execute on
    /// the MediaFlow host and can therefore reach services on the same home network.
    /// Live TV bootstrap is GET/HEAD-only and may legitimately target a private home-LAN
    /// address (Channels DVR / HDHomeRun / local XMLTV). MediaFlow's generic
    /// `/proxy/forward` endpoint intentionally rejects RFC-1918/loopback destinations, so
    /// it is the wrong route for this job. Use the long-standing stream relay for
    /// lineup/API/M3U GETs. XMLTV/Gracenote prefers the dedicated EPG relay and retains
    /// `/proxy/stream` as a compatibility fallback for older MediaFlow installs.
    static func liveTVBootstrapRequestsIfAllowed(
        _ original: URLRequest,
        epg: Bool
    ) -> [URLRequest]? {
        let config = snapshot()
        guard shouldProxy(kind: .liveTV, snapshot: config) else { return [original] }
        guard configurationError(kind: .liveTV, snapshot: config) == nil,
              let destination = original.url,
              let baseURL = normalizedBaseURL(config.trimmedProxyURLString) else { return nil }
        if isAlreadyWrappedByConfiguredProxy(destination, baseURL: baseURL) { return [original] }
        let method = (original.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else {
            return forwardRequestIfAllowed(original, kind: .liveTV).map { [$0] }
        }

        let endpoints = epg ? ["/proxy/epg", "/proxy/stream"] : ["/proxy/stream"]
        let requests = endpoints.compactMap { endpoint -> URLRequest? in
            guard let proxyURL = makeProxyURL(
                baseURL: baseURL,
                endpoint: endpoint,
                destination: destination,
                apiPassword: config.trimmedPassword,
                headers: original.allHTTPHeaderFields ?? [:]
            ) else { return nil }
            var routed = URLRequest(
                url: proxyURL,
                cachePolicy: original.cachePolicy,
                timeoutInterval: original.timeoutInterval
            )
            routed.httpMethod = method
            routed.httpShouldHandleCookies = false
            // Destination headers are encoded as h_* query items. Do not duplicate them
            // as inbound proxy headers.
            routed.setValue("DebridChannels-tvOS/MediaFlow-LiveTV", forHTTPHeaderField: "User-Agent")
            return routed
        }
        return requests.isEmpty ? nil : requests
    }

    static func testConnection(
        proxyURLString: String,
        apiPassword: String,
        expectedPublicIP: String
    ) async -> MediaFlowConnectionTestResult {
        guard let baseURL = normalizedBaseURL(proxyURLString) else {
            return MediaFlowConnectionTestResult(
                success: false,
                status: "Invalid Proxy URL. Enter a complete http:// or https:// address.",
                detectedIP: "",
                securitySummary: "Not connected"
            )
        }
        let cleanPassword = apiPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPassword.isEmpty else {
            return MediaFlowConnectionTestResult(
                success: false,
                status: "API Password is required.",
                detectedIP: "",
                securitySummary: securitySummary(for: baseURL)
            )
        }

        do {
            guard let healthURL = endpointURL(baseURL: baseURL, endpoint: "/health") else {
                throw URLError(.badURL)
            }
            var healthRequest = URLRequest(url: healthURL, timeoutInterval: 7)
            healthRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, healthResponse) = try await URLSession.shared.data(for: healthRequest)
            guard let healthHTTP = healthResponse as? HTTPURLResponse,
                  (200...299).contains(healthHTTP.statusCode) else {
                return MediaFlowConnectionTestResult(
                    success: false,
                    status: "MediaFlow server responded, but /health did not report success.",
                    detectedIP: "",
                    securitySummary: securitySummary(for: baseURL)
                )
            }

            guard var ipComponents = endpointURL(baseURL: baseURL, endpoint: "/proxy/ip").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
                throw URLError(.badURL)
            }
            ipComponents.queryItems = [URLQueryItem(name: "api_password", value: cleanPassword)]
            guard let ipURL = ipComponents.url else { throw URLError(.badURL) }
            var ipRequest = URLRequest(url: ipURL, timeoutInterval: 7)
            ipRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (ipData, ipResponse) = try await URLSession.shared.data(for: ipRequest)
            guard let ipHTTP = ipResponse as? HTTPURLResponse,
                  (200...299).contains(ipHTTP.statusCode) else {
                return MediaFlowConnectionTestResult(
                    success: false,
                    status: "MediaFlow is reachable, but API Password authentication failed or /proxy/ip is unavailable.",
                    detectedIP: "",
                    securitySummary: securitySummary(for: baseURL)
                )
            }
            let object = try? JSONSerialization.jsonObject(with: ipData) as? [String: Any]
            let detected = (object?["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !detected.isEmpty else {
                return MediaFlowConnectionTestResult(
                    success: false,
                    status: "MediaFlow is reachable, but it did not return a public IP.",
                    detectedIP: "",
                    securitySummary: securitySummary(for: baseURL)
                )
            }
            let expected = expectedPublicIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if !expected.isEmpty && expected.caseInsensitiveCompare(detected) != .orderedSame {
                return MediaFlowConnectionTestResult(
                    success: false,
                    status: "Connected, but MediaFlow reports \(detected) instead of the configured Public IP \(expected). Verify the home/proxy IP before relying on this connection.",
                    detectedIP: detected,
                    securitySummary: securitySummary(for: baseURL)
                )
            }
            return MediaFlowConnectionTestResult(
                success: true,
                status: "Connected • all enabled Debrid Channels playback will route through MediaFlow.",
                detectedIP: detected,
                securitySummary: securitySummary(for: baseURL)
            )
        } catch {
            return MediaFlowConnectionTestResult(
                success: false,
                status: "Connection failed: \(error.localizedDescription)",
                detectedIP: "",
                securitySummary: securitySummary(for: baseURL)
            )
        }
    }

    private enum MediaType {
        case generic
        case hls
        case dash
    }

    private static func mediaType(for url: URL) -> MediaType {
        let lower = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || lower.contains(".m3u8") || lower.contains("/hls/") || lower.contains("format=hls") || lower.contains("type=hls") {
            return .hls
        }
        if ext == "mpd" || lower.contains(".mpd") || lower.contains("manifest.mpd") || lower.contains("format=dash") || lower.contains("type=dash") {
            return .dash
        }
        return .generic
    }

    private static func normalizedBaseURL(_ raw: String) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              var components = URLComponents(string: clean),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    private static func endpointURL(baseURL: URL, endpoint: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath: String
        if components.path == "/" { basePath = "" }
        else { basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path }
        components.path = basePath + endpoint
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func makeProxyURL(
        baseURL: URL,
        endpoint: String,
        destination: URL,
        apiPassword: String,
        headers: [String: String]
    ) -> URL? {
        guard let endpointURL = endpointURL(baseURL: baseURL, endpoint: endpoint),
              var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else { return nil }
        var queryItems = [
            URLQueryItem(name: "d", value: destination.absoluteString),
            URLQueryItem(name: "api_password", value: apiPassword)
        ]
        for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            queryItems.append(URLQueryItem(name: "h_\(trimmedName)", value: value))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func isAlreadyWrappedByConfiguredProxy(_ url: URL, baseURL: URL) -> Bool {
        guard url.host?.caseInsensitiveCompare(baseURL.host ?? "") == .orderedSame else { return false }
        let path = url.path.lowercased()
        return path.contains("/proxy/stream") ||
            path.contains("/proxy/epg") ||
            path.contains("/proxy/forward") ||
            path.contains("/proxy/hls/") ||
            path.contains("/proxy/mpd/") ||
            path.contains("/proxy/acestream/") ||
            path.contains("/proxy/telegram/")
    }

    private static func securitySummary(for baseURL: URL) -> String {
        baseURL.scheme?.lowercased() == "https" ? "HTTPS encrypted" : "HTTP cleartext • HTTPS recommended for external access"
    }
}

enum MediaFlowConnectionPhase: Equatable {
    case disabled
    case checking
    case connected
    case failed
}

/// vBRDC017: process-wide MediaFlow connection watchdog. This is intentionally separate
/// from source selection and player identity: it verifies the configured home proxy,
/// publishes a 15-second connection banner, and performs a lightweight idle heartbeat.
/// Playback routing itself remains fail-closed: if the proxy disappears after a successful
/// check, the wrapped MediaFlow URL fails rather than falling back to the device IP.
@MainActor
final class MediaFlowConnectionMonitor: ObservableObject {
    static let shared = MediaFlowConnectionMonitor()

    @Published private(set) var phase: MediaFlowConnectionPhase = .disabled
    @Published private(set) var statusText: String = "MediaFlow Proxy Off"
    @Published private(set) var detectedIP: String = ""
    @Published private(set) var securitySummary: String = ""
    @Published private(set) var bannerVisible: Bool = false

    private var verificationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var verificationGeneration: UInt64 = 0
    private var appIsActive = false
    private var playbackIsActive = false
    private var lastSuccessfulVerificationAt: Date?

    private let successBannerDurationNanoseconds: UInt64 = 15_000_000_000
    private let heartbeatIntervalNanoseconds: UInt64 = 60_000_000_000
    private let freshReuseWindow: TimeInterval = 20

    private init() {
        let defaults = UserDefaults.standard
        detectedIP = defaults.string(forKey: MediaFlowProxyRouter.lastDetectedIPKey) ?? ""
        statusText = defaults.string(forKey: MediaFlowProxyRouter.lastStatusKey) ?? "MediaFlow Proxy Off"
        if defaults.bool(forKey: MediaFlowProxyRouter.lastVerifiedKey) {
            phase = .connected
        }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active {
            startHeartbeatIfNeeded()
        } else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            verificationTask?.cancel()
            verificationTask = nil
            dismissTask?.cancel()
            dismissTask = nil
            bannerVisible = false
        }
    }

    func setPlaybackActive(_ active: Bool) {
        playbackIsActive = active
        if active {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            bannerVisible = false
        } else {
            startHeartbeatIfNeeded()
        }
    }

    func markConfigurationChanged() {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lastSuccessfulVerificationAt = nil

        let config = MediaFlowProxyRouter.snapshot()
        guard config.enabled else {
            setDisabled()
            return
        }

        phase = .checking
        statusText = "MediaFlow configuration changed • verifying automatically"
        detectedIP = ""
        bannerVisible = true
        persist(verified: false)
    }

    func refresh(reason: String, showBanner: Bool = true, allowFreshReuse: Bool = true) {
        let config = MediaFlowProxyRouter.snapshot()
        guard config.enabled else {
            setDisabled()
            return
        }

        if allowFreshReuse,
           phase == .connected,
           let lastSuccessfulVerificationAt,
           Date().timeIntervalSince(lastSuccessfulVerificationAt) <= freshReuseWindow {
            if showBanner {
                bannerVisible = true
                scheduleSuccessDismiss()
            }
            startHeartbeatIfNeeded()
            return
        }

        if let error = MediaFlowProxyRouter.configurationError(kind: .vod, snapshot: config) {
            phase = .failed
            statusText = error
            detectedIP = ""
            securitySummary = "Not connected"
            bannerVisible = true
            persist(verified: false)
            heartbeatTask?.cancel()
            heartbeatTask = nil
            return
        }

        verificationGeneration &+= 1
        let generation = verificationGeneration
        verificationTask?.cancel()
        dismissTask?.cancel()
        dismissTask = nil
        phase = .checking
        statusText = "Checking MediaFlow home proxy…"
        if showBanner { bannerVisible = true }

        let proxyURL = config.proxyURLString
        let password = config.apiPassword
        let expectedIP = config.publicIPOverride
        verificationTask = Task { [weak self] in
            guard let self else { return }
            let result = await MediaFlowProxyRouter.testConnection(
                proxyURLString: proxyURL,
                apiPassword: password,
                expectedPublicIP: expectedIP
            )
            guard !Task.isCancelled, generation == self.verificationGeneration else { return }
            self.verificationTask = nil
            self.apply(result: result, showBannerOnSuccess: showBanner, reason: reason)
        }
    }

    func applyManualTestResult(_ result: MediaFlowConnectionTestResult) {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        apply(result: result, showBannerOnSuccess: true, reason: "manual test")
    }

    private func apply(result: MediaFlowConnectionTestResult, showBannerOnSuccess: Bool, reason _: String) {
        detectedIP = result.detectedIP
        securitySummary = result.securitySummary
        statusText = result.status
        if result.success {
            phase = .connected
            lastSuccessfulVerificationAt = Date()
            persist(verified: true)
            if showBannerOnSuccess {
                bannerVisible = true
                scheduleSuccessDismiss()
            }
            startHeartbeatIfNeeded()
        } else {
            phase = .failed
            lastSuccessfulVerificationAt = nil
            bannerVisible = true
            persist(verified: false)
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    private func setDisabled() {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        phase = .disabled
        statusText = "MediaFlow Proxy Off"
        detectedIP = ""
        securitySummary = ""
        bannerVisible = false
        lastSuccessfulVerificationAt = nil
        persist(verified: false)
    }

    private func scheduleSuccessDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: successBannerDurationNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.phase == .connected else { return }
            self.bannerVisible = false
            self.dismissTask = nil
        }
    }

    private func startHeartbeatIfNeeded() {
        guard appIsActive, !playbackIsActive, phase == .connected, heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: heartbeatIntervalNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled, self.appIsActive, !self.playbackIsActive else { break }
                let config = MediaFlowProxyRouter.snapshot()
                guard config.enabled else {
                    self.setDisabled()
                    break
                }
                let result = await MediaFlowProxyRouter.testConnection(
                    proxyURLString: config.proxyURLString,
                    apiPassword: config.apiPassword,
                    expectedPublicIP: config.publicIPOverride
                )
                guard !Task.isCancelled else { break }
                if result.success {
                    self.detectedIP = result.detectedIP
                    self.securitySummary = result.securitySummary
                    self.statusText = result.status
                    self.phase = .connected
                    self.lastSuccessfulVerificationAt = Date()
                    self.persist(verified: true)
                } else {
                    self.apply(result: result, showBannerOnSuccess: false, reason: "heartbeat")
                    break
                }
            }
            self.heartbeatTask = nil
            self.startHeartbeatIfNeeded()
        }
    }

    private func persist(verified: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(detectedIP, forKey: MediaFlowProxyRouter.lastDetectedIPKey)
        defaults.set(statusText, forKey: MediaFlowProxyRouter.lastStatusKey)
        defaults.set(verified, forKey: MediaFlowProxyRouter.lastVerifiedKey)
        let formatter = ISO8601DateFormatter()
        defaults.set(formatter.string(from: Date()), forKey: MediaFlowProxyRouter.lastTestDateKey)
    }
}

