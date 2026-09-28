import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

struct TraktDeviceLinkCode: Hashable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int
}

struct TraktTitleStats: Hashable {
    let watchers: Int
    let plays: Int
    let collectors: Int
    let comments: Int
    let lists: Int
    let votes: Int
}

struct TraktCloudResumePoint: Codable, Hashable {
    let playbackID: Int?
    let kind: String
    let title: String
    let year: Int?
    let showTitle: String?
    let showYear: Int?
    let season: Int?
    let episode: Int?
    let imdbID: String?
    let tmdbID: Int?
    let showIMDbID: String?
    let showTMDBID: Int?
    let progress: Double
    let runtimeMinutes: Int?
    let pausedAt: Date

    var durationSeconds: Double {
        guard let runtimeMinutes, runtimeMinutes > 0 else { return 0 }
        return Double(runtimeMinutes) * 60.0
    }

    var seconds: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(progress / 100.0, 0), 1) * durationSeconds
    }
}

private struct TraktOAuthTokenBundle: Codable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var scope: String
    var createdAt: TimeInterval
    var expiresIn: TimeInterval

    var expiresAt: TimeInterval { createdAt + max(60, expiresIn) }
}

enum TraktScrobbleEvent: String {
    case start
    case pause
    case stop
}

/// vBRDC194: Trakt is a synchronization layer above Debrid Channels' existing local
/// resume cache. The local cache remains the instant/offline source of truth, while
/// Trakt imports/exports unfinished playback state so another Apple TV/iOS device can
/// resume the same movie/episode after linking the same Trakt account.
final class TraktSyncManager {
    static let shared = TraktSyncManager()

    static let clientIDDefaultsKey = "traktClientIDV1"
    static let enabledDefaultsKey = "traktResumeSyncEnabledV1"
    static let accountDefaultsKey = "traktConnectedAccountV1"
    static let lastSyncDefaultsKey = "traktLastPlaybackSyncAtV1"
    static let statusDefaultsKey = "traktLastSyncStatusV1"
    static let accountVerifiedDefaultsKey = "traktAccountVerifiedAtV1"

    private let lock = NSLock()
    private var cloudResumePoints: [TraktCloudResumePoint] = []
    private var lastCheckpointAt: [String: Date] = [:]
    private var refreshInFlight = false
    // vBRDC206: natural episode EOF may defer the expensive cloud playback-list refresh
    // until the incoming decoder is stable. The stop scrobble itself is still sent at EOF.
    private var deferredProgressRefreshNeeded = false
    // vBRDC202: one startup Keychain read establishes connection identity. SwiftUI and
    // catalog code query isConnected frequently; they must not synchronously re-enter
    // Security.framework on every body/update. Token writes refresh this memory copy.
    private var tokenBundleCache: TraktOAuthTokenBundle? = nil
    // Trakt refresh tokens are single-use. Serialize refresh exchanges so simultaneous
    // scrobble/sync requests can never race the same refresh token.
    private var tokenRefreshTask: Task<String, Error>? = nil

    private static let keychainService = "com.channelsdebrid.tvos.trakt"
    private static let tokenAccount = "oauth-token-v1"
    private static let secretAccount = "client-secret-v1"
    private static let apiVersion = "2"
    private static let appVersion = "1.0.923"
    private static let appDate = "2026-09-08"

    // vBRDC194: Debrid Channels now owns one shared Trakt API application.
    // Keep the app identity out of user-facing settings. Trakt's native Device Code
    // flow requires the app client secret at token exchange time, so the credential is
    // stored as non-plain-text byte material rather than a literal source string.
    // This is obfuscation, not a substitute for a backend-held secret.
    private static let bundledCredentialMask: UInt8 = 0x5A
    private static let bundledClientIDBytes: [UInt8] = [54, 108, 51, 45, 107, 49, 111, 48, 23, 57, 17, 63, 5, 31, 34, 28, 21, 57, 35, 15, 14, 0, 44, 45, 50, 30, 57, 108, 30, 46, 62, 62, 62, 9, 18, 17, 98, 104, 20, 110, 15, 51, 31]
    private static let bundledClientSecretBytes: [UInt8] = [108, 105, 42, 46, 105, 25, 5, 51, 32, 108, 60, 108, 12, 52, 111, 34, 2, 42, 42, 25, 40, 8, 54, 61, 22, 61, 2, 104, 56, 98, 41, 63, 55, 9, 3, 109, 15, 19, 17, 32, 9, 43, 31]

    private static func decodeBundledCredential(_ bytes: [UInt8]) -> String {
        String(bytes: bytes.map { $0 ^ bundledCredentialMask }, encoding: .utf8) ?? ""
    }

    private static var resumeCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DebridChannels", isDirectory: true)
            .appendingPathComponent("trakt-playback-resume-v1.json")
    }

    private init() {
        if let raw = Self.readKeychainString(account: Self.tokenAccount),
           let data = raw.data(using: .utf8) {
            tokenBundleCache = try? JSONDecoder().decode(TraktOAuthTokenBundle.self, from: data)
        }
        loadPersistedCloudResumeCache()
        // vBRDC197: a newly launched/newly installed Debrid Channels instance should
        // immediately inherit the last successfully synced Trakt resume snapshot even
        // before the first network refresh completes. Timestamp guards prevent rollback.
        _ = materializeCloudResumePoints(cloudResumePoints)
    }

    @inline(__always)
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    var configuredClientID: String {
        let env = ProcessInfo.processInfo.environment["TRAKT_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let bundled = Self.decodeBundledCredential(Self.bundledClientIDBytes)
        if !bundled.isEmpty { return bundled }
        // Legacy developer override retained only as a migration/debug fallback.
        return UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var configuredClientSecret: String {
        let env = ProcessInfo.processInfo.environment["TRAKT_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let bundled = Self.decodeBundledCredential(Self.bundledClientSecretBytes)
        if !bundled.isEmpty { return bundled }
        // Legacy Keychain override retained only as a migration/debug fallback.
        return Self.readKeychainString(account: Self.secretAccount) ?? ""
    }

    var isConfigured: Bool { !configuredClientID.isEmpty && !configuredClientSecret.isEmpty }
    var isConnected: Bool { withStateLock { tokenBundleCache != nil } }

    /// vBRDC202: explicit Sync/Connect recovery may re-read the persisted Keychain token
    /// once if startup could not hydrate the memory cache. This is not a new authorization
    /// flow and never deletes the saved account; it simply restores the already-linked
    /// device identity without bringing Keychain I/O back into ordinary SwiftUI reads.
    @discardableResult
    func restorePersistedConnectionIfNeeded() -> Bool {
        if isConnected { return true }
        // vBRDC203: OAuth identity lives in Keychain while the friendly account label lives
        // in UserDefaults. A profile restore/reinstall can legitimately preserve the token
        // while replacing defaults, so a missing display name must NEVER make a valid linked
        // device look disconnected. Recover the token first, then rebuild account identity
        // from Trakt's authenticated /users/settings endpoint.
        guard let raw = Self.readKeychainString(account: Self.tokenAccount),
              let data = raw.data(using: .utf8),
              let token = try? JSONDecoder().decode(TraktOAuthTokenBundle.self, from: data) else { return false }
        withStateLock { tokenBundleCache = token }
        if connectedAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set("Connected • verifying Trakt account…", forKey: Self.statusDefaultsKey)
        }
        return true
    }

    var accountIdentityVerified: Bool {
        let raw = UserDefaults.standard.double(forKey: Self.accountVerifiedDefaultsKey)
        return isConnected && raw > 0 && Date().timeIntervalSince1970 - raw < 7 * 24 * 60 * 60
    }

    /// vBRDC203: reconstructs the user-facing Trakt account identity from the OAuth token.
    /// This is deliberately independent of backup profile data: refresh tokens remain in
    /// Keychain and are never copied through restore codes, while the friendly account name
    /// can always be re-derived from Trakt. Network failure retains the linked token and the
    /// last-known-good label rather than silently disconnecting the user.
    @discardableResult
    func refreshConnectedAccountIdentityIfNeeded(force: Bool = false) async -> Bool {
        if !isConnected { _ = restorePersistedConnectionIfNeeded() }
        guard isConnected else { return false }

        let existingName = connectedAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedAt = UserDefaults.standard.double(forKey: Self.accountVerifiedDefaultsKey)
        let recentlyVerified = verifiedAt > 0 && Date().timeIntervalSince1970 - verifiedAt < 12 * 60 * 60
        if !force, !existingName.isEmpty, recentlyVerified { return true }

        if existingName.isEmpty {
            UserDefaults.standard.set("Connected • verifying Trakt account…", forKey: Self.statusDefaultsKey)
        }
        do {
            let account = try await fetchAccountName().trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = account.isEmpty ? "Trakt account" : account
            UserDefaults.standard.set(resolved, forKey: Self.accountDefaultsKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.accountVerifiedDefaultsKey)
            UserDefaults.standard.set("Connected as \(resolved) • Verified", forKey: Self.statusDefaultsKey)
            return true
        } catch {
            let retained = connectedAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            if retained.isEmpty {
                UserDefaults.standard.set("Connected • account verification pending", forKey: Self.statusDefaultsKey)
            } else {
                UserDefaults.standard.set("Connected as \(retained) • verification pending", forKey: Self.statusDefaultsKey)
            }
            return false
        }
    }

    /// vBRDC211: one explicit user-owned resync transaction. Restore a persisted Keychain
    /// session first, verify the account identity, then refresh playback progress. The older
    /// Settings button called refreshPlaybackProgress before restoring the token, which made
    /// the button a silent no-op after some restore/reinstall paths.
    @discardableResult
    func manualResyncFromSettings() async -> Bool {
        if !isConnected { _ = restorePersistedConnectionIfNeeded() }
        guard isConnected, isConfigured else {
            UserDefaults.standard.set("Trakt resync unavailable • reconnect account", forKey: Self.statusDefaultsKey)
            return false
        }
        guard isEnabled else {
            UserDefaults.standard.set("Trakt Resume Sync is Off", forKey: Self.statusDefaultsKey)
            return false
        }
        _ = await refreshConnectedAccountIdentityIfNeeded(force: true)
        let before = lastSyncDate
        await refreshPlaybackProgress(force: true)
        let after = lastSyncDate
        let advanced: Bool
        if let after {
            advanced = before.map { after > $0 } ?? true
        } else {
            advanced = false
        }
        if !advanced, !lastStatus.lowercased().contains("sync:") {
            UserDefaults.standard.set("Trakt resume sync verified • no newer progress", forKey: Self.statusDefaultsKey)
        }
        let succeeded = isConnected && !lastStatus.lowercased().hasPrefix("trakt sync:")
        if succeeded {
            let continueCount = cloudResumePointsSnapshot().filter { $0.progress >= 0.2 && $0.progress < 95 }.count
            let noun = continueCount == 1 ? "item" : "items"
            UserDefaults.standard.set("✓ Trakt resync complete • \(continueCount) Continue Playing \(noun) refreshed", forKey: Self.statusDefaultsKey)
        }
        return succeeded
    }

    var connectedAccountName: String {
        UserDefaults.standard.string(forKey: Self.accountDefaultsKey) ?? ""
    }

    var lastStatus: String {
        UserDefaults.standard.string(forKey: Self.statusDefaultsKey) ?? (isConnected ? "Connected" : "Not connected")
    }

    var lastSyncDate: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastSyncDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    func saveClientSecret(_ secret: String) -> Bool {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        return Self.writeKeychainString(clean, account: Self.secretAccount)
    }

    func clearClientSecret() {
        Self.deleteKeychainValue(account: Self.secretAccount)
    }

    func disconnect() {
        Self.deleteKeychainValue(account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.accountDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.accountVerifiedDefaultsKey)
        UserDefaults.standard.set("Disconnected", forKey: Self.statusDefaultsKey)
        lock.lock()
        tokenBundleCache = nil
        cloudResumePoints.removeAll(keepingCapacity: false)
        lastCheckpointAt.removeAll(keepingCapacity: false)
        lock.unlock()
        persistCloudResumeCache([])
    }

    func beginDeviceLink() async throws -> TraktDeviceLinkCode {
        let clientID = configuredClientID
        guard !clientID.isEmpty else { throw TraktSyncError.missingClientID }
        guard let url = URL(string: "https://auth.trakt.tv/oauth/device/code") else { throw TraktSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TraktSyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURL = json["verification_url"] as? String else {
            throw TraktSyncError.invalidResponse
        }
        let expires = (json["expires_in"] as? NSNumber)?.intValue ?? 600
        let interval = max(3, (json["interval"] as? NSNumber)?.intValue ?? 5)
        UserDefaults.standard.set("Waiting for Trakt authorization", forKey: Self.statusDefaultsKey)
        return TraktDeviceLinkCode(deviceCode: deviceCode, userCode: userCode, verificationURL: verificationURL, expiresIn: expires, interval: interval)
    }

    func pollDeviceAuthorization(_ code: TraktDeviceLinkCode) async throws -> String {
        let clientID = configuredClientID
        let clientSecret = configuredClientSecret
        guard !clientID.isEmpty else { throw TraktSyncError.missingClientID }
        guard !clientSecret.isEmpty else { throw TraktSyncError.missingClientSecret }
        guard let url = URL(string: "https://auth.trakt.tv/oauth/device/token") else { throw TraktSyncError.invalidURL }

        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = max(3, code.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code.deviceCode,
                "client_id": clientID,
                "client_secret": clientSecret
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let token = try decodeTokenBundle(data)
                guard storeTokenBundle(token) else { throw TraktSyncError.keychainFailure }
                let account = (try? await fetchAccountName()) ?? "Trakt account"
                UserDefaults.standard.set(account, forKey: Self.accountDefaultsKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.accountVerifiedDefaultsKey)
                UserDefaults.standard.set("Connected as \(account) • Verified", forKey: Self.statusDefaultsKey)
                await refreshPlaybackProgress(force: true)
                return account
            }
            switch status {
            case 400: continue
            case 429:
                interval += 2
                continue
            case 404: throw TraktSyncError.invalidDeviceCode
            case 409: throw TraktSyncError.deviceCodeAlreadyUsed
            case 410: throw TraktSyncError.deviceCodeExpired
            case 418: throw TraktSyncError.deviceCodeDenied
            default:
                let message = String(data: data, encoding: .utf8) ?? ""
                throw TraktSyncError.server(status, message)
            }
        }
        throw TraktSyncError.deviceCodeExpired
    }

    func refreshPlaybackProgressIfNeeded(force: Bool = false) {
        guard isEnabled, isConnected, isConfigured else { return }
        if !force, let lastSyncDate, Date().timeIntervalSince(lastSyncDate) < 300 { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.refreshPlaybackProgress(force: force)
        }
    }

    func refreshPlaybackProgress(force: Bool = false) async {
        guard isEnabled, isConnected, isConfigured else { return }
        if !force, let lastSyncDate, Date().timeIntervalSince(lastSyncDate) < 300 { return }
        let claimed = withStateLock { () -> Bool in
            guard !refreshInFlight else { return false }
            refreshInFlight = true
            return true
        }
        if !claimed {
            // A forced caller (notably the post-playback catalog refresh) must not race
            // past an in-flight pause-scrobble refresh and read the older cloud snapshot.
            if force {
                for _ in 0..<50 {
                    let stillRefreshing = withStateLock { refreshInFlight }
                    if !stillRefreshing { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return
        }
        defer {
            withStateLock { refreshInFlight = false }
        }
        do {
            let movieData = try await authenticatedGET(path: "/sync/playback/movies?extended=full")
            let episodeData = try await authenticatedGET(path: "/sync/playback/episodes?extended=full")
            var points = parseMoviePlayback(movieData)
            points.append(contentsOf: parseEpisodePlayback(episodeData))
            withStateLock { cloudResumePoints = points }
            persistCloudResumeCache(points)
            let imported = materializeCloudResumePoints(points)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncDefaultsKey)
            UserDefaults.standard.set(imported > 0 ? "Trakt resume sync updated • imported \(imported)" : "Trakt resume sync updated", forKey: Self.statusDefaultsKey)
        } catch {
            UserDefaults.standard.set("Trakt sync: \(error.localizedDescription)", forKey: Self.statusDefaultsKey)
        }
    }

    /// vBRDC197: Trakt playback progress becomes native Debrid Channels resume state.
    /// This is intentionally one-way per refresh and timestamp guarded by the local cache,
    /// so a stale Trakt checkpoint cannot roll a newer local position backwards.
    @discardableResult
    private func materializeCloudResumePoints(_ points: [TraktCloudResumePoint]) -> Int {
        // vBRDC202: construct the complete cloud snapshot first, then commit it to the
        // resume cache once. This replaces N synchronous whole-cache writes with one and
        // prevents timing-only Trakt records from erasing artwork already learned locally.
        var updates: [PlaybackResumeCacheManager.SyncedProgressUpdate] = []
        updates.reserveCapacity(points.count)

        for point in points where point.progress >= 0.2 && point.progress < 95 {
            let duration = point.durationSeconds
            let seconds = point.seconds
            guard duration > 0, seconds >= 8, point.pausedAt > .distantPast else { continue }

            let isEpisode = point.kind == "episode"
            let displayTitle = isEpisode ? (point.showTitle ?? point.title) : point.title
            guard !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let tmdb = isEpisode ? (point.showTMDBID ?? point.tmdbID) : point.tmdbID
            let imdb = isEpisode ? (point.showIMDbID ?? point.imdbID) : point.imdbID
            let stableID: String = {
                if let tmdb { return "trakt-cloud-\(isEpisode ? "show" : "movie")-tmdb-\(tmdb)" }
                if let imdb, !imdb.isEmpty { return "trakt-cloud-\(isEpisode ? "show" : "movie")-imdb-\(imdb)" }
                return "trakt-cloud-\(isEpisode ? "show" : "movie")-\(displayTitle.lowercased())"
            }()
            let item = MediaItem(
                id: stableID,
                tmdbId: tmdb.map(String.init),
                imdbId: imdb,
                tvdbId: nil,
                title: displayTitle,
                year: (isEpisode ? (point.showYear ?? point.year) : point.year).map(String.init) ?? "",
                type: isEpisode ? "series" : "movie",
                catalog: "Trakt",
                description: "",
                genres: [],
                rating: "",
                posterURL: nil,
                landscapeURL: nil,
                logoURL: nil,
                addonName: "Trakt",
                seasonNumber: point.season,
                episodeNumber: point.episode
            )
            updates.append(.init(
                item: item,
                seconds: seconds,
                duration: duration,
                updatedAt: point.pausedAt,
                artworkURL: nil
            ))
        }
        return PlaybackResumeCacheManager.shared.importSyncedProgressBatch(updates)
    }

    func cloudResumePointsSnapshot() -> [TraktCloudResumePoint] {
        lock.lock()
        let points = cloudResumePoints
        lock.unlock()
        return points
    }

    func cloudResumePoint(for item: MediaItem) -> TraktCloudResumePoint? {
        let points = cloudResumePointsSnapshot()
        return points.filter { matches($0, item: item) }.max { $0.pausedAt < $1.pausedAt }
    }

    func cloudResumeEntry(for item: MediaItem) -> PlaybackResumeEntry? {
        guard isEnabled, let point = cloudResumePoint(for: item), point.progress >= 0.2, point.progress < 95 else { return nil }
        let duration = point.durationSeconds
        guard duration > 0 else { return nil }
        let seconds = point.seconds
        guard seconds >= 8 else { return nil }
        return PlaybackResumeEntry(
            key: PlaybackResumeCacheManager.shared.playbackKey(for: item),
            title: item.title,
            type: item.type,
            catalog: item.catalog,
            year: item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? point.year.map(String.init) : item.year,
            tmdbId: item.tmdbId ?? (point.showTMDBID ?? point.tmdbID).map(String.init),
            imdbId: item.imdbId ?? point.showIMDbID ?? point.imdbID,
            tvdbId: item.tvdbId,
            season: item.seasonNumber ?? point.season,
            episode: item.episodeNumber ?? point.episode,
            seconds: seconds,
            duration: duration,
            updatedAt: point.pausedAt,
            artworkURL: item.landscapeURL ?? item.posterURL,
            posterArtworkURL: item.posterURL,
            landscapeArtworkURL: item.landscapeURL
        )
    }

    func checkpoint(item: MediaItem, seconds: Double, duration: Double, isPlaying: Bool, force: Bool = false) {
        guard isEnabled, isConnected, isConfigured, duration.isFinite, duration > 0, seconds.isFinite, seconds >= 8 else { return }
        let key = identityKey(for: item)
        let now = Date()
        lock.lock()
        let last = lastCheckpointAt[key] ?? .distantPast
        if !force, now.timeIntervalSince(last) < 60 { lock.unlock(); return }
        lastCheckpointAt[key] = now
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.scrobble(item: item, seconds: seconds, duration: duration, event: isPlaying ? .start : .pause)
                // Pause is the durable Trakt resume edge. Refresh the cloud snapshot only
                // after Trakt accepted it so another device/catalog sees the same position.
                if !isPlaying { await self.refreshPlaybackProgress(force: true) }
            } catch { }
        }
    }

    func playbackStateChanged(item: MediaItem, seconds: Double, duration: Double, isPlaying: Bool) {
        guard !item.type.lowercased().contains("live") else { return }
        checkpoint(item: item, seconds: seconds, duration: duration, isPlaying: isPlaying, force: true)
    }

    func markCompleted(item: MediaItem, duration: Double, deferProgressRefresh: Bool = false) {
        guard isEnabled, isConnected, isConfigured else { return }
        let seconds = max(1, duration)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.scrobble(item: item, seconds: seconds, duration: seconds, event: .stop, progressOverride: 100)
                if deferProgressRefresh {
                    self.withStateLock { self.deferredProgressRefreshNeeded = true }
                } else {
                    await self.refreshPlaybackProgress(force: true)
                }
            } catch { }
        }
    }

    /// vBRDC206: called after a new VOD presentation has a confirmed first frame.
    /// A short grace period keeps Trakt's two playback-list GETs away from decoder startup.
    func flushDeferredProgressRefreshAfterPlaybackStabilizes() {
        guard isEnabled, isConnected, isConfigured else { return }
        Task.detached(priority: .utility) { [weak self] in
            // Check after the grace period, not before it: the outgoing stop scrobble can
            // still be in flight when the incoming decoder produces its first frame.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let shouldRefresh = self.withStateLock { () -> Bool in
                guard self.deferredProgressRefreshNeeded else { return false }
                self.deferredProgressRefreshNeeded = false
                return true
            }
            guard shouldRefresh else { return }
            await self.refreshPlaybackProgress(force: true)
        }
    }

    func removeCloudResume(for item: MediaItem) {
        guard isEnabled, isConnected, isConfigured, let playbackID = cloudResumePoint(for: item)?.playbackID else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.authenticatedRequest(path: "/sync/playback/\(playbackID)", method: "DELETE", body: nil)
                await self.refreshPlaybackProgress(force: true)
            } catch { }
        }
    }

    /// vBRDC197: explicit Trakt Watchlist action for Media Information. Debrid Channels
    /// Favorites stays independent; this mutates only the connected Trakt account.
    func setWatchlist(item: MediaItem, add: Bool) async throws {
        guard isEnabled, isConnected, isConfigured else { throw TraktSyncError.notConnected }
        let lower = item.type.lowercased()
        let isShow = item.seasonNumber != nil || item.episodeNumber != nil || lower.contains("series") || lower.contains("show") || lower == "tv" || lower.contains("episode")
        var media: [String: Any] = ["title": isShow ? normalizedSeriesTitle(item.title) : item.title]
        if let year = Int(item.year) { media["year"] = year }
        var ids: [String: Any] = [:]
        if let imdb = cleanIMDb(item.imdbId) { ids["imdb"] = imdb }
        if let tmdb = cleanTMDB(item.tmdbId) { ids["tmdb"] = tmdb }
        if let tvdb = Int(item.tvdbId ?? "") { ids["tvdb"] = tvdb }
        if !ids.isEmpty { media["ids"] = ids }
        let payload: [String: Any] = [isShow ? "shows" : "movies": [media]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await authenticatedRequest(path: add ? "/sync/watchlist" : "/sync/watchlist/remove", method: "POST", body: body)
        TraktCatalogService.shared.setWatchlistState(for: item, enabled: add)
        UserDefaults.standard.set(add ? "Added to Trakt Watchlist" : "Removed from Trakt Watchlist", forKey: Self.statusDefaultsKey)
    }

    func publicStats(for item: MediaItem) async -> TraktTitleStats? {
        let clientID = configuredClientID
        guard !clientID.isEmpty else { return nil }
        let identifier = cleanIMDb(item.imdbId) ?? cleanTMDB(item.tmdbId).map(String.init) ?? item.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        guard let identifier, !identifier.isEmpty else { return nil }
        let isEpisode = item.seasonNumber != nil || item.episodeNumber != nil || item.type.lowercased().contains("series") || item.type.lowercased().contains("show")
        let path = isEpisode ? "/shows/\(identifier)/stats" : "/movies/\(identifier)/stats"
        do {
            guard let url = URL(string: "https://api.trakt.tv" + path) else { return nil }
            var request = URLRequest(url: url)
            request.setValue(Self.apiVersion, forHTTPHeaderField: "trakt-api-version")
            request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func integer(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }
            return TraktTitleStats(
                watchers: integer("watchers"),
                plays: integer("plays"),
                collectors: integer("collectors"),
                comments: integer("comments"),
                lists: integer("lists"),
                votes: integer("votes")
            )
        } catch {
            return nil
        }
    }

    // MARK: - Network

    private func scrobble(item: MediaItem, seconds: Double, duration: Double, event: TraktScrobbleEvent, progressOverride: Double? = nil) async throws {
        guard duration > 0 else { return }
        let progress = progressOverride ?? min(max((seconds / duration) * 100.0, 0), 100)
        var payload: [String: Any] = [
            "progress": progress,
            "app_version": Self.appVersion,
            "app_date": Self.appDate
        ]
        let isEpisode = item.seasonNumber != nil || item.episodeNumber != nil || item.type.lowercased().contains("episode")
        if isEpisode, let season = item.seasonNumber, let episode = item.episodeNumber {
            var show: [String: Any] = ["title": normalizedSeriesTitle(item.title)]
            if let year = Int(item.year) { show["year"] = year }
            var showIDs: [String: Any] = [:]
            if let imdb = cleanIMDb(item.imdbId), !imdb.isEmpty { showIDs["imdb"] = imdb }
            if let tvdb = Int(item.tvdbId ?? "") { showIDs["tvdb"] = tvdb }
            // Stremio episode rows often carry the show TMDB id; title+season+episode is
            // still included so Trakt can match even if a provider supplied an episode id.
            if let tmdb = cleanTMDB(item.tmdbId) { showIDs["tmdb"] = tmdb }
            if !showIDs.isEmpty { show["ids"] = showIDs }
            payload["show"] = show
            payload["episode"] = ["season": season, "number": episode]
        } else {
            var movie: [String: Any] = ["title": item.title]
            if let year = Int(item.year) { movie["year"] = year }
            var ids: [String: Any] = [:]
            if let imdb = cleanIMDb(item.imdbId) { ids["imdb"] = imdb }
            if let tmdb = cleanTMDB(item.tmdbId) { ids["tmdb"] = tmdb }
            if !ids.isEmpty { movie["ids"] = ids }
            payload["movie"] = movie
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await authenticatedRequest(path: "/scrobble/\(event.rawValue)", method: "POST", body: body)
    }

    private func authenticatedGET(path: String) async throws -> Data {
        try await authenticatedRequest(path: path, method: "GET", body: nil)
    }

    // vBRDC195: catalog/Spotlight consumers reuse the exact same OAuth/token-refresh
    // lane as resume sync. No second bearer-token owner is allowed.
    func catalogAuthenticatedGET(path: String) async throws -> Data {
        try await authenticatedGET(path: path)
    }

    func catalogPublicGET(path: String) async throws -> Data {
        let clientID = configuredClientID
        guard !clientID.isEmpty else { throw TraktSyncError.missingClientID }
        guard let url = URL(string: "https://api.trakt.tv" + path) else { throw TraktSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(Self.apiVersion, forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TraktSyncError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func authenticatedRequest(path: String, method: String, body: Data?) async throws -> Data {
        let clientID = configuredClientID
        guard !clientID.isEmpty else { throw TraktSyncError.missingClientID }
        let token = try await validAccessToken()
        guard let url = URL(string: "https://api.trakt.tv" + path) else { throw TraktSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.apiVersion, forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TraktSyncError.invalidResponse }
        if http.statusCode == 401 {
            let refreshed = try await refreshToken(force: true)
            guard !refreshed.isEmpty else { throw TraktSyncError.unauthorized }
            var retry = request
            retry.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
            let retryCode = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(retryCode) else { throw TraktSyncError.http(retryCode) }
            return retryData
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TraktSyncError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func validAccessToken() async throws -> String {
        guard let token = readTokenBundle() else { throw TraktSyncError.notConnected }
        let now = Date().timeIntervalSince1970
        if token.expiresAt - now > 300 { return token.accessToken }
        return try await refreshToken(force: true)
    }

    private func refreshToken(force: Bool) async throws -> String {
        guard let existing = readTokenBundle() else { throw TraktSyncError.notConnected }
        if !force, existing.expiresAt - Date().timeIntervalSince1970 > 300 { return existing.accessToken }

        if let inFlight = withStateLock({ tokenRefreshTask }) {
            return try await inFlight.value
        }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw TraktSyncError.notConnected }
            return try await self.performTokenRefresh(existing: existing)
        }
        let selectedTask: Task<String, Error> = withStateLock {
            if let inFlight = tokenRefreshTask { return inFlight }
            tokenRefreshTask = task
            return task
        }

        do {
            let access = try await selectedTask.value
            withStateLock { tokenRefreshTask = nil }
            return access
        } catch {
            withStateLock { tokenRefreshTask = nil }
            throw error
        }
    }

    private func performTokenRefresh(existing: TraktOAuthTokenBundle) async throws -> String {
        let clientID = configuredClientID
        let clientSecret = configuredClientSecret
        guard !clientID.isEmpty else { throw TraktSyncError.missingClientID }
        guard !clientSecret.isEmpty else { throw TraktSyncError.missingClientSecret }
        guard let url = URL(string: "https://auth.trakt.tv/oauth/token") else { throw TraktSyncError.invalidURL }
        let redirect = ProcessInfo.processInfo.environment["TRAKT_REDIRECT_URI"] ?? "urn:ietf:wg:oauth:2.0:oob"
        let payload: [String: Any] = [
            "refresh_token": existing.refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "refresh_token"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TraktSyncError.server(status, String(data: data, encoding: .utf8) ?? "") }
        let token = try decodeTokenBundle(data)
        guard storeTokenBundle(token) else { throw TraktSyncError.keychainFailure }
        return token.accessToken
    }

    private func fetchAccountName() async throws -> String {
        let data = try await authenticatedGET(path: "/users/settings")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Trakt account" }
        if let user = json["user"] as? [String: Any] {
            let name = (user["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = (user["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { return name }
            if !username.isEmpty { return username }
        }
        return "Trakt account"
    }

    private func decodeTokenBundle(_ data: Data) throws -> TraktOAuthTokenBundle {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { throw TraktSyncError.invalidResponse }
        return TraktOAuthTokenBundle(
            accessToken: access,
            refreshToken: refresh,
            tokenType: (json["token_type"] as? String) ?? "bearer",
            scope: (json["scope"] as? String) ?? "public",
            createdAt: (json["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970,
            expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 604800
        )
    }

    // MARK: - Playback parsing

    private func parseMoviePlayback(_ data: Data) -> [TraktCloudResumePoint] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { row in
            guard let progress = (row["progress"] as? NSNumber)?.doubleValue,
                  let movie = row["movie"] as? [String: Any] else { return nil }
            let ids = movie["ids"] as? [String: Any] ?? [:]
            return TraktCloudResumePoint(
                playbackID: (row["id"] as? NSNumber)?.intValue,
                kind: "movie",
                title: (movie["title"] as? String) ?? "",
                year: (movie["year"] as? NSNumber)?.intValue,
                showTitle: nil,
                showYear: nil,
                season: nil,
                episode: nil,
                imdbID: ids["imdb"] as? String,
                tmdbID: (ids["tmdb"] as? NSNumber)?.intValue,
                showIMDbID: nil,
                showTMDBID: nil,
                progress: progress,
                runtimeMinutes: (movie["runtime"] as? NSNumber)?.intValue,
                pausedAt: parseTraktDate(row["paused_at"] as? String) ?? Date.distantPast
            )
        }
    }

    private func parseEpisodePlayback(_ data: Data) -> [TraktCloudResumePoint] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { row in
            guard let progress = (row["progress"] as? NSNumber)?.doubleValue,
                  let episode = row["episode"] as? [String: Any],
                  let show = row["show"] as? [String: Any] else { return nil }
            let episodeIDs = episode["ids"] as? [String: Any] ?? [:]
            let showIDs = show["ids"] as? [String: Any] ?? [:]
            return TraktCloudResumePoint(
                playbackID: (row["id"] as? NSNumber)?.intValue,
                kind: "episode",
                title: (episode["title"] as? String) ?? "",
                year: nil,
                showTitle: show["title"] as? String,
                showYear: (show["year"] as? NSNumber)?.intValue,
                season: (episode["season"] as? NSNumber)?.intValue,
                episode: (episode["number"] as? NSNumber)?.intValue,
                imdbID: episodeIDs["imdb"] as? String,
                tmdbID: (episodeIDs["tmdb"] as? NSNumber)?.intValue,
                showIMDbID: showIDs["imdb"] as? String,
                showTMDBID: (showIDs["tmdb"] as? NSNumber)?.intValue,
                progress: progress,
                runtimeMinutes: (episode["runtime"] as? NSNumber)?.intValue,
                pausedAt: parseTraktDate(row["paused_at"] as? String) ?? Date.distantPast
            )
        }
    }

    private func matches(_ point: TraktCloudResumePoint, item: MediaItem) -> Bool {
        let itemIsEpisode = item.seasonNumber != nil || item.episodeNumber != nil || item.type.lowercased().contains("episode")
        guard itemIsEpisode == (point.kind == "episode") else { return false }
        if itemIsEpisode {
            guard point.season == item.seasonNumber, point.episode == item.episodeNumber else { return false }
            let itemIMDb = cleanIMDb(item.imdbId)
            if let itemIMDb, [point.showIMDbID, point.imdbID].compactMap({ $0 }).contains(itemIMDb) { return true }
            let itemTMDB = cleanTMDB(item.tmdbId)
            if let itemTMDB, [point.showTMDBID, point.tmdbID].compactMap({ $0 }).contains(itemTMDB) { return true }
            let lhs = normalizeTitle(normalizedSeriesTitle(item.title))
            let rhs = normalizeTitle(point.showTitle ?? point.title)
            return !lhs.isEmpty && lhs == rhs
        }
        if let itemIMDb = cleanIMDb(item.imdbId), itemIMDb == point.imdbID { return true }
        if let itemTMDB = cleanTMDB(item.tmdbId), itemTMDB == point.tmdbID { return true }
        guard normalizeTitle(item.title) == normalizeTitle(point.title) else { return false }
        let itemYear = Int(item.year)
        return itemYear == nil || point.year == nil || itemYear == point.year
    }

    private func identityKey(for item: MediaItem) -> String {
        if let imdb = cleanIMDb(item.imdbId) { return "imdb|\(imdb)|s\(item.seasonNumber ?? -1)|e\(item.episodeNumber ?? -1)" }
        if let tmdb = cleanTMDB(item.tmdbId) { return "tmdb|\(tmdb)|s\(item.seasonNumber ?? -1)|e\(item.episodeNumber ?? -1)" }
        return "title|\(normalizeTitle(item.title))|\(item.year)|s\(item.seasonNumber ?? -1)|e\(item.episodeNumber ?? -1)"
    }

    private func normalizedSeriesTitle(_ value: String) -> String {
        var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = title.range(of: #"\s+s\d{1,3}e\d{1,4}\b"#, options: [.regularExpression, .caseInsensitive]) {
            title = String(title[..<range.lowerBound])
        }
        return title
    }

    private func normalizeTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanIMDb(_ value: String?) -> String? {
        guard let value else { return nil }
        if let range = value.range(of: #"tt\d{5,12}"#, options: [.regularExpression, .caseInsensitive]) {
            return String(value[range]).lowercased()
        }
        return nil
    }

    private func cleanTMDB(_ value: String?) -> Int? {
        guard let value, let range = value.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(value[range])
    }

    private func parseTraktDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - Persistence / Keychain

    private func loadPersistedCloudResumeCache() {
        guard let url = Self.resumeCacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TraktCloudResumePoint].self, from: data) else { return }
        cloudResumePoints = decoded
    }

    private func persistCloudResumeCache(_ points: [TraktCloudResumePoint]) {
        guard let url = Self.resumeCacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(points)
            try data.write(to: url, options: .atomic)
        } catch { }
    }

    private func readTokenBundle() -> TraktOAuthTokenBundle? {
        withStateLock { tokenBundleCache }
    }

    private func storeTokenBundle(_ token: TraktOAuthTokenBundle) -> Bool {
        guard let data = try? JSONEncoder().encode(token), let raw = String(data: data, encoding: .utf8) else { return false }
        guard Self.writeKeychainString(raw, account: Self.tokenAccount) else { return false }
        withStateLock { tokenBundleCache = token }
        return true
    }

    private static func readKeychainString(account: String) -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
#else
        return UserDefaults.standard.string(forKey: "trakt.keychain.\(account)")
#endif
    }

    @discardableResult
    private static func writeKeychainString(_ value: String, account: String) -> Bool {
#if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
#else
        UserDefaults.standard.set(value, forKey: "trakt.keychain.\(account)")
        return true
#endif
    }

    private static func deleteKeychainValue(account: String) {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
#else
        UserDefaults.standard.removeObject(forKey: "trakt.keychain.\(account)")
#endif
    }
}

enum TraktSyncError: LocalizedError {
    case missingClientID
    case missingClientSecret
    case notConnected
    case invalidURL
    case invalidResponse
    case keychainFailure
    case unauthorized
    case invalidDeviceCode
    case deviceCodeAlreadyUsed
    case deviceCodeExpired
    case deviceCodeDenied
    case http(Int)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Trakt Client ID is not configured."
        case .missingClientSecret: return "Trakt Client Secret is not configured."
        case .notConnected: return "Trakt account is not connected."
        case .invalidURL: return "Trakt URL could not be created."
        case .invalidResponse: return "Trakt returned an invalid response."
        case .keychainFailure: return "Trakt credentials could not be stored securely."
        case .unauthorized: return "Trakt authorization expired. Reconnect the account."
        case .invalidDeviceCode: return "Trakt device code is invalid."
        case .deviceCodeAlreadyUsed: return "Trakt device code was already used."
        case .deviceCodeExpired: return "Trakt device code expired. Start linking again."
        case .deviceCodeDenied: return "Trakt authorization was denied."
        case .http(let code): return "Trakt request failed with HTTP \(code)."
        case .server(let code, let message):
            let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Trakt request failed with HTTP \(code)." : "Trakt HTTP \(code): \(String(clean.prefix(140)))"
        }
    }
}
