import Foundation

/// Persistent tvOS playback resume/history cache.
///
/// v1119 freeze correction: resume updates remain in a small in-memory dictionary and
/// are encoded/written on a serial utility queue. The player clock no longer JSON-encodes
/// the complete resume/history collection on the main thread every five seconds.
struct PlaybackResumeEntry: Codable, Hashable {
    var key: String
    var title: String
    var type: String
    var catalog: String
    // vBRDC084: movie year is persisted so legacy/title fallback can never bleed
    // resume state across unrelated remakes or same-name films. Optional preserves
    // decoding compatibility with the existing v1119 on-disk payload.
    var year: String?
    // vBRDC196: retain the original MediaItem identity so a Continue Watching card
    // synthesized after relaunch can still resolve the exact local resume key.
    var mediaID: String? = nil
    var tmdbId: String? = nil
    var imdbId: String? = nil
    var tvdbId: String? = nil
    var season: Int?
    var episode: Int?
    var seconds: Double
    var duration: Double
    var updatedAt: Date
    // Legacy single artwork field remains decode-compatible with every previous build.
    var artworkURL: String?
    // vBRDC202: keep portrait/backdrop independently so a resume card never has to use a
    // landscape image as its poster (or lose both when Trakt imports timing-only state).
    var posterArtworkURL: String? = nil
    var landscapeArtworkURL: String? = nil
    // vBRDC203: preserve title-logo artwork independently so Resume can render the same
    // themed hero identity as normal catalog and Trakt cards after relaunch/restore.
    var logoArtworkURL: String? = nil
}


extension PlaybackResumeEntry {
    var dcProgressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    var dcRemainingSeconds: Double {
        guard duration > seconds else { return 0 }
        return max(0, duration - seconds)
    }

    var dcRemainingText: String {
        let remaining = dcRemainingSeconds
        if remaining >= 3600 {
            return "\(Int(remaining / 3600))h \(Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60))m"
        }
        return "\(max(1, Int(remaining / 60)))m"
    }

    var dcResumePositionText: String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

final class PlaybackResumeCacheManager {
    static let shared = PlaybackResumeCacheManager()

    // vBRDC202: Trakt may return many unfinished titles in one cloud snapshot. Import
    // them as one resume-cache transaction so sync never rewrites the complete JSON/shadow
    // payload once per title. This also preserves an older local artwork URL when the
    // cloud checkpoint contains timing/identity only.
    struct SyncedProgressUpdate {
        let item: MediaItem
        let seconds: Double
        let duration: Double
        let updatedAt: Date
        let artworkURL: String?
    }

    private struct Payload: Codable {
        var entries: [String: PlaybackResumeEntry]
        var recents: [PlaybackResumeEntry]
    }

    private let legacyEntriesKey = "DebridChannels.v498.playbackResume.entries"
    private let legacyRecentsKey = "DebridChannels.v498.playbackResume.recents"
    // vBRDC196: second durable copy protects progress if Application Support is unavailable
    // or tvOS terminates around an atomic-file replacement boundary.
    private static let resumeShadowKey = "DebridChannels.playbackResume.shadow.vBRDC196"
    private let minimumResumeSeconds: Double = 8
    private let completionThreshold: Double = 0.95
    // v1153: one logical title/episode may be indexed by several resolver identity aliases.
    // Keep enough alias slots to preserve the original ~180 logical-title history depth.
    private let maxEntries = 1200
    private let maxRecents = 60
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "DebridChannels.PlaybackResumeCache.writer", qos: .utility)
    private var payload: Payload

    private static var storageFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DebridChannels", isDirectory: true)
            .appendingPathComponent("playback-resume-v1119.json")
    }

    private var fileURL: URL? { Self.storageFileURL }

    private init() {
        let defaults = UserDefaults.standard
        let initialFileURL = Self.storageFileURL
        let filePayload: Payload? = {
            guard let initialFileURL, let data = try? Data(contentsOf: initialFileURL) else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }()
        let shadowPayload: Payload? = {
            guard let data = defaults.data(forKey: Self.resumeShadowKey) else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }()

        func newestDate(_ value: Payload) -> Date {
            let entryDate = value.entries.values.map(\.updatedAt).max() ?? .distantPast
            let recentDate = value.recents.map(\.updatedAt).max() ?? .distantPast
            return max(entryDate, recentDate)
        }

        if let filePayload, let shadowPayload {
            payload = newestDate(shadowPayload) > newestDate(filePayload) ? shadowPayload : filePayload
            // Repair whichever copy lagged behind without blocking startup.
            scheduleWrite(payload, removeLegacyAfterSuccess: false)
            return
        } else if let filePayload {
            payload = filePayload
            if let data = try? JSONEncoder().encode(filePayload) { defaults.set(data, forKey: Self.resumeShadowKey) }
            return
        } else if let shadowPayload {
            payload = shadowPayload
            scheduleWrite(shadowPayload, removeLegacyAfterSuccess: false)
            return
        }

        let legacyEntries: [String: PlaybackResumeEntry]
        if let data = defaults.data(forKey: legacyEntriesKey),
           let decoded = try? JSONDecoder().decode([String: PlaybackResumeEntry].self, from: data) {
            legacyEntries = decoded
        } else {
            legacyEntries = [:]
        }
        let legacyRecents: [PlaybackResumeEntry]
        if let data = defaults.data(forKey: legacyRecentsKey),
           let decoded = try? JSONDecoder().decode([PlaybackResumeEntry].self, from: data) {
            legacyRecents = decoded
        } else {
            legacyRecents = []
        }
        payload = Payload(entries: legacyEntries, recents: legacyRecents)
        if !legacyEntries.isEmpty || !legacyRecents.isEmpty {
            scheduleWrite(payload, removeLegacyAfterSuccess: true)
        }
    }

    func resumeEntry(for item: MediaItem) -> PlaybackResumeEntry? {
        let aliases = playbackKeyAliases(for: item)
        lock.lock()
        let directMatches = aliases.compactMap { payload.entries[$0] }
        let entry: PlaybackResumeEntry?
        if let newestDirect = directMatches.max(by: { $0.updatedAt < $1.updatedAt }) {
            entry = newestDirect
        } else if shouldAttemptLegacyScan(for: item) {
            // vBRDC084: legacy scans are now truly fallback-only. Search cards with
            // stable IDs/year aliases no longer rescan up to 1200 history entries on
            // every SwiftUI body evaluation; that old path caused both false same-title
            // RESUME badges and unnecessary main-thread work in large Search grids.
            entry = payload.entries.values
                .filter { legacyIdentityMatches($0, item: item) }
                .max { $0.updatedAt < $1.updatedAt }
        } else {
            entry = nil
        }
        lock.unlock()

        // vBRDC193: Trakt is an optional cloud synchronization layer above the local
        // resume cache. Whichever checkpoint was updated most recently wins, while the
        // existing local payload remains instant/offline and is never deleted merely
        // because Trakt is unavailable.
        let cloudEntry = TraktSyncManager.shared.cloudResumeEntry(for: item)
        let newestEntry: PlaybackResumeEntry?
        if let local = entry, let cloud = cloudEntry {
            newestEntry = cloud.updatedAt > local.updatedAt ? cloud : local
        } else {
            newestEntry = entry ?? cloudEntry
        }

        guard let newestEntry, newestEntry.seconds >= minimumResumeSeconds else { return nil }
        if newestEntry.duration > 0, newestEntry.seconds / newestEntry.duration >= completionThreshold {
            clear(for: item)
            return nil
        }
        return newestEntry
    }

    func saveProgress(item: MediaItem, seconds: Double, duration: Double, synchronously: Bool = false) {
        guard seconds.isFinite, seconds >= minimumResumeSeconds else { return }
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0
        if normalizedDuration > 0, seconds / normalizedDuration >= completionThreshold {
            // vBRDC209: ordinary five-second checkpoints must not repeatedly rewrite the
            // resume cache through the final 5% of a title. True EOF owns the one clear.
            // A durable user/lifecycle exit may still clear once so a deliberately-ended
            // session does not resurrect an old near-complete checkpoint on next launch.
            if synchronously { clear(for: item, synchronously: true) }
            return
        }

        let key = playbackKey(for: item)
        let aliases = playbackKeyAliases(for: item)
        let entry = PlaybackResumeEntry(
            key: key,
            title: item.title,
            type: item.type,
            catalog: item.catalog,
            year: item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.year.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaID: item.id,
            tmdbId: item.tmdbId,
            imdbId: item.imdbId,
            tvdbId: item.tvdbId,
            season: item.seasonNumber,
            episode: item.episodeNumber,
            seconds: seconds,
            duration: normalizedDuration,
            updatedAt: Date(),
            artworkURL: item.landscapeURL ?? item.posterURL,
            posterArtworkURL: item.posterURL,
            landscapeArtworkURL: item.landscapeURL,
            logoArtworkURL: item.logoURL
        )

        // vBRDC135: ordinary playback checkpoints must not scan/sort/copy the resume
        // collection on the MainActor. Serialize the mutation on the existing utility
        // writer queue, then encode the same snapshot there. Durable lifecycle/exit saves
        // synchronously drain older checkpoints and apply the newest mutation before return.
        let applyAndWrite = {
            let snapshot = self.applyProgressMutation(
                item: item,
                aliases: aliases,
                entry: entry,
                includeLegacyCleanup: synchronously
            )
            if let fileURL = self.fileURL {
                self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
            }
        }
        if synchronously {
            writerQueue.sync(execute: applyAndWrite)
        } else {
            writerQueue.async(execute: applyAndWrite)
        }

        // vBRDC193: keep the existing five-second local checkpoint completely local.
        // Trakt receives semantic playback edges (start / pause / stop) from the player
        // lifecycle instead of repeated start calls from the decoder clock. This follows
        // Trakt scrobble semantics and prevents an in-progress cloud resume point from
        // being continuously removed/restarted while the movie is simply playing.
    }

    /// vBRDC197: materialize a newer cloud checkpoint into the exact same durable
    /// resume store used by Debrid Channels playback. This makes Trakt progress drive
    /// the normal Resume button, progress bars and Continue Watching row instead of
    /// existing only as an overlay lookup. Older cloud state can never overwrite a
    /// newer local checkpoint.
    @discardableResult
    func importSyncedProgress(
        item: MediaItem,
        seconds: Double,
        duration: Double,
        updatedAt: Date,
        artworkURL: String? = nil,
        synchronously: Bool = true
    ) -> Bool {
        guard seconds.isFinite, seconds >= minimumResumeSeconds,
              duration.isFinite, duration > 0,
              seconds / duration < completionThreshold else { return false }

        let aliases = playbackKeyAliases(for: item)
        lock.lock()
        // vBRDC197: compare against every locally equivalent identity before cleanup, not
        // only the exact aliases carried by the cloud-synthesized item. A local title/legacy
        // key may predate later TMDB/IMDb hydration and can still be the newest checkpoint.
        let newestExisting = payload.entries.compactMap { key, existing -> PlaybackResumeEntry? in
            if aliases.contains(key) || legacyIdentityMatches(existing, item: item) { return existing }
            return nil
        }.max { $0.updatedAt < $1.updatedAt }
        lock.unlock()
        if let newestExisting, newestExisting.updatedAt >= updatedAt { return false }

        let preservedArtwork = artworkURL
            ?? item.landscapeURL
            ?? item.posterURL
            ?? newestExisting?.artworkURL
        let preservedPoster = item.posterURL ?? newestExisting?.posterArtworkURL
        let preservedLandscape = item.landscapeURL ?? newestExisting?.landscapeArtworkURL
        let preservedLogo = item.logoURL ?? newestExisting?.logoArtworkURL
        let entry = PlaybackResumeEntry(
            key: playbackKey(for: item),
            title: item.title,
            type: item.type,
            catalog: item.catalog,
            year: item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.year.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaID: item.id,
            tmdbId: item.tmdbId,
            imdbId: item.imdbId,
            tvdbId: item.tvdbId,
            season: item.seasonNumber,
            episode: item.episodeNumber,
            seconds: seconds,
            duration: duration,
            updatedAt: updatedAt,
            artworkURL: preservedArtwork,
            posterArtworkURL: preservedPoster,
            landscapeArtworkURL: preservedLandscape,
            logoArtworkURL: preservedLogo
        )

        let applyAndWrite = {
            let snapshot = self.applyProgressMutation(
                item: item,
                aliases: aliases,
                entry: entry,
                includeLegacyCleanup: true
            )
            if let fileURL = self.fileURL {
                self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
            }
        }
        if synchronously {
            writerQueue.sync(execute: applyAndWrite)
        } else {
            writerQueue.async(execute: applyAndWrite)
        }
        return true
    }

    /// vBRDC202: import one complete Trakt playback snapshot with one lock/mutation and
    /// one durable write. vBRDC197 performed a synchronous full JSON + UserDefaults shadow
    /// rewrite for every title, which could stall the app during a large account sync.
    @discardableResult
    func importSyncedProgressBatch(_ updates: [SyncedProgressUpdate]) -> Int {
        guard !updates.isEmpty else { return 0 }
        var imported = 0

        writerQueue.sync {
            self.lock.lock()
            for update in updates {
                let seconds = update.seconds
                let duration = update.duration
                guard seconds.isFinite, seconds >= self.minimumResumeSeconds,
                      duration.isFinite, duration > 0,
                      seconds / duration < self.completionThreshold else { continue }

                let item = update.item
                let aliases = self.playbackKeyAliases(for: item)
                let matching = self.payload.entries.compactMap { key, existing -> PlaybackResumeEntry? in
                    if aliases.contains(key) || self.legacyIdentityMatches(existing, item: item) { return existing }
                    return nil
                }
                let newestExisting = matching.max { $0.updatedAt < $1.updatedAt }
                if let newestExisting, newestExisting.updatedAt >= update.updatedAt { continue }

                let preservedArtwork = update.artworkURL
                    ?? item.landscapeURL
                    ?? item.posterURL
                    ?? newestExisting?.artworkURL
                    ?? matching.compactMap(\.artworkURL).first
                let preservedPoster = item.posterURL
                    ?? newestExisting?.posterArtworkURL
                    ?? matching.compactMap(\.posterArtworkURL).first
                let preservedLandscape = item.landscapeURL
                    ?? newestExisting?.landscapeArtworkURL
                    ?? matching.compactMap(\.landscapeArtworkURL).first
                let preservedLogo = item.logoURL
                    ?? newestExisting?.logoArtworkURL
                    ?? matching.compactMap(\.logoArtworkURL).first
                let entry = PlaybackResumeEntry(
                    key: self.playbackKey(for: item),
                    title: item.title,
                    type: item.type,
                    catalog: item.catalog,
                    year: item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.year.trimmingCharacters(in: .whitespacesAndNewlines),
                    mediaID: item.id,
                    tmdbId: item.tmdbId,
                    imdbId: item.imdbId,
                    tvdbId: item.tvdbId,
                    season: item.seasonNumber,
                    episode: item.episodeNumber,
                    seconds: seconds,
                    duration: duration,
                    updatedAt: update.updatedAt,
                    artworkURL: preservedArtwork,
                    posterArtworkURL: preservedPoster,
                    landscapeArtworkURL: preservedLandscape,
                    logoArtworkURL: preservedLogo
                )

                self.payload.entries = self.payload.entries.filter { _, existing in
                    !self.legacyIdentityMatches(existing, item: item)
                }
                for alias in aliases { self.payload.entries[alias] = entry }
                self.payload.recents.removeAll { existing in
                    aliases.contains(existing.key) || self.legacyIdentityMatches(existing, item: item)
                }
                self.payload.recents.insert(entry, at: 0)
                imported += 1
            }

            if self.payload.entries.count > self.maxEntries {
                self.payload.entries = Dictionary(uniqueKeysWithValues: self.payload.entries
                    .sorted { $0.value.updatedAt > $1.value.updatedAt }
                    .prefix(self.maxEntries)
                    .map { ($0.key, $0.value) })
            }
            self.payload.recents.sort { $0.updatedAt > $1.updatedAt }
            if self.payload.recents.count > self.maxRecents {
                self.payload.recents = Array(self.payload.recents.prefix(self.maxRecents))
            }
            let snapshot = self.payload
            self.lock.unlock()

            if let fileURL = self.fileURL {
                self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
            }
        }
        return imported
    }

    struct ArtworkBackfillUpdate {
        let entry: PlaybackResumeEntry
        let posterURL: String?
        let landscapeURL: String?
        let logoURL: String?
    }

    /// vBRDC202: when catalog/Trakt rows finally resolve artwork for known resume entries,
    /// update the complete shelf in one utility-queue mutation and one durable write. A
    /// visible Resume row can contain 20+ cards; writing the full resume JSON once per card
    /// was another avoidable I/O burst during catalog publication.
    func backfillArtworkBatch(_ updates: [ArtworkBackfillUpdate]) {
        let cleanUpdates = updates.compactMap { update -> (PlaybackResumeEntry, String?, String?, String?)? in
            let poster = update.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let landscape = update.landscapeURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            let logo = update.logoURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (poster?.isEmpty == false) || (landscape?.isEmpty == false) || (logo?.isEmpty == false) else { return nil }
            return (update.entry, poster, landscape, logo)
        }
        guard !cleanUpdates.isEmpty else { return }

        writerQueue.async {
            self.lock.lock()
            var changed = false
            for (entry, cleanPoster, cleanLandscape, cleanLogo) in cleanUpdates {
                for key in Array(self.payload.entries.keys) {
                    guard var existing = self.payload.entries[key], existing.key == entry.key else { continue }
                    if (existing.posterArtworkURL?.isEmpty ?? true), let cleanPoster, !cleanPoster.isEmpty {
                        existing.posterArtworkURL = cleanPoster
                        changed = true
                    }
                    if (existing.landscapeArtworkURL?.isEmpty ?? true), let cleanLandscape, !cleanLandscape.isEmpty {
                        existing.landscapeArtworkURL = cleanLandscape
                        changed = true
                    }
                    if (existing.logoArtworkURL?.isEmpty ?? true), let cleanLogo, !cleanLogo.isEmpty {
                        existing.logoArtworkURL = cleanLogo
                        changed = true
                    }
                    if (existing.artworkURL?.isEmpty ?? true) {
                        existing.artworkURL = cleanLandscape?.isEmpty == false ? cleanLandscape : cleanPoster
                        changed = true
                    }
                    self.payload.entries[key] = existing
                }
                for index in self.payload.recents.indices where self.payload.recents[index].key == entry.key {
                    if (self.payload.recents[index].posterArtworkURL?.isEmpty ?? true), let cleanPoster, !cleanPoster.isEmpty {
                        self.payload.recents[index].posterArtworkURL = cleanPoster
                        changed = true
                    }
                    if (self.payload.recents[index].landscapeArtworkURL?.isEmpty ?? true), let cleanLandscape, !cleanLandscape.isEmpty {
                        self.payload.recents[index].landscapeArtworkURL = cleanLandscape
                        changed = true
                    }
                    if (self.payload.recents[index].logoArtworkURL?.isEmpty ?? true), let cleanLogo, !cleanLogo.isEmpty {
                        self.payload.recents[index].logoArtworkURL = cleanLogo
                        changed = true
                    }
                    if (self.payload.recents[index].artworkURL?.isEmpty ?? true) {
                        self.payload.recents[index].artworkURL = cleanLandscape?.isEmpty == false ? cleanLandscape : cleanPoster
                        changed = true
                    }
                }
            }
            let snapshot = self.payload
            self.lock.unlock()
            guard changed, let fileURL = self.fileURL else { return }
            self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
        }
    }

    func backfillArtwork(for entry: PlaybackResumeEntry, posterURL: String?, landscapeURL: String?, logoURL: String? = nil) {
        backfillArtworkBatch([.init(entry: entry, posterURL: posterURL, landscapeURL: landscapeURL, logoURL: logoURL)])
    }


    /// vBRDC203: focused Resume/Trakt heroes may discover a TMDB themed logo after the
    /// resume row was synthesized. Persist that logo against the matching checkpoint so the
    /// next launch does not fall back to plain title text while catalog hydration catches up.
    func backfillThemedLogo(for item: MediaItem, logoURL: String?) {
        guard let clean = logoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return }
        let aliases = Set(playbackKeyAliases(for: item))
        let candidate = recentEntries().first { entry in
            aliases.contains(entry.key) || legacyIdentityMatches(entry, item: item)
        }
        guard let candidate else { return }
        backfillArtwork(for: candidate, posterURL: nil, landscapeURL: nil, logoURL: clean)
    }

    func clear(for item: MediaItem, synchronously: Bool = false) {
        let aliases = playbackKeyAliases(for: item)
        let applyAndWrite = {
            let snapshot = self.applyClearMutation(item: item, aliases: aliases)
            if let fileURL = self.fileURL {
                self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
            }
        }
        if synchronously {
            writerQueue.sync(execute: applyAndWrite)
        } else {
            writerQueue.async(execute: applyAndWrite)
        }
    }

    private func applyProgressMutation(
        item: MediaItem,
        aliases: [String],
        entry: PlaybackResumeEntry,
        includeLegacyCleanup: Bool
    ) -> Payload {
        lock.lock()
        if includeLegacyCleanup {
            // Find Links may hydrate IMDb -> TMDB (or the reverse). Do the broad legacy
            // reconciliation on durable saves, not every five-second playback checkpoint.
            payload.entries = payload.entries.filter { _, existing in
                !legacyIdentityMatches(existing, item: item)
            }
        }
        for alias in aliases { payload.entries[alias] = entry }
        if payload.entries.count > maxEntries {
            payload.entries = Dictionary(uniqueKeysWithValues: payload.entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) })
        }
        payload.recents.removeAll { existing in
            aliases.contains(existing.key) || (includeLegacyCleanup && legacyIdentityMatches(existing, item: item))
        }
        payload.recents.insert(entry, at: 0)
        if payload.recents.count > maxRecents { payload.recents = Array(payload.recents.prefix(maxRecents)) }
        let snapshot = payload
        lock.unlock()
        return snapshot
    }

    private func applyClearMutation(item: MediaItem, aliases: [String]) -> Payload {
        lock.lock()
        payload.entries = payload.entries.filter { key, existing in
            !aliases.contains(key) && !legacyIdentityMatches(existing, item: item)
        }
        payload.recents.removeAll { existing in
            aliases.contains(existing.key) || legacyIdentityMatches(existing, item: item)
        }
        let snapshot = payload
        lock.unlock()
        return snapshot
    }

    /// Writes the latest in-memory resume payload before tvOS can suspend or terminate
    /// the process. Normal playback checkpoints remain asynchronous; lifecycle/exit saves
    /// use this bounded synchronous flush so a correct timeline cannot disappear on relaunch.
    func flushSynchronously() {
        guard let fileURL else { return }
        // vBRDC135: snapshot only after the writer queue has drained older async
        // checkpoint mutations; otherwise a pre-drain snapshot could overwrite the
        // newest queued resume position during app suspension.
        writerQueue.sync {
            lock.lock()
            let snapshot = payload
            lock.unlock()
            write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
        }
    }

    func recentEntries() -> [PlaybackResumeEntry] {
        lock.lock()
        let values = payload.recents.sorted { $0.updatedAt > $1.updatedAt }
        lock.unlock()
        return values
    }

    func playbackKey(for item: MediaItem) -> String {
        let season = item.seasonNumber
        let episode = item.episodeNumber
        let lowerType = item.type.lowercased()
        let isEpisode = season != nil || episode != nil || lowerType.contains("episode") || lowerType.contains("series") || lowerType.contains("show")

        if isEpisode {
            let showID = stableShowID(for: item)
            return "episode|\(showID)|s\(season ?? 0)|e\(episode ?? 0)"
        }

        if let tmdb = tmdbID(in: item.id) ?? item.tmdbId.flatMap(tmdbIDFromLooseValue) { return "movie|tmdb|\(tmdb)" }
        if let imdb = imdbID(in: item.id) ?? item.imdbId.flatMap(imdbIDFromLooseValue) { return "movie|imdb|\(imdb)" }
        return "movie|fallback|\(safe([item.catalog, item.title, item.year, item.id].joined(separator: "|")))"
    }


    /// v1153 source-independent identity aliases. Resolver hydration is allowed to improve
    /// metadata IDs without creating a second playback timeline for the same title/episode.
    func playbackKeyAliases(for item: MediaItem) -> [String] {
        let season = item.seasonNumber
        let episode = item.episodeNumber
        let lowerType = item.type.lowercased()
        let isEpisode = season != nil || episode != nil || lowerType.contains("episode") || lowerType.contains("series") || lowerType.contains("show")
        var aliases: [String] = [playbackKey(for: item)]

        func append(_ value: String?) {
            guard let value, !value.isEmpty, !aliases.contains(value) else { return }
            aliases.append(value)
        }

        if isEpisode {
            let s = season ?? 0
            let e = episode ?? 0
            for identity in stableShowIDAliases(for: item) {
                append("episode|\(identity)|s\(s)|e\(e)")
            }
            if let seriesStem = normalizedSeriesTitleStem(for: item), !seriesStem.isEmpty {
                append("episode|title|\(safe([seriesStem, item.year].joined(separator: "|")))|s\(s)|e\(e)")
            }
        } else {
            if let tmdb = tmdbID(in: item.id) ?? item.tmdbId.flatMap(tmdbIDFromLooseValue) {
                append("movie|tmdb|\(tmdb)")
            }
            if let imdb = imdbID(in: item.id) ?? item.imdbId.flatMap(imdbIDFromLooseValue) {
                append("movie|imdb|\(imdb)")
            }
            if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty {
                append("movie|tvdb|\(safe(tvdb))")
            }
            let title = normalizedIdentityTitle(item.title)
            if !title.isEmpty {
                append("movie|title|\(safe([title, item.year].joined(separator: "|")))")
            }
        }
        return aliases
    }

    private func stableShowIDAliases(for item: MediaItem) -> [String] {
        var values: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, !values.contains(value) else { return }
            values.append(value)
        }
        add(stableShowID(for: item))
        if let tmdb = tmdbID(in: item.id) ?? item.tmdbId.flatMap(tmdbIDFromLooseValue) { add("tmdb:\(tmdb)") }
        if let imdb = imdbID(in: item.id) ?? item.imdbId.flatMap(imdbIDFromLooseValue) { add("imdb:\(imdb)") }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty { add("tvdb:\(tvdb)") }

        var raw = item.id
        if let range = raw.range(of: #"[:|/_-]s?\d{1,3}[:|/_-]e?\d{1,4}$"#, options: [.regularExpression, .caseInsensitive]) {
            raw.removeSubrange(range)
        }
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanRaw.isEmpty { add("raw:\(safe(cleanRaw))") }
        return values
    }

    private func normalizedSeriesTitleStem(for item: MediaItem) -> String? {
        var value = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"\s+s\d{1,3}e\d{1,4}\b"#, options: [.regularExpression, .caseInsensitive]) {
            value = String(value[..<range.lowerBound])
        }
        value = normalizedIdentityTitle(value)
        return value.isEmpty ? nil : value
    }

    private func normalizedIdentityTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldAttemptLegacyScan(for item: MediaItem) -> Bool {
        let lowerType = item.type.lowercased()
        let isEpisode = item.seasonNumber != nil || item.episodeNumber != nil || lowerType.contains("episode") || lowerType.contains("series") || lowerType.contains("show")
        if isEpisode { return true }

        // Modern movie checkpoints are indexed by TMDB/IMDb/TVDB and title+year aliases.
        // When any of those identities exists, absence of a direct alias is authoritative.
        if tmdbID(in: item.id) != nil || item.tmdbId.flatMap(tmdbIDFromLooseValue) != nil { return false }
        if imdbID(in: item.id) != nil || item.imdbId.flatMap(imdbIDFromLooseValue) != nil { return false }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty { return false }
        if !item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    private func legacyIdentityMatches(_ entry: PlaybackResumeEntry, item: MediaItem) -> Bool {
        let itemSeason = item.seasonNumber
        let itemEpisode = item.episodeNumber
        let lowerType = item.type.lowercased()
        let itemIsEpisode = itemSeason != nil || itemEpisode != nil || lowerType.contains("episode") || lowerType.contains("series") || lowerType.contains("show")
        let entryLowerType = entry.type.lowercased()
        let entryIsEpisode = entry.season != nil || entry.episode != nil || entryLowerType.contains("episode") || entryLowerType.contains("series") || entryLowerType.contains("show")
        guard itemIsEpisode == entryIsEpisode else { return false }

        if itemIsEpisode {
            guard (entry.season ?? 0) == (itemSeason ?? 0), (entry.episode ?? 0) == (itemEpisode ?? 0) else { return false }
            var legacyTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = legacyTitle.range(of: #"\s+s\d{1,3}e\d{1,4}\b"#, options: [.regularExpression, .caseInsensitive]) {
                legacyTitle = String(legacyTitle[..<range.lowerBound])
            }
            let entryStem = normalizedIdentityTitle(legacyTitle)
            let itemStem = normalizedSeriesTitleStem(for: item) ?? normalizedIdentityTitle(item.title)
            return !entryStem.isEmpty && entryStem == itemStem
        }

        // vBRDC084: movie resume identity must never be title-only when the current
        // item has a stable provider ID or a year. That old fallback caused every
        // search result named e.g. "The Long Walk" to inherit the same RESUME badge.
        // Direct aliases are checked before this function; the fallback below exists
        // only for genuinely legacy/no-ID records and is conservative by design.
        guard normalizedIdentityTitle(entry.title) == normalizedIdentityTitle(item.title) else { return false }

        let itemAliases = playbackKeyAliases(for: item)
        if itemAliases.contains(entry.key) { return true }

        let hasStableMovieIdentity = itemAliases.contains { alias in
            alias.hasPrefix("movie|tmdb|") || alias.hasPrefix("movie|imdb|") || alias.hasPrefix("movie|tvdb|")
        }
        if hasStableMovieIdentity { return false }

        let itemYear = item.year.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryYear = entry.year?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !itemYear.isEmpty || !entryYear.isEmpty {
            return !itemYear.isEmpty && !entryYear.isEmpty && itemYear == entryYear
        }

        // Last-resort legacy records with no stable ID and no year remain scoped to
        // their originating catalog instead of becoming a process-wide title match.
        return entry.catalog.caseInsensitiveCompare(item.catalog) == .orderedSame
    }

    private func stableShowID(for item: MediaItem) -> String {
        if let tmdb = tmdbID(in: item.id) ?? item.tmdbId.flatMap(tmdbIDFromLooseValue) { return "tmdb:\(tmdb)" }
        if let imdb = imdbID(in: item.id) ?? item.imdbId.flatMap(imdbIDFromLooseValue) { return "imdb:\(imdb)" }
        if let tvdb = item.tvdbId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvdb.isEmpty { return "tvdb:\(tvdb)" }
        var raw = item.id
        if let range = raw.range(of: #"[:|/_-]s?\d{1,3}[:|/_-]e?\d{1,4}$"#, options: [.regularExpression, .caseInsensitive]) {
            raw.removeSubrange(range)
        } else if let range = raw.range(of: "season", options: .caseInsensitive) {
            raw = String(raw[..<range.lowerBound])
        }
        return "fallback:\(safe([item.catalog, item.title, item.year, raw].joined(separator: "|")))"
    }

    private func tmdbID(in value: String) -> String? {
        let lower = value.lowercased()
        guard lower.contains("tmdb") else { return nil }
        if let range = value.range(of: #"tmdb[:_/|-]?(?:movie|tv|show|series)?[:_/|-]?(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let fragment = String(value[range])
            if let digits = fragment.range(of: #"\d+"#, options: .regularExpression) { return String(fragment[digits]) }
        }
        return nil
    }

    private func tmdbIDFromLooseValue(_ value: String) -> String? {
        value.range(of: #"\d+"#, options: .regularExpression).map { String(value[$0]) }
    }

    private func imdbID(in value: String) -> String? {
        if let range = value.range(of: #"tt\d{6,}"#, options: [.regularExpression, .caseInsensitive]) {
            return String(value[range]).lowercased()
        }
        return nil
    }

    private func imdbIDFromLooseValue(_ value: String) -> String? {
        imdbID(in: value)
    }

    private func safe(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(abs(trimmed.hashValue))
    }

    private func scheduleWrite(_ snapshot: Payload, removeLegacyAfterSuccess: Bool = false) {
        guard let fileURL else { return }
        writerQueue.async {
            self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: removeLegacyAfterSuccess)
        }
    }

    private func writeSynchronously(_ snapshot: Payload) {
        guard let fileURL else { return }
        // Serializing through the same queue drains any older async snapshot first, then
        // commits the newest payload before returning to the lifecycle caller.
        writerQueue.sync {
            self.write(snapshot, to: fileURL, removeLegacyAfterSuccess: false)
        }
    }

    private func write(_ snapshot: Payload, to fileURL: URL, removeLegacyAfterSuccess: Bool) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            UserDefaults.standard.set(data, forKey: Self.resumeShadowKey)
            if removeLegacyAfterSuccess {
                UserDefaults.standard.removeObject(forKey: legacyEntriesKey)
                UserDefaults.standard.removeObject(forKey: legacyRecentsKey)
            }
        } catch {
            // Resume memory must never interrupt playback.
        }
    }
}
