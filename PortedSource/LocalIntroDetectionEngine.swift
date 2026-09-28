import Foundation

/// App-owned chapter metadata published by the active playback engine.
/// No media URL or playback data is sent to the Debrid Channels backend.
struct PlaybackChapterMarker: Equatable, Hashable {
    let startSeconds: Double
    let endSeconds: Double
    let title: String
}

/// Tiny per-second fingerprint emitted from the already-decoded KSPlayer audio path.
/// The sample contains no recoverable audio, only a 64-bit perceptual signature and
/// two low-resolution characteristics used to reject false matches.
struct PlaybackAudioFingerprintSample: Equatable {
    let seconds: Double
    let hash: UInt64
    let energy: Float
    let zeroCrossingRate: Float
}

struct VODIntroMarker: Equatable, Codable {
    let startSeconds: Double
    let endSeconds: Double
    let title: String
    let confidence: String
    let chapterIndex: Int?
    // vBRDC045: optional so the existing vBRDC043/044 on-device archive decodes cleanly.
    // External/community timestamps never contain a stream URL or media payload.
    let provider: String?

    init(
        startSeconds: Double,
        endSeconds: Double,
        title: String,
        confidence: String,
        chapterIndex: Int?,
        provider: String? = nil
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.title = title
        self.confidence = confidence
        self.chapterIndex = chapterIndex
        self.provider = provider
    }

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }

    var authorityRank: Int {
        // A chapter is embedded in the exact file currently playing, so it wins if present.
        if chapterIndex != nil { return 500 }
        switch provider?.lowercased() {
        case "skipdb": return 470
        case "theintrodb": return 460
        case "introdb": return 450
        case "aniskip": return 425
        case "local-audio": return 200
        default: return 150
        }
    }

    var isStorySafe: Bool {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
              durationSeconds >= 5, durationSeconds <= 4 * 60 else { return false }

        // Exact-file chapters and curated community timestamps may legitimately follow a
        // long cold open. Local recurrence is intentionally more conservative because it is
        // inferred from decoded audio rather than an episode-specific marker.
        let trustedEpisodeMarker = chapterIndex != nil || ["skipdb", "theintrodb", "introdb", "aniskip"].contains(provider?.lowercased() ?? "")
        if trustedEpisodeMarker {
            return startSeconds <= 25 * 60 && endSeconds <= 29 * 60
        }
        return startSeconds <= 15 * 60 && endSeconds <= 18 * 60
    }
}

/// vBRDC043: client-first Skip Intro authority.
///
/// Detection order:
/// 1. Local chapter names from the active KSPlayer/AVPlayer asset.
/// 2. A conservative recurring-audio fingerprint learned from earlier episodes of the
///    same series + season. Learning needs two sufficiently sampled episodes before it
///    can create a reusable template, so a brand-new show never guesses from elapsed time.
///
/// The archive stores only tiny irreversible signatures. It never stores audio/video,
/// stream URLs, cookies, provider headers, or backend credentials.
final class LocalIntroDetectionEngine {
    static let shared = LocalIntroDetectionEngine()

    private struct Fingerprint: Codable, Hashable {
        let second: Int
        let hash: UInt64
        let energy: Float
        let zeroCrossingRate: Float
    }

    private struct EpisodeRecord: Codable {
        let seriesKey: String
        let season: Int
        let episode: Int
        var samples: [Fingerprint]
        var marker: VODIntroMarker?
        var updatedAt: Date
    }

    private struct Archive: Codable {
        var schemaVersion: Int = 1
        var records: [EpisodeRecord] = []
    }

    private struct LearnedTemplate {
        let samples: [Fingerprint]
        let averageDistance: Double
        let confidence: String
        let expectedStartSecond: Int?

        var durationSeconds: Double { Double(samples.count) }
    }

    private struct Session {
        let seriesKey: String
        let season: Int
        let episode: Int
        var samplesBySecond: [Int: Fingerprint]
        var marker: VODIntroMarker?
        var template: LearnedTemplate?
    }

    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "com.debridchannels.local-intro.persistence", qos: .utility)
    private var sessions: [UUID: Session] = [:]
    private var archive = Archive()
    private var archiveLoaded = false

    // vBRDC047: long cold opens are common. Jellyfin-class analyzers inspect roughly the
    // first 25-30% / 15 minutes, so do not stop our already-decoded 1 Hz fingerprint at 8:30.
    private let maximumFingerprintSecond = 15 * 60
    private let maximumRecords = 60
    private let maximumRecordsPerSeriesSeason = 6
    private let minimumTemplateSeconds = 15
    private let maximumTemplateSeconds = 3 * 60
    private let minimumCurrentMatchSeconds = 12
    private let guidedCurrentMatchSeconds = 7
    private let guidedStartToleranceSeconds = 3 * 60

    private init() {}

    func registerChapters(
        _ chapters: [PlaybackChapterMarker],
        item: MediaItem,
        presentationID: UUID
    ) -> VODIntroMarker? {
        guard let identity = identity(for: item), !chapters.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        loadArchiveIfNeededLocked()
        var session = sessionLocked(identity: identity, presentationID: presentationID)
        if let existing = session.marker {
            sessions[presentationID] = session
            return existing
        }
        guard let marker = storySafeChapterMarker(from: chapters) else {
            sessions[presentationID] = session
            return nil
        }
        session.marker = marker
        sessions[presentationID] = session
        return marker
    }

    func ingestFingerprint(
        _ sample: PlaybackAudioFingerprintSample,
        item: MediaItem,
        presentationID: UUID
    ) -> VODIntroMarker? {
        guard let identity = identity(for: item), sample.seconds.isFinite else { return nil }
        let second = Int(sample.seconds.rounded(.down))
        guard second >= 0, second <= maximumFingerprintSecond else { return nil }
        guard sample.energy.isFinite, sample.zeroCrossingRate.isFinite else { return nil }

        lock.lock()
        defer { lock.unlock() }
        loadArchiveIfNeededLocked()
        var session = sessionLocked(identity: identity, presentationID: presentationID)
        let compact = Fingerprint(
            second: second,
            hash: sample.hash,
            energy: max(0, min(sample.energy, 4)),
            zeroCrossingRate: max(0, min(sample.zeroCrossingRate, 1))
        )
        if session.samplesBySecond[second] != compact {
            session.samplesBySecond[second] = compact
        }

        if session.marker == nil,
           let template = session.template,
           let marker = detectCurrentMarker(session: session, template: template) {
            session.marker = marker
        }

        sessions[presentationID] = session
        return session.marker
    }

    func currentMarker(item: MediaItem, presentationID: UUID) -> VODIntroMarker? {
        guard let identity = identity(for: item) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        loadArchiveIfNeededLocked()
        let session = sessionLocked(identity: identity, presentationID: presentationID)
        sessions[presentationID] = session
        return session.marker
    }

    /// vBRDC048: persist episode-specific community authority into the same tiny local
    /// learning session. This lets one known episode teach the next missing episode without
    /// ever trusting elapsed time alone; the next episode still has to match decoded audio.
    func registerTrustedEpisodeMarker(
        _ marker: VODIntroMarker,
        item: MediaItem,
        presentationID: UUID
    ) {
        guard marker.isStorySafe,
              marker.authorityRank >= 425,
              let identity = identity(for: item) else { return }
        lock.lock()
        defer { lock.unlock() }
        loadArchiveIfNeededLocked()
        var session = sessionLocked(identity: identity, presentationID: presentationID)
        if let existing = session.marker {
            if marker.authorityRank > existing.authorityRank ||
                (marker.authorityRank == existing.authorityRank && marker != existing) {
                session.marker = marker
            }
        } else {
            session.marker = marker
        }
        sessions[presentationID] = session
    }

    func finishSession(item: MediaItem, presentationID: UUID) {
        guard identity(for: item) != nil else { return }
        lock.lock()
        loadArchiveIfNeededLocked()
        let finished = sessions.removeValue(forKey: presentationID)
        if let finished { mergeSessionIntoArchiveLocked(finished) }
        let snapshot = archive
        lock.unlock()
        guard finished != nil else { return }

        // Make the completed episode available to the very next episode immediately in
        // memory, but never JSON-encode/write on the decoder or MainActor path. Snapshot
        // the value while locked, then perform encoding and atomic disk I/O without holding
        // the detector lock so an active decoder can never wait behind filesystem latency.
        persistenceQueue.async { [weak self] in
            self?.writeArchive(snapshot)
        }
    }

    func discardSession(presentationID: UUID) {
        lock.lock()
        sessions.removeValue(forKey: presentationID)
        lock.unlock()
    }

    // MARK: - Identity / session

    private struct EpisodeIdentity {
        let seriesKey: String
        let season: Int
        let episode: Int
    }

    private func identity(for item: MediaItem) -> EpisodeIdentity? {
        guard let season = item.seasonNumber, season > 0,
              let episode = item.episodeNumber, episode > 0 else { return nil }

        // CatalogStore episode records intentionally inherit the parent-series external IDs.
        // Prefer those stable IDs so the learned intro survives artwork/catalog/provider changes.
        // Fall back to the normalized visible parent title for sources that do not carry them.
        let imdb = item.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if imdb.range(of: #"^tt\d{5,12}$"#, options: .regularExpression) != nil {
            return EpisodeIdentity(seriesKey: "imdb:\(imdb)", season: season, episode: episode)
        }
        let tmdb = item.tmdbId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !tmdb.isEmpty {
            return EpisodeIdentity(seriesKey: "tmdb:\(tmdb)", season: season, episode: episode)
        }

        let parent = item.title
            .replacingOccurrences(of: #"\s+[sS]\d{1,2}[eE]\d{1,3}.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\d{1,2}x\d{1,3}.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !parent.isEmpty else { return nil }
        let normalizedYear = item.year.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return EpisodeIdentity(seriesKey: "title:\(parent)|year:\(normalizedYear)", season: season, episode: episode)
    }

    private func sessionLocked(identity: EpisodeIdentity, presentationID: UUID) -> Session {
        if let existing = sessions[presentationID] { return existing }
        let previous = archive.records
            .filter {
                $0.seriesKey == identity.seriesKey &&
                !($0.season == identity.season && $0.episode == identity.episode) &&
                !$0.samples.isEmpty
            }
            .sorted {
                let lhsSameSeason = $0.season == identity.season
                let rhsSameSeason = $1.season == identity.season
                if lhsSameSeason != rhsSameSeason { return lhsSameSeason && !rhsSameSeason }
                return $0.updatedAt > $1.updatedAt
            }

        // vBRDC048: one previously episode-verified opening (exact chapter or trusted public
        // episode timestamp) can seed the local audio matcher. The current episode still has
        // to match the real decoded audio before a marker is accepted, so this never becomes
        // an elapsed-time guess. Without a verified seed, preserve two-episode recurrence.
        let verifiedSeed = previous.lazy.compactMap { self.verifiedSeedTemplate(from: $0) }.first
        let recurringCandidates = previous.filter { $0.samples.count >= minimumTemplateSeconds }
        let template = verifiedSeed ?? learnTemplate(from: Array(recurringCandidates.prefix(4)))
        let marker = archive.records
            .first { $0.seriesKey == identity.seriesKey && $0.season == identity.season && $0.episode == identity.episode }?
            .marker
        return Session(
            seriesKey: identity.seriesKey,
            season: identity.season,
            episode: identity.episode,
            samplesBySecond: [:],
            marker: marker,
            template: template
        )
    }

    // MARK: - Local chapter authority

    private func storySafeChapterMarker(from chapters: [PlaybackChapterMarker]) -> VODIntroMarker? {
        let negativeTerms = [
            "cold open", "cold-open", "recap", "previously", "previously on", "prologue",
            "teaser", "prelude", "story", "scene", "act ", "chapter ", "part "
        ]
        let strongPositive = [
            "opening credits", "opening credit", "opening theme", "opening titles", "opening title",
            "title sequence", "main title", "main titles", "theme song", "opening sequence"
        ]

        for (index, chapter) in chapters.enumerated() {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = title.lowercased()
            guard !lower.isEmpty, !negativeTerms.contains(where: { lower.contains($0) }) else { continue }
            let normalizedWordCount = lower.split { !$0.isLetter && !$0.isNumber }.count
            let positive = strongPositive.contains(where: { lower.contains($0) }) ||
                ((lower == "intro" || lower == "introduction") && normalizedWordCount <= 2)
            guard positive else { continue }
            let marker = VODIntroMarker(
                startSeconds: max(0, chapter.startSeconds),
                endSeconds: chapter.endSeconds,
                title: title,
                confidence: "Local chapter • high",
                chapterIndex: index
            )
            if marker.isStorySafe { return marker }
        }
        return nil
    }

    // MARK: - Recurring fingerprint learning

    private func verifiedSeedTemplate(from record: EpisodeRecord) -> LearnedTemplate? {
        guard let marker = record.marker,
              marker.isStorySafe,
              marker.authorityRank >= 425 else { return nil }
        let lower = Int(floor(marker.startSeconds))
        let upper = Int(ceil(marker.endSeconds))
        let samples = record.samples
            .filter { $0.second >= lower && $0.second <= upper }
            .sorted { $0.second < $1.second }
        let bounded = Array(samples.prefix(maximumTemplateSeconds))
        guard bounded.count >= 10 else { return nil }
        let energetic = bounded.filter { $0.energy > 0.0025 }.count
        guard energetic >= Int(Double(bounded.count) * 0.65) else { return nil }
        return LearnedTemplate(
            samples: bounded,
            averageDistance: 0,
            confidence: marker.chapterIndex != nil
                ? "Prior verified opening + local audio • high"
                : "Prior episode timestamp + local audio • high",
            expectedStartSecond: Int(marker.startSeconds.rounded())
        )
    }

    private func learnTemplate(from records: [EpisodeRecord]) -> LearnedTemplate? {
        guard records.count >= 2 else { return nil }
        var best: LearnedTemplate?

        for leftIndex in 0..<(records.count - 1) {
            for rightIndex in (leftIndex + 1)..<records.count {
                let left = records[leftIndex].samples
                    .filter { $0.second <= maximumFingerprintSecond }
                    .sorted { $0.second < $1.second }
                let right = records[rightIndex].samples
                    .filter { $0.second <= maximumFingerprintSecond }
                    .sorted { $0.second < $1.second }
                guard left.count >= minimumTemplateSeconds, right.count >= minimumTemplateSeconds else { continue }

                // Longest common contiguous run under a conservative perceptual match.
                var previous = [Int](repeating: 0, count: right.count + 1)
                var bestLength = 0
                var bestLeftEnd = 0
                var bestRightEnd = 0

                for i in 1...left.count {
                    var current = [Int](repeating: 0, count: right.count + 1)
                    for j in 1...right.count {
                        let a = left[i - 1]
                        let b = right[j - 1]
                        if fingerprintsMatch(a, b) {
                            current[j] = previous[j - 1] + 1
                            if current[j] > bestLength {
                                bestLength = current[j]
                                bestLeftEnd = i
                                bestRightEnd = j
                            }
                        }
                    }
                    previous = current
                }

                guard bestLength >= minimumTemplateSeconds else { continue }
                let boundedLength = min(bestLength, maximumTemplateSeconds)
                let leftStart = max(0, bestLeftEnd - boundedLength)
                let rightStart = max(0, bestRightEnd - boundedLength)
                let leftSegment = Array(left[leftStart..<bestLeftEnd])
                let rightSegment = Array(right[rightStart..<bestRightEnd])
                guard leftSegment.count == rightSegment.count, leftSegment.count >= minimumTemplateSeconds else { continue }

                let leftStartSecond = leftSegment.first?.second ?? Int.max
                let rightStartSecond = rightSegment.first?.second ?? Int.max
                guard leftStartSecond <= maximumFingerprintSecond, rightStartSecond <= maximumFingerprintSecond else { continue }

                let energetic = leftSegment.filter { $0.energy > 0.0025 }.count
                guard energetic >= Int(Double(leftSegment.count) * 0.70) else { continue }

                let distance = zip(leftSegment, rightSegment)
                    .map { Double(($0.hash ^ $1.hash).nonzeroBitCount) }
                    .reduce(0, +) / Double(leftSegment.count)
                guard distance <= 11.5 else { continue }

                let candidate = LearnedTemplate(
                    samples: leftSegment,
                    averageDistance: distance,
                    confidence: "On-device recurring audio • high",
                    expectedStartSecond: Int((Double(leftStartSecond + rightStartSecond) / 2.0).rounded())
                )
                if best == nil || candidate.samples.count > best!.samples.count ||
                    (candidate.samples.count == best!.samples.count && candidate.averageDistance < best!.averageDistance) {
                    best = candidate
                }
            }
        }
        return best
    }

    private func detectCurrentMarker(session: Session, template: LearnedTemplate) -> VODIntroMarker? {
        guard template.samples.count >= guidedCurrentMatchSeconds else { return nil }
        let current = session.samplesBySecond
        guard let latest = current.keys.max(), latest <= maximumFingerprintSecond else { return nil }

        // Fast path: once a season has taught us approximately where its recurring opening
        // lands, seven strong seconds near that position are enough to surface the button.
        // This is still audio-confirmed — the expected position only narrows the search and
        // never creates a marker by elapsed time alone.
        if let expected = template.expectedStartSecond {
            let required = min(guidedCurrentMatchSeconds, template.samples.count)
            let lower = max(0, expected - guidedStartToleranceSeconds)
            let upper = min(maximumFingerprintSecond, expected + guidedStartToleranceSeconds)
            if let start = bestMatchStart(
                current: current,
                template: template,
                required: required,
                candidateLower: lower,
                candidateUpper: upper,
                maximumAverageDistance: 9.5,
                allowedMismatches: 1
            ) {
                return markerForMatchedStart(start, template: template)
            }
        }

        // General fallback: allow the opening to move far away from the learned location, but
        // require the original longer confirmation to keep false positives conservative.
        let required = min(minimumCurrentMatchSeconds, template.samples.count)
        guard current.count >= required else { return nil }
        let earliestCandidate = max(0, latest - 90)
        let latestCandidate = latest - required + 1
        guard latestCandidate >= earliestCandidate else { return nil }
        if let start = bestMatchStart(
            current: current,
            template: template,
            required: required,
            candidateLower: earliestCandidate,
            candidateUpper: latestCandidate,
            maximumAverageDistance: 11.0,
            allowedMismatches: 2
        ) {
            return markerForMatchedStart(start, template: template)
        }
        return nil
    }

    private func bestMatchStart(
        current: [Int: Fingerprint],
        template: LearnedTemplate,
        required: Int,
        candidateLower: Int,
        candidateUpper: Int,
        maximumAverageDistance: Double,
        allowedMismatches: Int
    ) -> Int? {
        guard required > 0, template.samples.count >= required else { return nil }
        let templateHead = Array(template.samples.prefix(required))
        let latestAvailable = current.keys.max() ?? -1
        let upper = min(candidateUpper, latestAvailable - required + 1)
        guard upper >= candidateLower else { return nil }

        var bestStart: Int?
        var bestMatches = 0
        var bestDistance = Double.greatestFiniteMagnitude

        for start in candidateLower...upper {
            var matches = 0
            var distanceTotal = 0.0
            var compared = 0
            for offset in 0..<required {
                guard let sample = current[start + offset] else { continue }
                let reference = templateHead[offset]
                compared += 1
                let distance = Double((sample.hash ^ reference.hash).nonzeroBitCount)
                distanceTotal += distance
                if fingerprintsMatch(sample, reference) { matches += 1 }
            }
            guard compared >= required - 1 else { continue }
            let averageDistance = distanceTotal / Double(compared)
            if matches > bestMatches || (matches == bestMatches && averageDistance < bestDistance) {
                bestMatches = matches
                bestDistance = averageDistance
                bestStart = start
            }
        }

        guard let bestStart,
              bestMatches >= required - allowedMismatches,
              bestDistance <= maximumAverageDistance else { return nil }
        return bestStart
    }

    private func markerForMatchedStart(_ start: Int, template: LearnedTemplate) -> VODIntroMarker? {
        let duration = min(Double(template.samples.count), Double(maximumTemplateSeconds))
        let marker = VODIntroMarker(
            startSeconds: Double(start),
            endSeconds: Double(start) + duration,
            title: "Recurring opening",
            confidence: template.confidence,
            chapterIndex: nil,
            provider: "local-audio"
        )
        return marker.isStorySafe ? marker : nil
    }

    private func fingerprintsMatch(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        guard a.energy > 0.0015, b.energy > 0.0015 else { return false }
        // Silence, near-constant tones and malformed samples can produce extremely sparse
        // or saturated hashes that collide too easily. A real temporal-energy fingerprint
        // should contain a healthy mix of zero/one bits before it can vote for an intro.
        let aBits = a.hash.nonzeroBitCount
        let bBits = b.hash.nonzeroBitCount
        guard (16...48).contains(aBits), (16...48).contains(bBits) else { return false }
        let distance = (a.hash ^ b.hash).nonzeroBitCount
        guard distance <= 13 else { return false }
        let energyA = log1p(Double(a.energy) * 100)
        let energyB = log1p(Double(b.energy) * 100)
        guard abs(energyA - energyB) <= 0.90 else { return false }
        return abs(Double(a.zeroCrossingRate - b.zeroCrossingRate)) <= 0.18
    }

    // MARK: - Persistence

    private var archiveURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base
            .appendingPathComponent("DebridChannels", isDirectory: true)
            .appendingPathComponent("LocalIntroFingerprints-v1.json", isDirectory: false)
    }

    private func loadArchiveIfNeededLocked() {
        guard !archiveLoaded else { return }
        archiveLoaded = true
        guard let url = archiveURL,
              let data = try? Data(contentsOf: url),
              data.count <= 8_000_000,
              let decoded = try? JSONDecoder().decode(Archive.self, from: data),
              decoded.schemaVersion == 1 else { return }
        archive = decoded
        boundArchiveLocked()
    }

    private func mergeSessionIntoArchiveLocked(_ session: Session) {
        let samples = session.samplesBySecond.values
            .filter { $0.second >= 0 && $0.second <= maximumFingerprintSecond }
            .sorted { $0.second < $1.second }
        guard !samples.isEmpty || session.marker != nil else { return }

        archive.records.removeAll {
            $0.seriesKey == session.seriesKey && $0.season == session.season && $0.episode == session.episode
        }
        archive.records.append(EpisodeRecord(
            seriesKey: session.seriesKey,
            season: session.season,
            episode: session.episode,
            samples: samples,
            marker: session.marker,
            updatedAt: Date()
        ))
        boundArchiveLocked()
    }

    private func boundArchiveLocked() {
        let sorted = archive.records.sorted { $0.updatedAt > $1.updatedAt }
        var counts: [String: Int] = [:]
        var kept: [EpisodeRecord] = []
        for record in sorted {
            let key = "\(record.seriesKey)|s\(record.season)"
            let count = counts[key, default: 0]
            guard count < maximumRecordsPerSeriesSeason else { continue }
            counts[key] = count + 1
            kept.append(record)
            if kept.count >= maximumRecords { break }
        }
        archive.records = kept
    }

    private func writeArchive(_ snapshot: Archive) {
        guard let url = archiveURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 8_000_000 else { return }
            try data.write(to: url, options: [.atomic])
        } catch {
            // Skip Intro learning is optional; persistence must never affect playback.
        }
    }
}


// MARK: - vBRDC045 app-side community segment authority

/// Resolves a known intro before it has to play. This is deliberately an Apple-TV-side
/// metadata lookup: only stable title identity (IMDb + S/E) is sent to public timestamp
/// services. Stream URLs, debrid credentials, headers, cookies, audio, and video never leave
/// the player. Embedded chapters remain highest authority because they describe the exact file.
actor AppSideIntroSegmentService {
    static let shared = AppSideIntroSegmentService()

    private struct CacheEntry {
        let marker: VODIntroMarker?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let positiveTTL: TimeInterval = 6 * 60 * 60
    private let negativeTTL: TimeInterval = 20 * 60

    private init() {}

    func marker(for item: MediaItem, durationSeconds: Double?) async -> VODIntroMarker? {
        guard let season = item.seasonNumber, season > 0,
              let episode = item.episodeNumber, episode > 0 else { return nil }

        let imdb = canonicalIMDbID(for: item)
        let tmdb = canonicalTMDbID(for: item)
        guard imdb != nil || tmdb != nil else { return nil }

        let durationBucket: Int = {
            guard let durationSeconds, durationSeconds.isFinite, durationSeconds >= 60 else { return 0 }
            return Int((durationSeconds / 5.0).rounded()) * 5
        }()
        let identity = imdb ?? tmdb.map { "tmdb:\($0)" } ?? "unknown"
        let key = "\(identity.lowercased()):\(season):\(episode):d\(durationBucket)"
        if let cached = cache[key], cached.expiresAt > Date() {
            return cached.marker
        }

        // vBRDC047: use three independent free general-TV timestamp databases plus AniSkip.
        // SkipDB and TheIntroDB both understand release duration; TheIntroDB can also use TMDb
        // when IMDb is absent. All requests are read-only and carry title identity only.
        async let skipDBMarker = fetchSkipDB(
            imdb: imdb,
            season: season,
            episode: episode,
            durationSeconds: durationSeconds
        )
        async let theIntroDBMarker = fetchTheIntroDB(
            imdb: imdb,
            tmdb: tmdb,
            season: season,
            episode: episode,
            durationSeconds: durationSeconds
        )
        async let introDBMarker = fetchIntroDB(imdb: imdb, season: season, episode: episode)
        async let aniSkipMarker = fetchAniSkip(
            imdb: imdb,
            season: season,
            episode: episode,
            durationSeconds: durationSeconds
        )

        let candidates = await [skipDBMarker, theIntroDBMarker, introDBMarker, aniSkipMarker].compactMap { $0 }
        let chosen = candidates.max { $0.authorityRank < $1.authorityRank }
        cache[key] = CacheEntry(
            marker: chosen,
            expiresAt: Date().addingTimeInterval(chosen == nil ? negativeTTL : positiveTTL)
        )
        return chosen
    }

    func prefetch(for item: MediaItem, durationSeconds: Double? = nil) async {
        _ = await marker(for: item, durationSeconds: durationSeconds)
    }

    private func fetchSkipDB(
        imdb: String?,
        season: Int,
        episode: Int,
        durationSeconds: Double?
    ) async -> VODIntroMarker? {
        guard let imdb else { return nil }
        var components = URLComponents(string: "https://api.skipdb.tv/api/segments")
        var queryItems = [
            URLQueryItem(name: "imdb_id", value: imdb),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        if let durationSeconds, durationSeconds.isFinite, durationSeconds >= 60, durationSeconds <= 6 * 60 * 60 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(durationSeconds.rounded()))))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let segments = root["segments"] as? [String: Any],
                  let intro = segments["intro"] as? [String: Any],
                  let startMs = number(intro["start_ms"]),
                  let endMs = number(intro["end_ms"]) else { return nil }

            let confidence = number(intro["confidence"]).map { value -> String in
                let percent = value <= 1 ? value * 100 : value
                return "\(Int(percent.rounded()))%"
            } ?? "community"
            let match = (intro["match"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let adjusted = (intro["adjusted"] as? Bool) == true
            let detail = [
                adjusted ? "duration-adjusted" : nil,
                match?.isEmpty == false ? match : nil,
                confidence
            ].compactMap { $0 }.joined(separator: " • ")

            let marker = VODIntroMarker(
                startSeconds: startMs / 1000.0,
                endSeconds: endMs / 1000.0,
                title: "Intro",
                confidence: "SkipDB \(detail)",
                chapterIndex: nil,
                provider: "skipdb"
            )
            return marker.isStorySafe ? marker : nil
        } catch {
            return nil
        }
    }

    private func fetchTheIntroDB(
        imdb: String?,
        tmdb: Int?,
        season: Int,
        episode: Int,
        durationSeconds: Double?
    ) async -> VODIntroMarker? {
        var components = URLComponents(string: "https://api.theintrodb.org/v3/media")
        var queryItems: [URLQueryItem] = []
        if let tmdb {
            queryItems.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
        } else if let imdb {
            queryItems.append(URLQueryItem(name: "imdb_id", value: imdb))
        } else {
            return nil
        }
        queryItems.append(URLQueryItem(name: "season", value: String(season)))
        queryItems.append(URLQueryItem(name: "episode", value: String(episode)))
        if let durationSeconds, durationSeconds.isFinite, durationSeconds >= 60, durationSeconds <= 6 * 60 * 60 {
            queryItems.append(URLQueryItem(name: "duration_ms", value: String(Int((durationSeconds * 1000).rounded()))))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let intros = root["intro"] as? [[String: Any]],
                  !intros.isEmpty else { return nil }

            for intro in intros {
                let start: Double
                if intro["start_ms"] is NSNull || intro["start_ms"] == nil {
                    start = 0
                } else if let ms = number(intro["start_ms"]) {
                    start = ms / 1000.0
                } else {
                    continue
                }
                guard let endMs = number(intro["end_ms"]) else { continue }
                let marker = VODIntroMarker(
                    startSeconds: start,
                    endSeconds: endMs / 1000.0,
                    title: "Intro",
                    confidence: durationSeconds == nil
                        ? "TheIntroDB community timestamp"
                        : "TheIntroDB release-matched timestamp",
                    chapterIndex: nil,
                    provider: "theintrodb"
                )
                if marker.isStorySafe { return marker }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func fetchIntroDB(imdb: String?, season: Int, episode: Int) async -> VODIntroMarker? {
        guard let imdb else { return nil }
        var components = URLComponents(string: "https://api.introdb.app/segments")
        components?.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdb),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let intro = root["intro"] as? [String: Any],
                  let start = secondsValue(intro["start_sec"], millisecondsFallback: intro["start_ms"]),
                  let end = secondsValue(intro["end_sec"], millisecondsFallback: intro["end_ms"]) else { return nil }

            let marker = VODIntroMarker(
                startSeconds: start,
                endSeconds: end,
                title: "Intro",
                confidence: confidenceLabel(intro["confidence"]),
                chapterIndex: nil,
                provider: "introdb"
            )
            return marker.isStorySafe ? marker : nil
        } catch {
            return nil
        }
    }

    private func fetchAniSkip(
        imdb: String?,
        season: Int,
        episode: Int,
        durationSeconds: Double?
    ) async -> VODIntroMarker? {
        guard let imdb, let malID = await resolveMyAnimeListID(imdb: imdb, season: season) else { return nil }

        let duration = durationSeconds.flatMap { value -> Int? in
            guard value.isFinite, value >= 60, value <= 6 * 60 * 60 else { return nil }
            return Int(value.rounded())
        } ?? 0

        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "op"),
            URLQueryItem(name: "types", value: "mixed-op"),
            URLQueryItem(name: "episodeLength", value: String(duration))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["found"] as? Bool) == true,
                  let results = root["results"] as? [[String: Any]] else { return nil }

            for result in results {
                let type = (result["skipType"] as? String)?.lowercased() ?? ""
                guard type == "op" || type == "mixed-op",
                      let interval = result["interval"] as? [String: Any],
                      let start = number(interval["startTime"]),
                      let end = number(interval["endTime"]) else { continue }
                let marker = VODIntroMarker(
                    startSeconds: start,
                    endSeconds: end,
                    title: "Intro",
                    confidence: "AniSkip community timestamp",
                    chapterIndex: nil,
                    provider: "aniskip"
                )
                if marker.isStorySafe { return marker }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func resolveMyAnimeListID(imdb: String, season: Int) async -> Int? {
        var components = URLComponents(string: "https://arm.haglund.dev/api/v2/imdb")
        components?.queryItems = [
            URLQueryItem(name: "id", value: imdb),
            URLQueryItem(name: "include", value: "myanimelist")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4.0)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !entries.isEmpty else { return nil }

            if season > 0, season - 1 < entries.count,
               let exact = intValue(entries[season - 1]["myanimelist"]) {
                return exact
            }
            return entries.compactMap { intValue($0["myanimelist"]) }.first
        } catch {
            return nil
        }
    }

    private func canonicalIMDbID(for item: MediaItem) -> String? {
        for raw in [item.imdbId, item.id] {
            guard let raw, !raw.isEmpty else { continue }
            let range = raw.range(of: #"tt\d{5,12}"#, options: [.regularExpression, .caseInsensitive])
            if let range { return String(raw[range]).lowercased() }
        }
        return nil
    }

    private func canonicalTMDbID(for item: MediaItem) -> Int? {
        for raw in [item.tmdbId, item.id] {
            guard let raw, !raw.isEmpty else { continue }
            let lower = raw.lowercased()
            if lower.range(of: #"^\d+$"#, options: .regularExpression) != nil, let value = Int(lower) {
                return value
            }
            if let range = lower.range(of: #"tmdb(?::|/|-)?(\d+)"#, options: .regularExpression) {
                let token = String(lower[range]).replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)
                if let value = Int(token) { return value }
            }
        }
        return nil
    }

    private func secondsValue(_ seconds: Any?, millisecondsFallback: Any?) -> Double? {
        if let value = number(seconds) { return value }
        if let ms = number(millisecondsFallback) { return ms / 1000.0 }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String {
            if let direct = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return direct }
            let parts = s.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func confidenceLabel(_ value: Any?) -> String {
        guard let confidence = number(value) else { return "IntroDB community timestamp" }
        let percent = confidence <= 1.0 ? confidence * 100 : confidence
        return "IntroDB \(Int(percent.rounded()))%"
    }
}
