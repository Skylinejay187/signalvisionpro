import Foundation

/// Durable scheduling and delivery policy for new-episode alerts.
///
/// RootView still owns tvOS focus and visual presentation. This manager owns the
/// persisted deadline, scan health journal, retry policy, and pending-delivery queue
/// so alerts survive scene changes and app relaunches without duplicate schedulers.
enum NewEpisodeAlertsManager {
    static let nextCheckedAtDefaultsKey = "newEpisodeAlertNextCheckedAt"
    static let lastCheckedAtDefaultsKey = "newEpisodeAlertLastCheckedAt"
    static let scanFrequencyDefaultsKey = "newEpisodeAlertScanFrequencyMinutes"
    static let scheduleStateDefaultsKey = "newEpisodeAlertScheduleState.v970"
    static let legacyScheduleStateDefaultsKey = "newEpisodeAlertScheduleState.v968"
    static let pendingAlertsDefaultsKey = "newEpisodeAlertPendingQueue.v968"
    static let defaultFrequencyMigrationKey = "newEpisodeAlertDefaultFiveMigration.v970"

    struct ScheduleState: Codable, Equatable {
        var version: Int = 2
        var frequencyRawValue: String = NewEpisodeAlertScanFrequency.five.rawValue
        var nextScanAt: Date? = nil
        var lastAttemptAt: Date? = nil
        var lastSuccessAt: Date? = nil
        var lastOutcome: String = "Never scanned"
        var consecutiveFailureCount: Int = 0
    }

    static func migrateDefaultFrequencyToFiveIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultFrequencyMigrationKey) else { return }
        defaults.set(NewEpisodeAlertScanFrequency.five.rawValue, forKey: scanFrequencyDefaultsKey)
        defaults.set(true, forKey: defaultFrequencyMigrationKey)
    }

    static func selectedScanFrequencyRawValue() -> String {
        UserDefaults.standard.string(forKey: scanFrequencyDefaultsKey) ?? NewEpisodeAlertScanFrequency.five.rawValue
    }

    static func selectedScanFrequencySeconds() -> Int {
        let raw = selectedScanFrequencyRawValue()
        let frequency = NewEpisodeAlertScanFrequency(rawValue: raw) ?? .five
        return Int(episodeAlertIntervalSeconds(for: frequency))
    }

    static func loadScheduleState() -> ScheduleState {
        if let data = UserDefaults.standard.data(forKey: scheduleStateDefaultsKey),
           var decoded = try? JSONDecoder().decode(ScheduleState.self, from: data) {
            let selected = selectedScanFrequencyRawValue()
            // A deadline created for a different interval is never authoritative.
            // This prevents a stale 10/30-minute deadline from silently overriding
            // a newly selected 5-minute interval after relaunch.
            if decoded.frequencyRawValue != selected {
                decoded.frequencyRawValue = selected
                decoded.nextScanAt = nil
            }
            return decoded
        }

        var state = ScheduleState()
        state.frequencyRawValue = selectedScanFrequencyRawValue()
        state.lastAttemptAt = UserDefaults.standard.object(forKey: lastCheckedAtDefaultsKey) as? Date

        // Preserve useful health history from v968, but intentionally do not migrate
        // its deadline. v970 rearms from the currently selected interval so an older
        // broken scheduler state cannot keep alerts dormant after launch.
        if let legacyData = UserDefaults.standard.data(forKey: legacyScheduleStateDefaultsKey),
           let legacy = try? JSONDecoder().decode(ScheduleState.self, from: legacyData) {
            state.lastAttemptAt = legacy.lastAttemptAt ?? state.lastAttemptAt
            state.lastSuccessAt = legacy.lastSuccessAt
            state.lastOutcome = legacy.lastOutcome
            state.consecutiveFailureCount = legacy.consecutiveFailureCount
        }
        return state
    }

    static func saveScheduleState(_ state: ScheduleState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: scheduleStateDefaultsKey)
        if let next = state.nextScanAt {
            UserDefaults.standard.set(next, forKey: nextCheckedAtDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: nextCheckedAtDefaultsKey)
        }
        if let attempt = state.lastAttemptAt {
            UserDefaults.standard.set(attempt, forKey: lastCheckedAtDefaultsKey)
        }
    }

    static func persistedNextScanAt() -> Date? {
        // v970 schedule state is authoritative. Legacy next-check dates are excluded
        // because they were produced by the scheduler that could fail to rearm.
        loadScheduleState().nextScanAt
    }

    static func recordDeadline(_ date: Date, frequencyRawValue: String) {
        var state = loadScheduleState()
        state.frequencyRawValue = frequencyRawValue
        state.nextScanAt = date
        saveScheduleState(state)
    }

    static func recordScanAttempt(at date: Date, reason: String) {
        var state = loadScheduleState()
        state.frequencyRawValue = selectedScanFrequencyRawValue()
        state.lastAttemptAt = date
        state.lastOutcome = "Running: \(reason)"
        saveScheduleState(state)
    }

    @discardableResult
    static func recordScanCompletion(success: Bool, partial: Bool, at date: Date, outcome: String) -> ScheduleState {
        var state = loadScheduleState()
        state.frequencyRawValue = selectedScanFrequencyRawValue()
        state.lastOutcome = outcome
        if success {
            state.lastSuccessAt = date
            state.consecutiveFailureCount = 0
        } else {
            state.consecutiveFailureCount += 1
        }
        if partial, success == false {
            state.lastOutcome = "Partial: \(outcome)"
        }
        saveScheduleState(state)
        return state
    }

    static func retryDelaySeconds(consecutiveFailureCount: Int) -> TimeInterval {
        switch max(1, consecutiveFailureCount) {
        case 1: return 60
        case 2: return 120
        default: return 300
        }
    }

    static func shouldRunImmediateCatchUp(now: Date, storedNext: Date?) -> Bool {
        guard let storedNext else { return true }
        return storedNext <= now
    }

    static func initialHeartbeatDelay(now: Date, storedNext: Date?, intervalSeconds: Int, runImmediateScan: Bool) -> TimeInterval {
        guard !runImmediateScan else { return 0 }
        guard let storedNext else { return TimeInterval(intervalSeconds) }
        let remaining = storedNext.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return min(remaining, TimeInterval(intervalSeconds))
    }

    static func sleepNanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    static func loadPendingAlerts() -> [NewEpisodeAlertHit] {
        guard let data = UserDefaults.standard.data(forKey: pendingAlertsDefaultsKey),
              let decoded = try? JSONDecoder().decode([NewEpisodeAlertHit].self, from: data) else { return [] }
        var seen = Set<String>()
        return decoded.filter { hit in
            guard !hit.alertKey.hasPrefix("developerEpisodeAlertTest::") else { return false }
            return seen.insert(hit.id).inserted
        }
    }

    static func savePendingAlerts(_ hits: [NewEpisodeAlertHit]) {
        var seen = Set<String>()
        let clean = hits.filter { hit in
            guard !hit.alertKey.hasPrefix("developerEpisodeAlertTest::") else { return false }
            return seen.insert(hit.id).inserted
        }
        if clean.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingAlertsDefaultsKey)
            return
        }
        let compact = clean.prefix(20).map(compactPersistedHit)
        guard let data = try? JSONEncoder().encode(compact) else { return }
        UserDefaults.standard.set(data, forKey: pendingAlertsDefaultsKey)
    }

    private static func compactPersistedHit(_ hit: NewEpisodeAlertHit) -> NewEpisodeAlertHit {
        var show = hit.show
        show.cast = []
        show.directors = []
        show.castMembers = []
        show.franchiseItems = []
        var episode = hit.episode
        episode.cast = []
        episode.directors = []
        episode.castMembers = []
        episode.franchiseItems = []
        return NewEpisodeAlertHit(alertKey: hit.alertKey, show: show, episode: episode)
    }

    static func mergePendingAlerts(_ hits: [NewEpisodeAlertHit]) -> [NewEpisodeAlertHit] {
        var merged = loadPendingAlerts()
        var ids = Set(merged.map(\.id))
        for hit in hits where ids.insert(hit.id).inserted {
            merged.append(hit)
        }
        savePendingAlerts(merged)
        return merged
    }

    static func removePendingAlert(id: String) {
        savePendingAlerts(loadPendingAlerts().filter { $0.id != id })
    }

    static let scheduleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func decorateScanReport(
        _ report: inout NewEpisodeAlertScanReport,
        periodicScannerEnabled: Bool,
        scanIntervalSeconds: TimeInterval,
        selectedScanFrequency: NewEpisodeAlertScanFrequency,
        selectedScanFrequencyRawValue: String,
        activeHeartbeatIntervalSeconds: Int,
        heartbeatTaskActive: Bool,
        heartbeatGeneration: Int,
        lastHeartbeatFiredAt: Date?,
        nextHeartbeatScanAt: Date?,
        lastScanReason: String,
        duplicateHeartbeatPreventedCount: Int,
        alertStyleDisplayName: String,
        bannerSideDisplayName: String,
        alertThemeDisplayName: String,
        bannerDurationSeconds: Int,
        lastRealScanAt: Date?,
        scanAlreadyRunning: Bool,
        displayedThisCycleCount: Int,
        remainingQueueCount: Int
    ) {
        let scheduleState = loadScheduleState()
        report.periodicScannerEnabled = periodicScannerEnabled
        report.scanIntervalMinutes = Int(scanIntervalSeconds / 60)
        report.scanFrequencyTestMode = selectedScanFrequency == .oneMinuteTest
        report.selectedScanFrequencyRawValue = selectedScanFrequencyRawValue
        report.selectedScanFrequencySeconds = selectedScanFrequencySeconds()
        report.activeHeartbeatIntervalSeconds = activeHeartbeatIntervalSeconds
        report.heartbeatTaskActive = heartbeatTaskActive
        report.heartbeatGeneration = heartbeatGeneration
        report.lastHeartbeatFiredTime = lastHeartbeatFiredAt.map(scheduleFormatter.string(from:)) ?? "None"
        report.nextScheduledScanTime = nextHeartbeatScanAt.map(scheduleFormatter.string(from:))
            ?? scheduleState.nextScanAt.map(scheduleFormatter.string(from:))
            ?? "None"
        report.lastScanReason = lastScanReason
        report.duplicateHeartbeatPreventedCount = duplicateHeartbeatPreventedCount
        report.alertStyleSetting = alertStyleDisplayName
        report.bannerSideSetting = bannerSideDisplayName
        report.alertThemeSetting = alertThemeDisplayName
        report.bannerDurationSeconds = bannerDurationSeconds
        report.lastScanTime = lastRealScanAt.map(scheduleFormatter.string(from:))
            ?? scheduleState.lastAttemptAt.map(scheduleFormatter.string(from:))
            ?? "None"
        if let next = scheduleState.nextScanAt {
            report.nextScanEstimate = scheduleFormatter.string(from: next)
        } else if let lastRealScanAt {
            report.nextScanEstimate = scheduleFormatter.string(from: lastRealScanAt.addingTimeInterval(scanIntervalSeconds))
        } else {
            report.nextScanEstimate = periodicScannerEnabled ? "Pending first scan" : "None"
        }
        report.scanAlreadyRunning = scanAlreadyRunning
        report.displayedThisCycleCount = displayedThisCycleCount
        report.remainingQueueCount = remainingQueueCount
        report.persistentQueueCount = loadPendingAlerts().count
        report.scheduleConsecutiveFailureCount = scheduleState.consecutiveFailureCount
        if report.scanOutcome == "Not run" {
            report.scanOutcome = scheduleState.lastOutcome
        }
    }

    static func makeDeveloperAlert(now: Date = Date()) -> NewEpisodeAlertHit {
        let show = MediaItem(
            id: "developer-new-episode-alert-show",
            title: "Developer Alert Test",
            year: "2026",
            type: "series",
            catalog: "Follow Center",
            description: "Temporary developer-only test alert generated from Follow Center.",
            genres: ["Debug", "New Episode"],
            rating: "",
            posterURL: "",
            landscapeURL: nil,
            logoURL: nil,
            previewURL: nil
        )
        let episode = MediaItem(
            id: "developer-new-episode-alert-episode-\(Int(now.timeIntervalSince1970))",
            title: "Real Overlay Path Test",
            year: "2026",
            type: "episode",
            catalog: "Follow Center",
            description: "This temporary alert uses the same root overlay state as scanner-detected new episode alerts.",
            genres: ["Debug", "New Episode"],
            rating: "",
            posterURL: "",
            landscapeURL: nil,
            logoURL: nil,
            previewURL: nil,
            seasonNumber: 1,
            episodeNumber: 1,
            airDateString: Self.iso8601DayString(from: now)
        )
        return NewEpisodeAlertHit(
            alertKey: "developerEpisodeAlertTest::\(episode.id)",
            show: show,
            episode: episode
        )
    }

    private static func iso8601DayString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return String(formatter.string(from: date).prefix(10))
    }
}
