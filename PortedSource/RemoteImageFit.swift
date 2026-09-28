import SwiftUI
import UIKit
import ImageIO

/// vBRDC297: Nuvio-inspired global ImageIO gate. A fast network can otherwise
/// finish many poster requests at once and fan out into a burst of concurrent
/// thumbnail decodes. Limiting decode work protects the tvOS focus/compositor
/// thread while still allowing enough parallelism to keep visible rows warm.
private final class SignalArtworkDecodeGate: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init(maxConcurrent: Int) {
        semaphore = DispatchSemaphore(value: max(1, maxConcurrent))
    }

    func withPermit<T>(_ work: () -> T) -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return work()
    }
}

private let signalArtworkDecodeGate = SignalArtworkDecodeGate(maxConcurrent: 2)

/// Central artwork URL upgrader used before every image request.
/// v703: Premium decode path. Do not let SwiftUI/URLCache reuse low-res image entries,
/// and do not downsample artwork before the view displays it. TMDB gets /original/;
/// provider/Cinemeta/Stremio URLs stay intact so signed URLs and catalog art do not break.
enum PremiumArtworkURL {
    static func upgraded(_ input: String?) -> String? {
        guard var raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        if raw.hasPrefix("http://"), !isPrivateLocalHTTP(raw) {
            raw = raw.replacingOccurrences(of: "http://", with: "https://")
        }

        if raw.contains("image.tmdb.org/t/p/") {
            let tmdbSizes = ["/w45/", "/w92/", "/w154/", "/w185/", "/w300/", "/w342/", "/w500/", "/h632/", "/w780/", "/w1280/", "/original/"]
            for size in tmdbSizes where raw.contains(size) {
                raw = raw.replacingOccurrences(of: size, with: "/original/")
            }
            for size in ["w45", "w92", "w154", "w185", "w300", "w342", "w500", "h632", "w780", "w1280"] {
                raw = raw.replacingOccurrences(of: "/t/p/\(size)", with: "/t/p/original")
            }
        }

        // vBRDC315: restore the shared backend artwork byte cache. The direct-origin
        // experiment in v314 regressed poster readiness on hardware. Visible cards still use
        // display-sized local decode buckets; the backend simply gives every poster one
        // durable, deduplicated source-byte path before local caching.
        return sharedBackendArtworkURL(raw)
    }

    // vBRDC224 Phase 6 shared-cache hardening (built on vBRDC223 Phase 5): every public artwork request is routed
    // through the configured Debrid Channels backend. The backend downloads each unique
    // source once into its persistent shared cache, so one user's cache miss warms the
    // exact same asset for every other user. Backend/local URLs are never re-proxied.
    private static func sharedBackendArtworkURL(_ raw: String) -> String {
        guard let source = URL(string: raw), let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return raw }
        if isPrivateLocalHTTP(raw) { return raw }

        let configured = (UserDefaults.standard.string(forKey: "backendBaseURL") ?? "https://api.skylinejay187.it.com")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !configured.isEmpty, let backend = URL(string: configured), let backendHost = backend.host?.lowercased() else { return raw }
        if source.host?.lowercased() == backendHost { return raw }
        // vBRDC332: the official catalog has already saved immutable artwork in MinIO.
        // Sending its /assets/ URLs through Signal's *different* /api/image service
        // adds an extra upstream fetch and another cache key on every cold device.
        // Keep the authoritative catalog asset URL direct (the local-server case is
        // already handled above), so all clients share the same immutable object.
        let sourceHost = source.host?.lowercased() ?? ""
        if source.path.hasPrefix("/assets/"),
           (sourceHost == "catalog.skylinejay187.it.com" || sourceHost.hasSuffix(".catalog.debridchannels")) {
            return raw
        }

        guard var components = URLComponents(string: configured + "/api/image") else { return raw }
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        return components.url?.absoluteString ?? raw
    }

    private static func isPrivateLocalHTTP(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) { return true }
        return false
    }

    static func url(_ input: String?) -> URL? {
        guard let raw = upgraded(input), !raw.isEmpty else { return nil }
        if let direct = URL(string: raw), direct.scheme != nil { return direct }
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: encoded), url.scheme != nil { return url }
        return nil
    }

    /// vBRDC321: recover the public origin embedded by Signal's /api/image proxy.
    /// The backend remains the preferred shared byte-cache path, but a slow/unavailable
    /// image relay must never strand a visible poster or themed logo indefinitely.
    static func directOriginURL(from routedURL: URL) -> URL? {
        guard routedURL.path.hasSuffix("/api/image"),
              let components = URLComponents(url: routedURL, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let origin = URL(string: raw),
              let scheme = origin.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              !isPrivateLocalHTTP(raw) else { return nil }
        return origin
    }
}

// vBRDC091: artwork loaded by short-lived heavyweight surfaces must never evict the
// warm Home/Movies/Shows cache. Sports and Favorites get isolated decoded caches that
// are released on surface exit; persistent catalog/Live TV artwork keeps the donor cache.
enum PremiumArtworkCacheDomain: Hashable {
    case persistent
    case sports
    case favorites
}

private struct PremiumArtworkCacheDomainEnvironmentKey: EnvironmentKey {
    static let defaultValue: PremiumArtworkCacheDomain = .persistent
}

extension EnvironmentValues {
    var premiumArtworkCacheDomain: PremiumArtworkCacheDomain {
        get { self[PremiumArtworkCacheDomainEnvironmentKey.self] }
        set { self[PremiumArtworkCacheDomainEnvironmentKey.self] = newValue }
    }
}


/// vBRDC296: app-owned source-byte artwork cache.
///
/// URLCache is still kept as the normal HTTP cache, but it is not the source of truth for
/// warm posters anymore. Some artwork CDNs/proxies change cache headers or revalidate even
/// when the bytes are unchanged. This cache keys the final upgraded URL directly and stores
/// the original response bytes under Caches so a previously-seen poster can be decoded
/// locally on the next launch without another network round trip.
enum PersistentArtworkSourceCache {
    private static let queue = DispatchQueue(label: "com.debridchannels.artwork-source-cache", qos: .utility)
    private static let directoryName = "SignalArtworkSourceCache-v296"
    private static let byteLimit: Int64 = 768 * 1024 * 1024
    private static var writesSincePrune = 0
    // vBRDC297: do not turn every cache hit into a filesystem metadata write. The prior
    // implementation touched mtime on every read, serializing fast poster hits behind disk
    // attribute updates. Keep LRU usefulness with a coarse access touch instead.
    private static var lastTouchByPath: [String: Date] = [:]
    private static let accessTouchInterval: TimeInterval = 15 * 60

    private static func directoryURL() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func stableFileName(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx.art", hash)
    }

    private static func fileURL(for url: URL) -> URL? {
        directoryURL()?.appendingPathComponent(stableFileName(for: url), isDirectory: false)
    }

    static func read(_ url: URL, completion: @escaping (Data?) -> Void) {
        queue.async {
            guard let file = fileURL(for: url),
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  !data.isEmpty else {
                completion(nil)
                return
            }
            let now = Date()
            let lastTouch = lastTouchByPath[file.path] ?? .distantPast
            if now.timeIntervalSince(lastTouch) >= accessTouchInterval {
                lastTouchByPath[file.path] = now
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            }
            completion(data)
        }
    }

    static func data(for url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            read(url) { data in
                continuation.resume(returning: data)
            }
        }
    }

    static func remove(_ url: URL) {
        queue.async {
            guard let file = fileURL(for: url) else { return }
            try? FileManager.default.removeItem(at: file)
            lastTouchByPath.removeValue(forKey: file.path)
        }
    }

    static func write(_ data: Data, for url: URL) {
        guard !data.isEmpty else { return }
        queue.async {
            guard let file = fileURL(for: url) else { return }
            if !FileManager.default.fileExists(atPath: file.path) {
                try? data.write(to: file, options: [.atomic])
            } else {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            }
            writesSincePrune += 1
            if writesSincePrune >= 80 {
                writesSincePrune = 0
                pruneIfNeeded()
            }
        }
    }

    private static func pruneIfNeeded() {
        guard let directory = directoryURL(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        var entries: [(url: URL, bytes: Int64, date: Date)] = []
        entries.reserveCapacity(files.count)
        var total: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            total += bytes
            entries.append((file, bytes, values.contentModificationDate ?? .distantPast))
        }
        guard total > byteLimit else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
            if total <= byteLimit { break }
        }
    }
}

// vBRDC099: mounted catalog artwork gets a direct generation-based recovery signal after
// playback/foreground/surface handoffs. This intentionally is NOT an ObservableObject:
// publishing one global epoch through SwiftUI would invalidate every mounted artwork view
// at once and could recreate the very return/scroll hitch this recovery path is meant to fix.
// The coordinator talks directly to weakly registered loaders; healthy images are untouched.
@MainActor
final class PremiumArtworkRehydrationCoordinator {
    static let shared = PremiumArtworkRehydrationCoordinator()
    private var generation: UInt64 = 0

    private init() {}

    func force(reason: String) {
        generation &+= 1
        PremiumRemoteImageLoader.forceMountedBlankRehydration(reason: reason, generation: generation)
    }
}

@MainActor
final class PremiumRemoteImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published private(set) var imageURL: URL? = nil
    @Published var failed = false

    // vBRDC088: a single original source URL may legitimately be decoded at different
    // display budgets (small rail poster vs. focused card vs. full-screen hero). Keep the
    // decode bucket in every cache/in-flight key so a display-sized card bitmap can never
    // poison a full-resolution presentation that requests the same source URL.
    private struct LoadKey: Hashable {
        let url: URL
        let maxPixelSize: Int
        let domain: PremiumArtworkCacheDomain

        var cacheKey: NSString {
            "\(url.absoluteString)|decode=\(maxPixelSize)|domain=\(String(describing: domain))" as NSString
        }
    }

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Same 96 MB persistent process budget as the donor build. vBRDC088 makes high-churn card
        // entries display-sized, allowing more useful warm images inside the same ceiling.
        cache.countLimit = 220
        cache.totalCostLimit = 140 * 1024 * 1024
        return cache
    }()
    private static let sportsMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 28 * 1024 * 1024
        return cache
    }()
    private static let favoritesMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 28 * 1024 * 1024
        return cache
    }()

    // vBRDC099: playback may release the large persistent decode reservoir, but the exact
    // artwork visible immediately before playback is useful return-state. Snapshot only
    // mounted persistent card/hero owners into this small bounded cache so Home/Movies/Shows
    // can repaint synchronously on return without carrying the full 96 MB catalog cache.
    private static let playbackReturnMemoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 36
        cache.totalCostLimit = 28 * 1024 * 1024
        return cache
    }()

    private final class WeakBox {
        weak var value: PremiumRemoteImageLoader?
        init(_ value: PremiumRemoteImageLoader) { self.value = value }
    }
    private static var mountedLoaders: [WeakBox] = []

    private static func cache(for domain: PremiumArtworkCacheDomain) -> NSCache<NSString, UIImage> {
        switch domain {
        case .persistent: return memoryCache
        case .sports: return sportsMemoryCache
        case .favorites: return favoritesMemoryCache
        }
    }

    // vBRDC092: a popup/focused card may request a larger decode bucket than the same
    // artwork already visible on the row. Use that warm lower-resolution bitmap as an
    // immediate provisional frame, then replace it directly when the requested decode
    // finishes. This removes black/transparent reload flashes without lowering final quality.
    private static let reusableDecodeBuckets = [3072, 2560, 2048, 1600, 1280, 1024, 768, 640, 512, 384, 320]

    /// Nuvio-style decode bucketing: cards that request nearly the same pixel size
    /// should reuse one decoded bitmap instead of occupying separate cache entries.
    /// Full-screen Signal artwork keeps 2K/3K/4K buckets so this does not reduce quality.
    private static func normalizedDecodeBudget(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return 0 }
        let bounded = min(max(requested, 160), 3840)
        let buckets = [320, 384, 512, 640, 768, 1024, 1280, 1600, 2048, 2560, 3072, 3840]
        return buckets.first(where: { $0 >= bounded }) ?? 3840
    }

    private static func bestProvisionalCachedImage(
        url: URL,
        requestedMaxPixelSize: Int,
        domain: PremiumArtworkCacheDomain
    ) -> UIImage? {
        let candidates: [Int]
        if requestedMaxPixelSize == 0 {
            candidates = reusableDecodeBuckets
        } else {
            candidates = reusableDecodeBuckets.filter { $0 < requestedMaxPixelSize }
        }
        let domains: [PremiumArtworkCacheDomain] = domain == .persistent ? [.persistent] : [domain, .persistent]
        for candidateDomain in domains {
            for bucket in candidates {
                let candidate = LoadKey(url: url, maxPixelSize: bucket, domain: candidateDomain)
                if let image = cache(for: candidateDomain).object(forKey: candidate.cacheKey) { return image }
                if candidateDomain == .persistent,
                   let image = playbackReturnMemoryCache.object(forKey: candidate.cacheKey) { return image }
            }
        }
        return nil
    }
    private static var inFlightLoads: [LoadKey: [ObjectIdentifier: (UIImage?) -> Void]] = [:]
    private static var pendingSubscriberCancellationTasks: [LoadKey: Task<Void, Never>] = [:]
    private static var prefetchTasks: [URL: URLSessionDataTask] = [:]
    // vBRDC317 Phase 2: stable poster hydration queue. A catalog snapshot may request
    // more URLs than the two concurrent network slots. Keep the remaining identities queued
    // and pump them as slots finish instead of silently abandoning everything after URL #2.
    private static var pendingPrefetchURLs: [URL] = []
    private static var desiredPrefetchURLs: Set<URL> = []
    private static var prefetchOwnerTokens: [URL: UUID] = [:]
    private static var activeNetworkTasks: [LoadKey: URLSessionDataTask] = [:]
    private static var nonRetryableFailures: Set<LoadKey> = []
    // vBRDC092: detail artwork may be warmed after focus settles, but that speculative
    // decode must never survive into the next Siri Remote movement. Once a real view
    // subscribes to the key it stops being speculative and is allowed to finish.
    private static var idlePrewarmKeys: Set<LoadKey> = []
    private static var exclusivePlaybackActive = false
    private static let maxActivePrefetchTasks = 6
    private static let normalDecodedCacheLimitBytes = 140 * 1024 * 1024
    private static let exclusiveVODDecodedCacheLimitBytes = 32 * 1024 * 1024
    private static let imageSession: URLSession = {
        // vBRDC224 Phase 6: the backend shared artwork URLs are long-lived immutable objects.
        // Keep original bytes in URLCache across launches so a warm device avoids even the
        // inexpensive server round-trip, while decode-size bucketing below still prevents a
        // small decoded card bitmap from poisoning a hero/full-screen presentation.
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 1024 * 1024 * 1024,
            diskPath: "DebridChannelsArtwork-v1"
        )
        configuration.timeoutIntervalForRequest = 24
        configuration.timeoutIntervalForResource = 36
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()
    private var task: URLSessionDataTask?
    private var currentURL: URL?
    private var currentKey: LoadKey?
    // vBRDC090: decoded pixels may finish on the same frame as a Siri Remote move.
    // Cache them immediately, but defer the ObservableObject publication until focus
    // settles so artwork completion cannot steal the navigation frame budget.
    private var deferredPublicationTask: Task<Void, Never>?
    // vBRDC118: full-screen decorative artwork must not begin a new high-resolution
    // network/decode job for every fly-by card while Siri Remote geometry owns the frame.
    // Card/poster owners keep their immediate path; only explicit heavyweight callers opt in.
    private var deferredNavigationLoadTask: Task<Void, Never>?
    // vBRDC099: a transient CDN/DNS miss must not pin a mounted catalog card blank until
    // the user scrolls it away. Keep retries view-owned and bounded so cancellation still
    // follows normal SwiftUI lifecycle.
    private var transientRetryTask: Task<Void, Never>?
    private var transientRetryAttempt: Int = 0
    // vBRDC101: visible catalog hero/card/logo artwork is transition-critical. It may
    // publish during the bounded UNITY surface handoff while ordinary/background image
    // completions remain deferred. Navigation bursts and playback exclusivity still win.
    private var allowPublicationDuringSurfaceHandoff: Bool = false
    // vBRDC106: opt-in permission for visible VOD overlay/Cast Explorer artwork.
    // Default false keeps catalog/wallpaper/background image publication blocked while
    // full-screen playback owns the session.
    private var allowPublicationDuringPlayback: Bool = false
    // vBRDC123: opt-in for bounded artwork that is itself part of visible foreground
    // VOD UI (Cast Explorer, Featured Cast, episode browser, Up Next). Those surfaces must
    // never remain blank behind an indefinite navigation waiter. Ordinary/decorative VOD
    // artwork keeps the durable frame-budget path.
    private var forceVisiblePlaybackPublication: Bool = false

    init() {
        Self.mountedLoaders.removeAll { $0.value == nil }
        Self.mountedLoaders.append(WeakBox(self))
    }

    private static func snapshotMountedPersistentArtworkForPlaybackReturn(reason: String) {
        // Do not clear the rolling reservoir here. Catalog views may already have unmounted
        // (for example Home -> Live -> channel playback), and their recently decoded cards
        // are exactly what we want to keep for a later smooth catalog return.
        var retained: [WeakBox] = []
        retained.reserveCapacity(mountedLoaders.count)
        var captured = 0
        for box in mountedLoaders {
            guard let loader = box.value else { continue }
            retained.append(box)
            guard let key = loader.currentKey,
                  key.domain == .persistent,
                  key.maxPixelSize > 0,
                  key.maxPixelSize <= 1280,
                  let image = loader.image,
                  loader.imageURL == key.url else { continue }
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            playbackReturnMemoryCache.setObject(image, forKey: key.cacheKey, cost: cost)
            captured += 1
        }
        mountedLoaders = retained
        print("[ArtworkContinuity][vBRDC099] captured=\(captured) mounted=\(retained.count) reason=\(reason)")
    }

    /// vBRDC118 peak-smooth path for heavyweight full-screen artwork. Exact cached
    /// decodes still publish synchronously. A cache miss that arrives during active Siri
    /// Remote navigation retains the previous decoded frame and waits until navigation
    /// geometry releases ownership before starting URLSession/ImageIO work. Repeated focus
    /// moves replace this one pending request instead of creating/cancelling 4K decode jobs.
    func loadAfterNavigationSettles(
        _ url: URL?,
        preserveCurrentImage: Bool = true,
        maxPixelSize: Int? = nil,
        cacheDomain: PremiumArtworkCacheDomain = .persistent,
        allowPublicationDuringSurfaceHandoff: Bool = false,
        allowPublicationDuringPlayback: Bool = false,
        forceVisiblePlaybackPublication: Bool = false
    ) {
        deferredNavigationLoadTask?.cancel()
        deferredNavigationLoadTask = nil

        guard let url else {
            load(
                nil,
                preserveCurrentImage: preserveCurrentImage,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain,
                allowPublicationDuringSurfaceHandoff: allowPublicationDuringSurfaceHandoff,
                allowPublicationDuringPlayback: allowPublicationDuringPlayback,
                forceVisiblePlaybackPublication: forceVisiblePlaybackPublication
            )
            return
        }

        let decodeBudget = Self.normalizedDecodeBudget(maxPixelSize)
        let key = LoadKey(url: url, maxPixelSize: decodeBudget, domain: cacheDomain)
        let exactCached = Self.cache(for: key.domain).object(forKey: key.cacheKey) != nil
            || (key.domain == .persistent && Self.playbackReturnMemoryCache.object(forKey: key.cacheKey) != nil)

        // Cached pixels cost no network/decode budget, so keep single-step browsing crisp.
        if exactCached {
            load(
                url,
                preserveCurrentImage: preserveCurrentImage,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain,
                allowPublicationDuringSurfaceHandoff: allowPublicationDuringSurfaceHandoff,
                allowPublicationDuringPlayback: allowPublicationDuringPlayback,
                forceVisiblePlaybackPublication: forceVisiblePlaybackPublication
            )
            return
        }

        // A focus callback and the backdrop URL change can land on the same MainActor turn.
        // Yield once before deciding whether this is a navigation-owned frame so the focus
        // coordinator gets a chance to claim geometry first. Outside navigation this is only
        // a microtask delay; during a burst it prevents the first fly-by card from escaping
        // the heavyweight gate and starting a 4K decode.
        deferredNavigationLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }

            if UnityFrameRuntime.shared.snapshot.navigationActive {
                let permitted = await UnityFrameRuntime.shared.waitUntilPermitted(
                    .criticalArtwork,
                    maxWait: 1.80,
                    poll: 0.020
                )
                guard permitted, !Task.isCancelled else { return }
            }

            self.load(
                url,
                preserveCurrentImage: preserveCurrentImage,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain,
                allowPublicationDuringSurfaceHandoff: allowPublicationDuringSurfaceHandoff,
                allowPublicationDuringPlayback: allowPublicationDuringPlayback,
                forceVisiblePlaybackPublication: forceVisiblePlaybackPublication
            )
            self.deferredNavigationLoadTask = nil
        }
    }

    func load(
        _ url: URL?,
        preserveCurrentImage: Bool = false,
        maxPixelSize: Int? = nil,
        cacheDomain: PremiumArtworkCacheDomain = .persistent,
        allowPublicationDuringSurfaceHandoff: Bool = false,
        allowPublicationDuringPlayback: Bool = false,
        forceVisiblePlaybackPublication: Bool = false
    ) {
        self.allowPublicationDuringSurfaceHandoff = allowPublicationDuringSurfaceHandoff
        self.allowPublicationDuringPlayback = allowPublicationDuringPlayback
        self.forceVisiblePlaybackPublication = forceVisiblePlaybackPublication
        guard let url else {
            cancel()
            image = nil
            imageURL = nil
            failed = false
            currentURL = nil
            currentKey = nil
            return
        }
        let decodeBudget = Self.normalizedDecodeBudget(maxPixelSize)
        let key = LoadKey(url: url, maxPixelSize: decodeBudget, domain: cacheDomain)
        if currentKey == key, image != nil { return }

        let keyChanged = currentKey != key
        if keyChanged {
            transientRetryTask?.cancel()
            transientRetryTask = nil
            transientRetryAttempt = 0
        }

        if let previousKey = currentKey {
            Self.removeInFlightSubscriber(for: previousKey, owner: self)
        }
        deferredPublicationTask?.cancel()
        deferredPublicationTask = nil
        task = nil
        currentURL = url
        currentKey = key
        failed = false
        if !preserveCurrentImage {
            image = nil
            imageURL = nil
        }

        if let cached = Self.cache(for: key.domain).object(forKey: key.cacheKey) {
            imageURL = url
            image = cached
            transientRetryAttempt = 0
            return
        }
        if key.domain == .persistent,
           let cached = Self.playbackReturnMemoryCache.object(forKey: key.cacheKey) {
            let cost = cached.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            Self.memoryCache.setObject(cached, forKey: key.cacheKey, cost: cost)
            imageURL = url
            image = cached
            transientRetryAttempt = 0
            return
        }
        // vBRDC091: transient Sports/Favorites surfaces may reuse an already-warm
        // persistent catalog bitmap, but they never write their own new decode into the
        // persistent cache. This preserves fast entry without allowing those surfaces to
        // evict Home/Movies/Shows artwork.
        if key.domain != .persistent {
            let persistentKey = LoadKey(url: url, maxPixelSize: decodeBudget, domain: .persistent)
            if let cached = Self.memoryCache.object(forKey: persistentKey.cacheKey) {
                imageURL = url
                image = cached
                return
            }
        }

        // Show the already-decoded row/card image immediately while the larger requested
        // bucket upgrades in place. Do not return: the final decode still proceeds.
        if let provisional = Self.bestProvisionalCachedImage(
            url: url,
            requestedMaxPixelSize: decodeBudget,
            domain: key.domain
        ) {
            imageURL = url
            image = provisional
        }

        if Self.enqueueInFlightLoad(for: key, owner: self) { return }

        let startNetworkLoad: @MainActor () -> Void = { [weak self] in
            guard let self, self.currentKey == key, Self.inFlightLoads[key] != nil else { return }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 24
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS-PremiumArtwork/1.0", forHTTPHeaderField: "User-Agent")

            func completeArtworkLoad(data: Data, response: URLResponse?, request: URLRequest) {
                if let response {
                    Self.imageSession.configuration.urlCache?.storeCachedResponse(
                        CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                        for: request
                    )
                }
                // Keep the routed Signal key authoritative even when the bytes came from
                // the public-origin fallback. Future mounts therefore hit the same durable
                // local source cache and do not repeat either network path.
                PersistentArtworkSourceCache.write(data, for: url)
                let decoded = Self.decodedForDisplay(data: data, maxPixelSize: key.maxPixelSize)
                DispatchQueue.main.async {
                    Self.activeNetworkTasks.removeValue(forKey: key)
                    Self.nonRetryableFailures.remove(key)
                    Self.finishInFlightLoad(for: key, image: decoded)
                }
            }

            func failArtworkLoad(permanentClientFailure: Bool) {
                DispatchQueue.main.async {
                    Self.activeNetworkTasks.removeValue(forKey: key)
                    if permanentClientFailure {
                        if Self.nonRetryableFailures.count >= 256 { Self.nonRetryableFailures.removeAll(keepingCapacity: true) }
                        Self.nonRetryableFailures.insert(key)
                    } else {
                        Self.nonRetryableFailures.remove(key)
                    }
                    Self.finishInFlightLoad(for: key, image: nil)
                }
            }

            let networkTask = Self.imageSession.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode
                let valid = error == nil
                    && (status.map { (200...299).contains($0) } ?? true)
                    && (data?.isEmpty == false)

                if valid, let data {
                    completeArtworkLoad(data: data, response: response, request: request)
                    return
                }

                // vBRDC321: one bounded origin fallback. This specifically protects the
                // catalog/Spotlight path from a shared artwork-backend stall without
                // reverting v314's slower direct-first behavior.
                if let origin = PremiumArtworkURL.directOriginURL(from: url) {
                    var fallbackRequest = URLRequest(url: origin)
                    fallbackRequest.cachePolicy = .returnCacheDataElseLoad
                    fallbackRequest.timeoutInterval = 12
                    fallbackRequest.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    fallbackRequest.setValue("DebridChannels-tvOS-ArtworkOriginFallback/1.0", forHTTPHeaderField: "User-Agent")
                    let fallbackTask = Self.imageSession.dataTask(with: fallbackRequest) { fallbackData, fallbackResponse, fallbackError in
                        let fallbackStatus = (fallbackResponse as? HTTPURLResponse)?.statusCode
                        if fallbackError == nil,
                           fallbackStatus.map({ (200...299).contains($0) }) ?? true,
                           let fallbackData, !fallbackData.isEmpty {
                            completeArtworkLoad(data: fallbackData, response: fallbackResponse, request: fallbackRequest)
                        } else {
                            let permanent = fallbackStatus.map { (400...499).contains($0) && $0 != 408 && $0 != 429 } ?? false
                            failArtworkLoad(permanentClientFailure: permanent)
                        }
                    }
                    DispatchQueue.main.async {
                        guard Self.inFlightLoads[key] != nil else { fallbackTask.cancel(); return }
                        self.task = fallbackTask
                        Self.activeNetworkTasks[key] = fallbackTask
                        fallbackTask.resume()
                    }
                    return
                }

                let permanent = status.map { (400...499).contains($0) && $0 != 408 && $0 != 429 } ?? false
                failArtworkLoad(permanentClientFailure: permanent)
            }
            self.task = networkTask
            Self.activeNetworkTasks[key] = networkTask
            networkTask.resume()
        }

        // Check our own persistent byte cache off the MainActor before URLSession. A warm hit
        // does no networking and ImageIO decode remains on the utility queue.
        PersistentArtworkSourceCache.read(url) { data in
            if let data, !data.isEmpty {
                let decoded = Self.decodedForDisplay(data: data, maxPixelSize: key.maxPixelSize)
                if let decoded {
                    DispatchQueue.main.async {
                        guard Self.inFlightLoads[key] != nil else { return }
                        Self.nonRetryableFailures.remove(key)
                        Self.finishInFlightLoad(for: key, image: decoded)
                    }
                } else {
                    // A corrupt/truncated disk entry must not permanently win every
                    // future lookup and strand its card blank. Evict then refetch.
                    PersistentArtworkSourceCache.remove(url)
                    DispatchQueue.main.async { startNetworkLoad() }
                }
            } else {
                DispatchQueue.main.async { startNetworkLoad() }
            }
        }
    }

    func cancel() {
        deferredNavigationLoadTask?.cancel()
        deferredNavigationLoadTask = nil
        transientRetryTask?.cancel()
        transientRetryTask = nil
        transientRetryAttempt = 0
        if let key = currentKey {
            Self.removeInFlightSubscriber(for: key, owner: self)
        }
        deferredPublicationTask?.cancel()
        deferredPublicationTask = nil
        task = nil
        currentURL = nil
        currentKey = nil
        image = nil
        imageURL = nil
        failed = false
    }

    private func forceRehydrateCurrentIfBlank() {
        guard !Self.exclusivePlaybackActive,
              !VODExclusivePlaybackGate.isActive,
              image == nil,
              let key = currentKey,
              !Self.nonRetryableFailures.contains(key) else { return }
        // A playback/background cancellation can leave a mounted owner with a valid request
        // identity but no URLSession task. Restart exactly that request. In-flight work remains
        // deduplicated by LoadKey, and a real 4xx is deliberately not hammered again.
        failed = false
        load(
            key.url,
            preserveCurrentImage: true,
            maxPixelSize: key.maxPixelSize > 0 ? key.maxPixelSize : nil,
            cacheDomain: key.domain,
            allowPublicationDuringSurfaceHandoff: allowPublicationDuringSurfaceHandoff,
            allowPublicationDuringPlayback: allowPublicationDuringPlayback
        )
    }

    static func forceMountedBlankRehydration(reason: String, generation: UInt64) {
        guard !exclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return }
        var retained: [WeakBox] = []
        retained.reserveCapacity(mountedLoaders.count)
        var restarted = 0
        for box in mountedLoaders {
            guard let loader = box.value else { continue }
            retained.append(box)
            let before = loader.image
            loader.forceRehydrateCurrentIfBlank()
            if before == nil, loader.image == nil, loader.currentKey != nil { restarted += 1 }
        }
        mountedLoaders = retained
        print("[ArtworkRehydrate][vBRDC099] generation=\(generation) mounted=\(retained.count) blankCandidates=\(restarted) reason=\(reason)")
    }

    static func prefetch(_ urls: [URL], keeping keepAliveURLs: Set<URL> = []) {
        guard !exclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return }

        // Preserve caller order: current/visible posters are first, near-visible posters follow.
        var seen = Set<URL>()
        let ordered = urls.filter { seen.insert($0).inserted }
        let requested = Array(ordered.prefix(24))
        desiredPrefetchURLs = Set(requested).union(keepAliveURLs)

        cancelObsoletePrefetches(keeping: desiredPrefetchURLs)

        let active = Set(prefetchTasks.keys)
        pendingPrefetchURLs = requested.filter { !active.contains($0) }
        pumpPrefetchQueue()
    }

    private static func pumpPrefetchQueue() {
        guard !exclusivePlaybackActive, !VODExclusivePlaybackGate.isActive else { return }

        while prefetchTasks.count < maxActivePrefetchTasks, !pendingPrefetchURLs.isEmpty {
            let url = pendingPrefetchURLs.removeFirst()
            guard desiredPrefetchURLs.contains(url), prefetchTasks[url] == nil else { continue }

            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 18
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("DebridChannels-tvOS-PremiumArtworkPrefetch/1.0", forHTTPHeaderField: "User-Agent")

            let ownerToken = UUID()
            prefetchOwnerTokens[url] = ownerToken
            let task = Self.imageSession.dataTask(with: request) { data, response, error in
                // Persist bytes only for an active, still-requested prefetch generation.
                DispatchQueue.main.async {
                    guard prefetchOwnerTokens[url] == ownerToken else { return }
                    prefetchTasks.removeValue(forKey: url)
                    prefetchOwnerTokens.removeValue(forKey: url)
                    let status = (response as? HTTPURLResponse)?.statusCode
                    if desiredPrefetchURLs.contains(url),
                       error == nil,
                       status.map({ (200...299).contains($0) }) ?? true,
                       let data, !data.isEmpty, let response {
                        Self.imageSession.configuration.urlCache?.storeCachedResponse(
                            CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                            for: request
                        )
                        PersistentArtworkSourceCache.write(data, for: url)
                    } else if desiredPrefetchURLs.contains(url),
                              let origin = PremiumArtworkURL.directOriginURL(from: url) {
                        var fallback = URLRequest(url: origin)
                        fallback.cachePolicy = .returnCacheDataElseLoad
                        fallback.timeoutInterval = 10
                        let fallbackTask = Self.imageSession.dataTask(with: fallback) { fallbackData, fallbackResponse, fallbackError in
                            let fallbackStatus = (fallbackResponse as? HTTPURLResponse)?.statusCode
                            if fallbackError == nil,
                               fallbackStatus.map({ (200...299).contains($0) }) ?? true,
                               let fallbackData, !fallbackData.isEmpty {
                                PersistentArtworkSourceCache.write(fallbackData, for: url)
                            }
                            DispatchQueue.main.async { pumpPrefetchQueue() }
                        }
                        prefetchTasks[url] = fallbackTask
                        prefetchOwnerTokens[url] = ownerToken
                        fallbackTask.resume()
                        return
                    }
                    pumpPrefetchQueue()
                }
            }
            prefetchTasks[url] = task
            task.resume()
        }
    }

    /// vBRDC092: warm one exact presentation bucket without creating a view-owned loader.
    /// If the destination view mounts while this request is still running it subscribes to
    /// the same in-flight key rather than starting a duplicate network/decode operation.
    static func prewarm(
        _ url: URL?,
        maxPixelSize: Int,
        cacheDomain: PremiumArtworkCacheDomain = .persistent
    ) {
        guard !exclusivePlaybackActive, !VODExclusivePlaybackGate.isActive, let url else { return }
        let key = LoadKey(url: url, maxPixelSize: normalizedDecodeBudget(maxPixelSize), domain: cacheDomain)
        if cache(for: cacheDomain).object(forKey: key.cacheKey) != nil { return }
        if inFlightLoads[key] != nil || activeNetworkTasks[key] != nil { return }

        // Empty subscriber map marks a speculative in-flight decode. A view that arrives
        // later joins this map through enqueueInFlightLoad() and promotes it to required.
        inFlightLoads[key] = [:]
        idlePrewarmKeys.insert(key)
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 18
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS-DetailArtworkPrewarm/1.0", forHTTPHeaderField: "User-Agent")

        let task = imageSession.dataTask(with: request) { data, response, error in
            let decoded: UIImage?
            if error == nil, let data, !data.isEmpty {
                if let response {
                    imageSession.configuration.urlCache?.storeCachedResponse(
                        CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                        for: request
                    )
                }
                PersistentArtworkSourceCache.write(data, for: url)
                decoded = decodedForDisplay(data: data, maxPixelSize: key.maxPixelSize)
            } else {
                decoded = nil
            }
            DispatchQueue.main.async {
                activeNetworkTasks.removeValue(forKey: key)
                idlePrewarmKeys.remove(key)
                if let decoded {
                    let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                    cache(for: key.domain).setObject(decoded, forKey: key.cacheKey, cost: cost)
                }
                finishInFlightLoad(for: key, image: decoded)
            }
        }
        activeNetworkTasks[key] = task
        task.resume()
    }

    /// Cancel only speculative detail prewarms that no visible image loader has joined.
    /// Called at the start of a new navigation burst so high-resolution decode/network work
    /// cannot become a hidden source of frame loss while the user is scrolling again.
    static func cancelIdlePrewarmsForNavigation() {
        let keys = idlePrewarmKeys
        for key in keys {
            guard inFlightLoads[key]?.isEmpty == true else {
                idlePrewarmKeys.remove(key)
                continue
            }
            activeNetworkTasks[key]?.cancel()
            activeNetworkTasks.removeValue(forKey: key)
            pendingSubscriberCancellationTasks[key]?.cancel()
            pendingSubscriberCancellationTasks.removeValue(forKey: key)
            inFlightLoads.removeValue(forKey: key)
            idlePrewarmKeys.remove(key)
        }
    }

    static func beginExclusivePlayback() {
        snapshotMountedPersistentArtworkForPlaybackReturn(reason: "VOD playback entry")
        exclusivePlaybackActive = true
        for task in activeNetworkTasks.values { task.cancel() }
        activeNetworkTasks.removeAll()
        for task in pendingSubscriberCancellationTasks.values { task.cancel() }
        pendingSubscriberCancellationTasks.removeAll()
        inFlightLoads.removeAll()
        idlePrewarmKeys.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchOwnerTokens.removeAll()
        pendingPrefetchURLs.removeAll()
        desiredPrefetchURLs.removeAll()
        memoryCache.removeAllObjects()
        sportsMemoryCache.removeAllObjects()
        favoritesMemoryCache.removeAllObjects()
        memoryCache.totalCostLimit = exclusiveVODDecodedCacheLimitBytes
        print("[ReleaseStability][v1133] VOD entry released decoded artwork cache and reduced playback cache ceiling to 32 MB")
    }

    static func releaseDecodedArtworkForHiddenVODOverlay() {
        guard exclusivePlaybackActive || VODExclusivePlaybackGate.isActive else { return }

        // vBRDC159: VOD title logos are small playback-owned foreground assets. The chrome
        // can hide while their request is still in flight, but the SwiftUI owner remains
        // mounted; cancelling that request here can leave the owner permanently blank because
        // no new onAppear is guaranteed when chrome returns. Preserve only actively-subscribed
        // <=640px foreground work and continue cancelling every heavyweight/decorative request.
        let protectedForegroundKeys = Set(inFlightLoads.compactMap { key, subscribers in
            key.maxPixelSize > 0 && key.maxPixelSize <= 640 && !subscribers.isEmpty ? key : nil
        })
        let networkKeysToCancel = activeNetworkTasks.keys.filter { !protectedForegroundKeys.contains($0) }
        for key in networkKeysToCancel {
            activeNetworkTasks[key]?.cancel()
            activeNetworkTasks.removeValue(forKey: key)
        }
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchOwnerTokens.removeAll()
        pendingPrefetchURLs.removeAll()
        desiredPrefetchURLs.removeAll()

        let cancellationKeysToDrop = pendingSubscriberCancellationTasks.keys.filter { !protectedForegroundKeys.contains($0) }
        for key in cancellationKeysToDrop {
            pendingSubscriberCancellationTasks[key]?.cancel()
            pendingSubscriberCancellationTasks.removeValue(forKey: key)
        }
        let inFlightKeysToDrop = inFlightLoads.keys.filter { !protectedForegroundKeys.contains($0) }
        for key in inFlightKeysToDrop { inFlightLoads.removeValue(forKey: key) }
        print("[ReleaseStability][vBRDC159] hidden VOD overlay cancelled decorative artwork work while preserving active title-logo foreground loads")
    }

    static func endExclusivePlayback() {
        guard exclusivePlaybackActive else {
            memoryCache.totalCostLimit = normalDecodedCacheLimitBytes
            return
        }
        for task in pendingSubscriberCancellationTasks.values { task.cancel() }
        pendingSubscriberCancellationTasks.removeAll()
        // Entry already released heavyweight caches. Clearing again on exit races the
        // remounting catalog and can erase artwork that just finished during focus recovery.
        memoryCache.totalCostLimit = normalDecodedCacheLimitBytes
        exclusivePlaybackActive = false
    }

    static func suspendForBackground() {
        snapshotMountedPersistentArtworkForPlaybackReturn(reason: "scene inactive")
        // Background is a real lifecycle boundary. Cancel the underlying request owners too;
        // otherwise a request started before sleep can finish afterward and repopulate a cache
        // the app intentionally released. Foreground rehydration restarts only mounted blanks.
        for task in activeNetworkTasks.values { task.cancel() }
        activeNetworkTasks.removeAll()
        for task in pendingSubscriberCancellationTasks.values { task.cancel() }
        pendingSubscriberCancellationTasks.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchOwnerTokens.removeAll()
        pendingPrefetchURLs.removeAll()
        desiredPrefetchURLs.removeAll()
        inFlightLoads.removeAll()
        idlePrewarmKeys.removeAll()
        memoryCache.removeAllObjects()
        sportsMemoryCache.removeAllObjects()
        favoritesMemoryCache.removeAllObjects()
        print("[ArtworkLifecycle][vBRDC099] suspended all artwork request owners and released decoded cache")
    }

    static func handleMemoryPressure() {
        for task in pendingSubscriberCancellationTasks.values { task.cancel() }
        pendingSubscriberCancellationTasks.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchOwnerTokens.removeAll()
        pendingPrefetchURLs.removeAll()
        desiredPrefetchURLs.removeAll()
        memoryCache.removeAllObjects()
        sportsMemoryCache.removeAllObjects()
        favoritesMemoryCache.removeAllObjects()
        playbackReturnMemoryCache.removeAllObjects()
        nonRetryableFailures.removeAll(keepingCapacity: false)
        print("[ArtworkLifecycle][Phase7] released decoded artwork cache and prefetch work")
    }

    static func releaseTransientSurfaceResources(domain: PremiumArtworkCacheDomain, reason: String) {
        guard domain != .persistent else { return }

        let keys = activeNetworkTasks.keys.filter { $0.domain == domain }
        for key in keys {
            activeNetworkTasks[key]?.cancel()
            activeNetworkTasks.removeValue(forKey: key)
        }

        let pendingKeys = pendingSubscriberCancellationTasks.keys.filter { $0.domain == domain }
        for key in pendingKeys {
            pendingSubscriberCancellationTasks[key]?.cancel()
            pendingSubscriberCancellationTasks.removeValue(forKey: key)
        }

        let inFlightKeys = inFlightLoads.keys.filter { $0.domain == domain }
        for key in inFlightKeys {
            inFlightLoads.removeValue(forKey: key)
        }

        cache(for: domain).removeAllObjects()
        print("[ArtworkLifecycle][vBRDC091] released \(domain) transient surface artwork reason=\(reason)")
    }

    static func cancelObsoletePrefetches(keeping urlsToKeep: Set<URL>) {
        desiredPrefetchURLs = urlsToKeep
        pendingPrefetchURLs.removeAll { !urlsToKeep.contains($0) }
        let obsolete = prefetchTasks.keys.filter { !urlsToKeep.contains($0) }
        for url in obsolete {
            prefetchOwnerTokens.removeValue(forKey: url)
            prefetchTasks[url]?.cancel()
            prefetchTasks.removeValue(forKey: url)
        }
        pumpPrefetchQueue()
    }

    static func releaseDecodedArtworkForLiveTVPlayback() {
        snapshotMountedPersistentArtworkForPlaybackReturn(reason: "Live TV playback entry")
        for task in activeNetworkTasks.values { task.cancel() }
        activeNetworkTasks.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        prefetchOwnerTokens.removeAll()
        pendingPrefetchURLs.removeAll()
        desiredPrefetchURLs.removeAll()
        for task in pendingSubscriberCancellationTasks.values { task.cancel() }
        pendingSubscriberCancellationTasks.removeAll()
        inFlightLoads.removeAll()
        memoryCache.removeAllObjects()
        sportsMemoryCache.removeAllObjects()
        favoritesMemoryCache.removeAllObjects()
        print("[LiveTVMemory][v975] released decoded artwork cache for full-screen Live TV playback")
    }

    private static func enqueueInFlightLoad(for key: LoadKey, owner: PremiumRemoteImageLoader) -> Bool {
        pendingSubscriberCancellationTasks[key]?.cancel()
        pendingSubscriberCancellationTasks.removeValue(forKey: key)
        let ownerID = ObjectIdentifier(owner)
        let callback: (UIImage?) -> Void = { [weak owner] decoded in
            guard let owner, owner.currentKey == key else { return }
            if let decoded {
                let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                cache(for: key.domain).setObject(decoded, forKey: key.cacheKey, cost: cost)
                // Keep a small rolling set of recent catalog-card decodes even after those
                // views unmount. This covers Home -> Live -> playback -> Home as well as VOD
                // return without retaining full-screen/original artwork during playback.
                if key.domain == .persistent, key.maxPixelSize > 0, key.maxPixelSize <= 1280 {
                    playbackReturnMemoryCache.setObject(decoded, forKey: key.cacheKey, cost: cost)
                }
            }
            owner.publishDecodedImage(decoded, for: key)
        }

        if inFlightLoads[key] != nil {
            inFlightLoads[key]?[ownerID] = callback
            idlePrewarmKeys.remove(key)
            return true
        }
        inFlightLoads[key] = [ownerID: callback]
        return false
    }

    private func publishDecodedImage(_ decoded: UIImage?, for key: LoadKey) {
        deferredPublicationTask?.cancel()
        deferredPublicationTask = nil

        let apply: @MainActor () -> Void = { [weak self] in
            guard let self, self.currentKey == key else { return }
            if let decoded {
                self.imageURL = key.url
                self.image = decoded
                self.failed = false
                self.transientRetryAttempt = 0
                self.transientRetryTask?.cancel()
                self.transientRetryTask = nil
            } else {
                self.imageURL = nil
                self.failed = true
                self.scheduleTransientRetryIfNeeded(for: key)
            }
        }

        guard UnityAnimationCoordinator.shared.shouldDeferVisualPublication(
            allowDuringSurfaceHandoff: allowPublicationDuringSurfaceHandoff,
            allowDuringPlayback: allowPublicationDuringPlayback
        ) else {
            apply()
            return
        }

        deferredPublicationTask = Task { @MainActor [weak self] in
            // vBRDC102: decoded image publication no longer owns a private 35 ms polling
            // clock or force-publishes after 350 ms. It joins the exact same frame lane as
            // navigation/UNITY. Obsolete owners cancel naturally as focus changes.
            guard let self else { return }
            let lane: UnityFrameRuntime.Lane
            if self.allowPublicationDuringPlayback {
                lane = .playbackArtwork
            } else if self.allowPublicationDuringSurfaceHandoff {
                lane = .criticalArtwork
            } else {
                lane = .backgroundPrefetch
            }
            let permitted: Bool
            if self.forceVisiblePlaybackPublication && self.allowPublicationDuringPlayback {
                // vBRDC123: bounded foreground VOD artwork gets a short courtesy wait for
                // active Siri Remote geometry, then paints anyway instead of remaining blank.
                // Callers cap decode size and are explicit visible UI, so this cannot unleash
                // full-screen/decorative 4K publication during playback.
                permitted = await UnityFrameRuntime.shared.waitUntilPermitted(
                    lane,
                    // vBRDC159: Source Intelligence -> player handoff can legitimately
                    // outlive the old 450 ms window. Visible 640px title logos keep their
                    // decoded result pending through that handoff instead of silently
                    // missing the only publication opportunity.
                    maxWait: 1.80,
                    poll: 0.020
                )
            } else {
                permitted = await UnityFrameRuntime.shared.waitUntilPermittedDurably(lane)
            }
            guard !Task.isCancelled, self.currentKey == key else {
                self.deferredPublicationTask = nil
                return
            }
            let runtime = UnityFrameRuntime.shared.snapshot
            if permitted || (self.forceVisiblePlaybackPublication
                              && self.allowPublicationDuringPlayback
                              && runtime.sceneActive
                              && runtime.playbackActive
                              && !runtime.trailerActive) {
                // vBRDC293: once the frame coordinator grants publication, publish
                // immediately. v292's extra randomized delay made visible rows feel sticky
                // even though it reduced same-frame completion bursts.
                apply()
            }
            self.deferredPublicationTask = nil
        }
    }

    private func scheduleTransientRetryIfNeeded(for key: LoadKey) {
        guard currentKey == key,
              image == nil,
              transientRetryAttempt < 2,
              !Self.nonRetryableFailures.contains(key),
              (allowPublicationDuringPlayback || (!Self.exclusivePlaybackActive && !VODExclusivePlaybackGate.isActive)) else { return }

        transientRetryTask?.cancel()
        transientRetryAttempt += 1
        let delay: UInt64 = transientRetryAttempt == 1 ? 500_000_000 : 1_400_000_000
        transientRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.currentKey == key,
                  self.image == nil,
                  (self.allowPublicationDuringPlayback || (!Self.exclusivePlaybackActive && !VODExclusivePlaybackGate.isActive)) else { return }
            self.failed = false
            self.load(
                key.url,
                preserveCurrentImage: true,
                maxPixelSize: key.maxPixelSize > 0 ? key.maxPixelSize : nil,
                cacheDomain: key.domain,
                allowPublicationDuringSurfaceHandoff: self.allowPublicationDuringSurfaceHandoff,
                allowPublicationDuringPlayback: self.allowPublicationDuringPlayback,
                forceVisiblePlaybackPublication: self.forceVisiblePlaybackPublication
            )
        }
    }

    private static func removeInFlightSubscriber(for key: LoadKey, owner: PremiumRemoteImageLoader) {
        guard var subscribers = inFlightLoads[key] else { return }
        subscribers.removeValue(forKey: ObjectIdentifier(owner))
        guard subscribers.isEmpty else {
            inFlightLoads[key] = subscribers
            return
        }

        inFlightLoads[key] = subscribers
        pendingSubscriberCancellationTasks[key]?.cancel()
        pendingSubscriberCancellationTasks[key] = Task { @MainActor in
            let grace: UInt64 = UnityFrameRuntime.shared.snapshot.navigationActive ? 60_000_000 : 160_000_000
            try? await Task.sleep(nanoseconds: grace)
            guard !Task.isCancelled, inFlightLoads[key]?.isEmpty == true else {
                pendingSubscriberCancellationTasks[key] = nil
                return
            }
            inFlightLoads.removeValue(forKey: key)
            activeNetworkTasks[key]?.cancel()
            activeNetworkTasks.removeValue(forKey: key)
            pendingSubscriberCancellationTasks[key] = nil
        }
    }

    private static func finishInFlightLoad(for key: LoadKey, image: UIImage?) {
        pendingSubscriberCancellationTasks[key]?.cancel()
        pendingSubscriberCancellationTasks.removeValue(forKey: key)
        guard let callbacks = inFlightLoads.removeValue(forKey: key) else { return }
        callbacks.values.forEach { $0(image) }
    }

    nonisolated private static func decodedForDisplay(data: Data, maxPixelSize: Int) -> UIImage? {
        signalArtworkDecodeGate.withPermit {
            autoreleasepool {
                if maxPixelSize > 0,
                   let imageSource = CGImageSourceCreateWithData(data as CFData, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
                    }
                }

                // Full-screen/default callers preserve donor behavior exactly. Also serves as a
                // compatibility fallback for formats ImageIO cannot thumbnail directly.
                guard let source = UIImage(data: data) else { return nil }
                guard source.cgImage != nil else { return source }
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = source.scale
                format.opaque = false
                let renderer = UIGraphicsImageRenderer(size: source.size, format: format)
                return renderer.image { _ in
                    source.draw(in: CGRect(origin: .zero, size: source.size))
                }
            }
        }
    }

    static var releaseStabilityActiveWorkCount: Int {
        activeNetworkTasks.count + prefetchTasks.count + inFlightLoads.count
    }

    static var releaseStabilityDecodedCacheLimitBytes: Int {
        exclusivePlaybackActive ? exclusiveVODDecodedCacheLimitBytes : normalDecodedCacheLimitBytes
    }

    deinit {
        deferredNavigationLoadTask?.cancel()
        transientRetryTask?.cancel()
        task = nil
    }
}


private struct RemoteImageFitAspectModifier: ViewModifier {
    let mode: RemoteImageFit.Mode

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .fill:
            content.scaledToFill()
        case .fit:
            content.scaledToFit()
        case .stretch:
            content
        }
    }
}

struct RemoteImageFit: View {
    enum Mode { case fill, fit, stretch }
    let url: String?
    var mode: Mode = .fill
    var showPlaceholder: Bool = true
    // Optional display decode budget. nil keeps the donor's original-resolution decode.
    // High-churn card surfaces set a generous cap above their rendered size in vBRDC088.
    var maxPixelSize: Int? = nil
    // vBRDC021: opt-in only. Keeps the previous decoded frame visible while a new URL
    // is downloaded/decoded, then swaps directly to the ready replacement.
    var preservePreviousOnURLChange: Bool = false
    // vBRDC101: opt-in for visible hero/card/logo layers that must be allowed to paint
    // while the outer UNITY branch itself is animating. All other exclusivity rules remain.
    var publishDuringSurfaceHandoff: Bool = false
    // vBRDC106: opt-in only for artwork that is part of visible playback UI. The default
    // remains false so catalog/wallpaper/background images still yield to full-screen video.
    var publishDuringPlayback: Bool = false
    // vBRDC123: bounded foreground VOD UI only. After a short navigation courtesy wait,
    // visible artwork may publish so an event-gate stall cannot leave blank cards.
    var forceVisiblePlaybackPublication: Bool = false
    // vBRDC118: opt-in for large decorative backdrops. During a D-pad burst, keep the
    // current pixels and delay only a cache-miss network/decode start until geometry settles.
    // Small cards/logos remain immediate and therefore keep the exact current focus feel.
    var deferHeavyLoadDuringNavigation: Bool = false
    // Called only when the loader has actually committed a decoded bitmap for the requested URL.
    // Featured Cast uses this to keep the visible name/role/select identity paired with the
    // retained portrait until the replacement portrait is genuinely on screen.
    var onDisplayedURLChange: ((URL?) -> Void)? = nil
    // vBRDC108: optional text is a *true failure fallback*, never a resident underlay.
    // This is used by Live TV logos so a transparent PNG cannot reveal a duplicate generic
    // text logo underneath it. While a real URL is loading the slot stays clear; text appears
    // only when there is no usable URL or the image loader has definitively failed.
    var fallbackText: String? = nil

    @StateObject private var loader = PremiumRemoteImageLoader()
    @Environment(\.premiumArtworkCacheDomain) private var cacheDomain

    private var resolvedURL: URL? {
        PremiumArtworkURL.url(url)
    }

    private func requestLoad(
        _ resolvedURL: URL?,
        preserveCurrentImage: Bool,
        maxPixelSize: Int?,
        cacheDomain: PremiumArtworkCacheDomain
    ) {
        if deferHeavyLoadDuringNavigation {
            loader.loadAfterNavigationSettles(
                resolvedURL,
                preserveCurrentImage: preserveCurrentImage,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain,
                allowPublicationDuringSurfaceHandoff: publishDuringSurfaceHandoff,
                allowPublicationDuringPlayback: publishDuringPlayback,
                forceVisiblePlaybackPublication: forceVisiblePlaybackPublication
            )
        } else {
            loader.load(
                resolvedURL,
                preserveCurrentImage: preserveCurrentImage,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain,
                allowPublicationDuringSurfaceHandoff: publishDuringSurfaceHandoff,
                allowPublicationDuringPlayback: publishDuringPlayback,
                forceVisiblePlaybackPublication: forceVisiblePlaybackPublication
            )
        }
    }

    var body: some View {
        Group {
            if let image = loader.image, preservePreviousOnURLChange || loader.imageURL == resolvedURL {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .modifier(RemoteImageFitAspectModifier(mode: mode))
                    // vBRDC023: the seamless catalog path already retains the old decoded
                    // frame until the replacement is ready. Do not then fade the ready
                    // replacement from transparent; that final opacity transition was the
                    // remaining small brightness flash seen on physical Apple TV.
                    .transition(preservePreviousOnURLChange ? .identity : .opacity)
            } else {
                placeholder(showSpinner: !loader.failed && resolvedURL != nil)
            }
        }
        .clipped()
        .animation(preservePreviousOnURLChange ? nil : .easeInOut(duration: 0.18), value: loader.imageURL)
        .onAppear {
            // Preserve the donor's mount semantics: a fresh mount starts from its own
            // request state. Retained-frame continuity remains an URL-change behavior.
            requestLoad(
                resolvedURL,
                preserveCurrentImage: false,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain
            )
        }
        .onChange(of: resolvedURL) { newValue in
            requestLoad(
                newValue,
                preserveCurrentImage: preservePreviousOnURLChange,
                maxPixelSize: maxPixelSize,
                cacheDomain: cacheDomain
            )
        }
        .onChange(of: maxPixelSize) { newValue in
            requestLoad(
                resolvedURL,
                preserveCurrentImage: preservePreviousOnURLChange,
                maxPixelSize: newValue,
                cacheDomain: cacheDomain
            )
        }
        .onChange(of: cacheDomain) { newDomain in
            requestLoad(
                resolvedURL,
                preserveCurrentImage: preservePreviousOnURLChange,
                maxPixelSize: maxPixelSize,
                cacheDomain: newDomain
            )
        }
        .onChange(of: loader.imageURL) { _, newValue in
            onDisplayedURLChange?(newValue)
        }
        .onDisappear { loader.cancel() }
    }

    private func placeholder(showSpinner: Bool) -> some View {
        ZStack {
            if let fallbackText,
               !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               resolvedURL == nil || loader.failed {
                Text(fallbackText)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.30)
            } else if showPlaceholder {
                LinearGradient(colors: [.black.opacity(0.92), .gray.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if showSpinner {
                    ProgressView().scaleEffect(0.78).opacity(0.30)
                }
            } else {
                Color.clear
            }
        }
    }
}
