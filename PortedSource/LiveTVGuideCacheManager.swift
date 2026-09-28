import Foundation


struct LiveTVPersistedGuideSnapshot: Sendable {
    let channels: [LiveTVLoadedChannel]
    let guide: [String: [LiveProgram]]
}

// v783 Architecture Migration Step 9
// Centralizes Live TV lineup + guide cache persistence/refresh timing so the
// LiveTVSourceModel can keep owning provider loading and UI state only.
final class LiveTVGuideCacheManager {
    static let channelCacheKey = "liveTVLoadedChannelsV165"
    static let guideCacheKey = "liveTVGuideProgramsV191"
    static let lastRefreshKey = "liveTVLastRefreshV191"
    static let lastHealthyGuideKey = "liveTVLastHealthyGuideV322"
    static let channelCacheFileName = "liveTVLoadedChannelsV165.json"
    static let guideCacheFileName = "liveTVGuideProgramsV191.json"

    // vBRDC119: Live TV can persist tens of thousands of channels/program rows. The old
    // implementation JSON-encoded and atomically wrote those snapshots synchronously from
    // LiveTVSourceModel's MainActor. That made an otherwise-complete guide refresh capable
    // of stealing several animation frames. One utility queue now owns all large-state IO,
    // while pending snapshots are coalesced so an Xtream batch burst writes the newest state
    // instead of building a backlog of obsolete encodes.
    private static let persistenceQueue = DispatchQueue(label: "com.debridchannels.livetv-guide-cache", qos: .utility)
    private static let persistenceLock = NSLock()
    private static var pendingChannels: [LiveTVLoadedChannel]?
    private static var pendingGuide: (guide: [String: [LiveProgram]], maxRows: Int)?
    private static var channelWorkerScheduled = false
    private static var guideWorkerScheduled = false

    let refreshTTL: TimeInterval

    init(refreshTTL: TimeInterval = 3 * 60 * 60) {
        self.refreshTTL = refreshTTL
    }

    var shouldRefreshNow: Bool {
        let last = UserDefaults.standard.double(forKey: Self.lastRefreshKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= refreshTTL
    }

    func markRefreshed(_ date: Date = Date()) {
        let stamp = date.timeIntervalSince1970
        UserDefaults.standard.set(stamp, forKey: Self.lastRefreshKey)
        UserDefaults.standard.set(stamp, forKey: Self.lastHealthyGuideKey)
    }

    var lastHealthyGuideDate: Date? {
        let stamp = UserDefaults.standard.double(forKey: Self.lastHealthyGuideKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    func resetRefreshClock() {
        UserDefaults.standard.removeObject(forKey: Self.lastRefreshKey)
    }

    func loadChannelSnapshots() -> [LiveTVLoadedChannel]? {
        // Atomic file replacement lets readers consume the last complete snapshot without
        // waiting behind an in-flight large guide encode on the utility writer queue.
        let data = Self.loadLargeStateDataUnlocked(defaultsKey: Self.channelCacheKey, fileName: Self.channelCacheFileName)
        guard let data,
              let saved = try? JSONDecoder().decode([LiveTVLoadedChannel].self, from: data),
              !saved.isEmpty else { return nil }
        return saved
    }

    func persistChannels(_ channels: [LiveTVLoadedChannel]) {
        var shouldSchedule = false
        Self.persistenceLock.lock()
        Self.pendingChannels = channels
        if !Self.channelWorkerScheduled {
            Self.channelWorkerScheduled = true
            shouldSchedule = true
        }
        Self.persistenceLock.unlock()

        guard shouldSchedule else { return }
        Self.persistenceQueue.async {
            Self.drainChannelWrites()
        }
    }

    func loadGuidePrograms() -> [String: [LiveProgram]]? {
        let data = Self.loadLargeStateDataUnlocked(defaultsKey: Self.guideCacheKey, fileName: Self.guideCacheFileName)
        guard let data,
              let cached = try? JSONDecoder().decode([String: [CachedLiveProgram]].self, from: data) else { return nil }
        let restored = cached.mapValues { $0.map(\.liveProgram) }
        return restored.isEmpty ? nil : restored
    }


    /// vBRDC203: persisted EPG payloads can be very large. Read + JSON-decode both lineup
    /// and guide on the same utility lane that owns their writes so LiveTVSourceModel never
    /// blocks tvOS MainActor while restoring a multi-megabyte Gracenote/XMLTV snapshot.
    func loadPersistedStateAsync() async -> LiveTVPersistedGuideSnapshot? {
        await withCheckedContinuation { continuation in
            Self.persistenceQueue.async {
                let channels = self.loadChannelSnapshots() ?? []
                let guide = self.loadGuidePrograms() ?? [:]
                guard !channels.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: LiveTVPersistedGuideSnapshot(channels: channels, guide: guide))
            }
        }
    }

    func persistGuidePrograms(_ guide: [String: [LiveProgram]], maxRows: Int) {
        var shouldSchedule = false
        Self.persistenceLock.lock()
        Self.pendingGuide = (guide, maxRows)
        if !Self.guideWorkerScheduled {
            Self.guideWorkerScheduled = true
            shouldSchedule = true
        }
        Self.persistenceLock.unlock()

        guard shouldSchedule else { return }
        Self.persistenceQueue.async {
            Self.drainGuideWrites()
        }
    }

    static func clearPersistedCache() {
        // Cancel any not-yet-encoded snapshots first. `sync` then waits behind an encode that
        // is already in flight, so the final operation is guaranteed to be the clear rather
        // than a stale write resurrecting the previous provider mode afterward.
        persistenceLock.lock()
        pendingChannels = nil
        pendingGuide = nil
        persistenceLock.unlock()

        persistenceQueue.sync {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: channelCacheKey)
            defaults.removeObject(forKey: guideCacheKey)
            defaults.removeObject(forKey: lastRefreshKey)
            defaults.removeObject(forKey: lastHealthyGuideKey)
            removeLargeStateFile(named: channelCacheFileName)
            removeLargeStateFile(named: guideCacheFileName)
        }
    }

    private static func drainChannelWrites() {
        while true {
            persistenceLock.lock()
            guard let snapshot = pendingChannels else {
                channelWorkerScheduled = false
                persistenceLock.unlock()
                return
            }
            pendingChannels = nil
            persistenceLock.unlock()

            guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else {
                saveLargeStateDataUnlocked(Data(), defaultsKey: channelCacheKey, fileName: channelCacheFileName)
                continue
            }
            saveLargeStateDataUnlocked(data, defaultsKey: channelCacheKey, fileName: channelCacheFileName)
        }
    }

    private static func drainGuideWrites() {
        while true {
            persistenceLock.lock()
            guard let pending = pendingGuide else {
                guideWorkerScheduled = false
                persistenceLock.unlock()
                return
            }
            pendingGuide = nil
            persistenceLock.unlock()

            guard !pending.guide.isEmpty else {
                saveLargeStateDataUnlocked(Data(), defaultsKey: guideCacheKey, fileName: guideCacheFileName)
                continue
            }
            let cached = pending.guide.mapValues { programs in
                programs.prefix(pending.maxRows).map(CachedLiveProgram.init)
            }
            if let data = try? JSONEncoder().encode(cached) {
                saveLargeStateDataUnlocked(data, defaultsKey: guideCacheKey, fileName: guideCacheFileName)
            }
        }
    }

    private static func largeStateDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("DebridChannelsLargeState", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func largeStateFile(named name: String) -> URL? {
        largeStateDirectory()?.appendingPathComponent(name)
    }

    private static func removeLargeStateFile(named name: String) {
        guard let url = largeStateFile(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadLargeStateDataUnlocked(defaultsKey: String, fileName: String) -> Data? {
        if let url = largeStateFile(named: fileName),
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            return data
        }
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        if let data, !data.isEmpty {
            if let url = largeStateFile(named: fileName) {
                try? data.write(to: url, options: [.atomic])
            }
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return data
    }

    private static func saveLargeStateDataUnlocked(_ data: Data, defaultsKey: String, fileName: String) {
        guard !data.isEmpty else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            removeLargeStateFile(named: fileName)
            return
        }
        if let url = largeStateFile(named: fileName) {
            try? data.write(to: url, options: [.atomic])
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
