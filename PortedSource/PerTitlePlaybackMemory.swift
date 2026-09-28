import Foundation

/// Phase 7 per-title playback preferences.
///
/// Language choices are stored at show level for television so the next episode can
/// suggest the same audio/subtitle language. Source choices remain exact-title or
/// exact-episode scoped. Alternate Audio candidate/offset and resume position retain
/// their existing exact-episode stores and are intentionally not broadened here.
struct PerTitlePlaybackPreference: Codable, Equatable {
    var audioPreference: String?
    var subtitlePreference: String?
    var subtitlesEnabled: Bool?
    var subtitleDelayMS: Int?
    var lastProvider: String?
    var lastSourceSignature: String?
    var lastSourceTitle: String?
    var sourceQualityPreference: String?
    var updatedAt: Date

    static let empty = PerTitlePlaybackPreference(
        audioPreference: nil,
        subtitlePreference: nil,
        subtitlesEnabled: nil,
        subtitleDelayMS: nil,
        lastProvider: nil,
        lastSourceSignature: nil,
        lastSourceTitle: nil,
        sourceQualityPreference: nil,
        updatedAt: .distantPast
    )
}

final class PerTitlePlaybackMemoryManager {
    static let shared = PerTitlePlaybackMemoryManager()

    private struct Storage: Codable {
        var exact: [String: PerTitlePlaybackPreference]
        var seriesLanguage: [String: PerTitlePlaybackPreference]
    }

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "DebridChannels.PerTitlePlaybackMemory.writer", qos: .utility)
    private let maxExactEntries = 240
    private let maxSeriesEntries = 90
    private var storage: Storage

    private static var storageFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DebridChannels", isDirectory: true)
            .appendingPathComponent("per-title-playback-memory-v1119.json")
    }

    private var fileURL: URL? { Self.storageFileURL }

    private init() {
        let initialFileURL = Self.storageFileURL
        if let initialFileURL,
           let data = try? Data(contentsOf: initialFileURL),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage(exact: [:], seriesLanguage: [:])
        }
    }

    func preference(for item: MediaItem) -> PerTitlePlaybackPreference {
        lock.lock()
        defer { lock.unlock() }
        let exact = storage.exact[exactKey(for: item)] ?? .empty
        guard isEpisode(item) else { return exact }
        let series = storage.seriesLanguage[seriesKey(for: item)] ?? .empty
        return PerTitlePlaybackPreference(
            audioPreference: exact.audioPreference ?? series.audioPreference,
            subtitlePreference: exact.subtitlePreference ?? series.subtitlePreference,
            subtitlesEnabled: exact.subtitlesEnabled ?? series.subtitlesEnabled,
            subtitleDelayMS: exact.subtitleDelayMS,
            lastProvider: exact.lastProvider,
            lastSourceSignature: exact.lastSourceSignature,
            lastSourceTitle: exact.lastSourceTitle,
            sourceQualityPreference: exact.sourceQualityPreference,
            updatedAt: max(exact.updatedAt, series.updatedAt)
        )
    }

    func trackPreference(_ kind: String, for item: MediaItem) -> String? {
        let value = preference(for: item)
        if kind == "audio" { return value.audioPreference }
        if kind == "subtitle" {
            if value.subtitlesEnabled == false { return "Off" }
            return value.subtitlePreference
        }
        return nil
    }

    func subtitleDelayMS(for item: MediaItem) -> Int {
        preference(for: item).subtitleDelayMS ?? 0
    }

    func rememberTrackPreference(_ kind: String, value: String, for item: MediaItem) {
        let clean = normalized(value)
        guard !clean.isEmpty else { return }
        let targetKey = isEpisode(item) ? seriesKey(for: item) : exactKey(for: item)
        mutate(seriesScoped: isEpisode(item), key: targetKey) { entry in
            if kind == "audio" {
                entry.audioPreference = clean
            } else if kind == "subtitle" {
                entry.subtitlesEnabled = clean.caseInsensitiveCompare("Off") != .orderedSame
                entry.subtitlePreference = entry.subtitlesEnabled == true ? clean : nil
            }
        }
    }

    func rememberSubtitleDelayMS(_ value: Int, for item: MediaItem) {
        let clamped = min(max(value, -10_000), 10_000)
        mutate(seriesScoped: false, key: exactKey(for: item)) { entry in
            entry.subtitleDelayMS = clamped
        }
    }

    func rememberProvider(_ provider: String, for item: MediaItem) {
        let clean = normalized(provider)
        guard !clean.isEmpty else { return }
        mutate(seriesScoped: false, key: exactKey(for: item)) { entry in
            entry.lastProvider = clean
        }
    }

    func rememberSource(_ link: StreamLink, for item: MediaItem) {
        mutate(seriesScoped: false, key: exactKey(for: item)) { entry in
            entry.lastProvider = normalized(link.providerDisplay)
            entry.lastSourceSignature = sourceSignature(link)
            entry.lastSourceTitle = normalized(link.title)
            entry.sourceQualityPreference = qualityPreference(link)
        }
    }

    /// Preserve Source Intelligence ranking, but honor an exact remembered source when
    /// it still exists. If that signed source expired, a remembered provider/quality match
    /// may move forward only when it already appears inside the top five ranked choices.
    func prioritizedLinks(for item: MediaItem, links: [StreamLink]) -> [StreamLink] {
        guard links.count > 1 else { return links }
        let memory = preference(for: item)
        if let signature = memory.lastSourceSignature,
           let index = links.firstIndex(where: { sourceSignature($0) == signature }) {
            var result = links
            let match = result.remove(at: index)
            result.insert(match, at: 0)
            return result
        }

        let preferredProvider = normalized(memory.lastProvider ?? "").lowercased()
        let preferredQuality = normalized(memory.sourceQualityPreference ?? "").lowercased()
        guard !preferredProvider.isEmpty || !preferredQuality.isEmpty else { return links }
        let safeRange = links.indices.prefix(min(5, links.count))
        guard let index = safeRange.first(where: { candidateIndex in
            let candidate = links[candidateIndex]
            let providerMatches = preferredProvider.isEmpty || normalized(candidate.providerDisplay).lowercased() == preferredProvider
            let qualityMatches = preferredQuality.isEmpty || qualityPreference(candidate).lowercased() == preferredQuality
            return providerMatches && qualityMatches
        }), index > 0 else { return links }
        var result = links
        let match = result.remove(at: index)
        result.insert(match, at: 0)
        return result
    }

    private func mutate(seriesScoped: Bool, key: String, change: (inout PerTitlePlaybackPreference) -> Void) {
        lock.lock()
        if seriesScoped {
            var entry = storage.seriesLanguage[key] ?? .empty
            change(&entry)
            entry.updatedAt = Date()
            storage.seriesLanguage[key] = entry
            storage.seriesLanguage = bounded(storage.seriesLanguage, max: maxSeriesEntries)
        } else {
            var entry = storage.exact[key] ?? .empty
            change(&entry)
            entry.updatedAt = Date()
            storage.exact[key] = entry
            storage.exact = bounded(storage.exact, max: maxExactEntries)
        }
        let snapshot = storage
        lock.unlock()
        writeAsync(snapshot)
    }

    private func writeAsync(_ snapshot: Storage) {
        guard let fileURL else { return }
        writerQueue.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                // Playback preferences are advisory. Never block or fail playback for cache I/O.
            }
        }
    }

    private func bounded(_ values: [String: PerTitlePlaybackPreference], max limit: Int) -> [String: PerTitlePlaybackPreference] {
        guard values.count > limit else { return values }
        return Dictionary(uniqueKeysWithValues: values
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(limit)
            .map { ($0.key, $0.value) })
    }

    private func exactKey(for item: MediaItem) -> String {
        PlaybackResumeCacheManager.shared.playbackKey(for: item)
    }

    private func seriesKey(for item: MediaItem) -> String {
        let exact = exactKey(for: item)
        if exact.hasPrefix("episode|") {
            let parts = exact.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 3 { return parts.prefix(parts.count - 2).joined(separator: "|") }
        }
        return exact
    }

    private func isEpisode(_ item: MediaItem) -> Bool {
        let type = item.type.lowercased()
        return item.seasonNumber != nil || item.episodeNumber != nil || type.contains("episode") || type.contains("series") || type.contains("show")
    }

    private func sourceSignature(_ link: StreamLink) -> String {
        [link.providerDisplay, link.source, link.title, link.quality, link.size]
            .map { normalized($0).lowercased() }
            .joined(separator: "|")
    }

    private func qualityPreference(_ link: StreamLink) -> String {
        switch link.sourceIntelligenceResolutionRank {
        case 0: return "4K"
        case 1: return "1440p"
        case 2: return "1080p"
        case 3: return "720p"
        case 4: return "480p"
        default:
            let clean = normalized(link.quality)
            return clean.isEmpty ? "Auto" : clean
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
