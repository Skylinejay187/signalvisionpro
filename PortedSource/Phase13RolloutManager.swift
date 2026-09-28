import Foundation

/// Phase 13 staged-rollout and release-gate ownership.
///
/// This manager deliberately does not turn experimental playback features on by itself.
/// It records the current rollout lane, owns the emergency kill switch, and provides a
/// single fail-closed policy that can disable experimental playback without touching
/// accounts, favorites, watch progress, providers, Live TV sources, or episode alerts.
enum Phase13RolloutManager {
    static let migrationVersion = 2

    enum ReleaseChannel: String, CaseIterable, Codable {
        case internalTesting = "internal-testing"
        case beta = "beta"
        case stable = "stable"

        var displayName: String {
            switch self {
            case .internalTesting: return "Internal Testing"
            case .beta: return "Beta"
            case .stable: return "Stable"
            }
        }
    }

    struct Snapshot: Codable, Equatable {
        let channel: ReleaseChannel
        let emergencyKillSwitchEnabled: Bool
        let lastValidatedBuild: String
        let lastRollbackReason: String?
        let lastRollbackDate: TimeInterval?
        let acceptanceMatrixVersion: Int
    }

    private static let migrationKey = "phase13.rolloutMigrationVersion.v1"
    private static let channelKey = "phase13.releaseChannel.v1"
    private static let killSwitchKey = "phase13.emergencyPlaybackKillSwitch.v1"
    private static let lastRollbackReasonKey = "phase13.lastRollbackReason.v1"
    private static let lastRollbackDateKey = "phase13.lastRollbackDate.v1"
    private static let lastValidatedBuildKey = "phase13.lastValidatedBuild.v1"
    private static let acceptanceMatrixVersionKey = "phase13.acceptanceMatrixVersion.v1"

    // Phase 15 final production acceptance contract. Revision 2 adds the interactive
    // Cast Explorer, confirmed VOD title/episode switching, full episode search, and
    // VOD-only amplification checks without auto-promoting this candidate.
    static let acceptanceMatrixVersion = 2

    @discardableResult
    static func performSafeMigration(defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.integer(forKey: migrationKey)
        guard stored < migrationVersion else { return [] }

        var changes: [String] = []
        if let raw = defaults.string(forKey: channelKey), ReleaseChannel(rawValue: raw) == nil {
            defaults.set(ReleaseChannel.internalTesting.rawValue, forKey: channelKey)
            changes.append("invalid rollout channel reset to Internal Testing")
        } else if defaults.string(forKey: channelKey) == nil {
            // A development candidate may never silently promote itself to Stable.
            defaults.set(ReleaseChannel.internalTesting.rawValue, forKey: channelKey)
            changes.append("rollout channel initialized to Internal Testing")
        }

        if defaults.object(forKey: killSwitchKey) == nil {
            defaults.set(false, forKey: killSwitchKey)
        }
        defaults.set(acceptanceMatrixVersion, forKey: acceptanceMatrixVersionKey)
        defaults.set(currentBuildNumber(), forKey: lastValidatedBuildKey)
        defaults.set(migrationVersion, forKey: migrationKey)
        changes.append("Phase 13 rollout schema v\(migrationVersion)")
        return changes
    }

    static func currentChannel(defaults: UserDefaults = .standard) -> ReleaseChannel {
        guard let raw = defaults.string(forKey: channelKey), let channel = ReleaseChannel(rawValue: raw) else {
            return .internalTesting
        }
        return channel
    }

    /// Phase 15 is the only phase expected to promote a release candidate to Stable.
    /// This setter exists for the controlled release workflow and never enables features.
    static func setChannel(_ channel: ReleaseChannel, defaults: UserDefaults = .standard) {
        defaults.set(channel.rawValue, forKey: channelKey)
        defaults.set(currentBuildNumber(), forKey: lastValidatedBuildKey)
    }

    static func emergencyKillSwitchEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: killSwitchKey)
    }

    static func setEmergencyKillSwitch(_ enabled: Bool, reason: String? = nil, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: killSwitchKey)
        guard enabled else { return }
        let cleanReason = sanitizedReason(reason ?? "Manual Phase 13 emergency playback kill switch")
        defaults.set(cleanReason, forKey: lastRollbackReasonKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastRollbackDateKey)
        StableFeatureGateManager.recordEmergencyPlaybackRollback(reason: cleanReason, defaults: defaults)
        _ = StableFeatureGateManager.disableExperimentalPlaybackFeatures(defaults: defaults)
    }

    /// Apply an already-enabled kill switch at launch before any experimental playback
    /// feature can resume. User data and presentation preferences remain untouched.
    @discardableResult
    static func applyEmergencyKillSwitchIfNeeded(defaults: UserDefaults = .standard) -> Int {
        guard emergencyKillSwitchEnabled(defaults: defaults) else { return 0 }
        let changed = StableFeatureGateManager.disableExperimentalPlaybackFeatures(defaults: defaults)
        let reason = sanitizedReason(defaults.string(forKey: lastRollbackReasonKey) ?? "Phase 13 emergency playback kill switch")
        StableFeatureGateManager.recordEmergencyPlaybackRollback(reason: reason, defaults: defaults)
        return changed
    }

    /// Unrecoverable experimental handoff failures are already restored to the immutable
    /// original playback URL by the VOD session. Phase 13 records that event for release
    /// gating without automatically promoting or changing user-selected feature flags.
    static func recordUnrecoverablePlaybackFailure(_ reason: String, defaults: UserDefaults = .standard) {
        defaults.set(sanitizedReason(reason), forKey: lastRollbackReasonKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastRollbackDateKey)
    }

    static func snapshot(defaults: UserDefaults = .standard) -> Snapshot {
        Snapshot(
            channel: currentChannel(defaults: defaults),
            emergencyKillSwitchEnabled: emergencyKillSwitchEnabled(defaults: defaults),
            lastValidatedBuild: defaults.string(forKey: lastValidatedBuildKey) ?? currentBuildNumber(),
            lastRollbackReason: defaults.string(forKey: lastRollbackReasonKey),
            lastRollbackDate: defaults.object(forKey: lastRollbackDateKey) == nil ? nil : defaults.double(forKey: lastRollbackDateKey),
            acceptanceMatrixVersion: max(defaults.integer(forKey: acceptanceMatrixVersionKey), acceptanceMatrixVersion)
        )
    }

    static let acceptanceTestNames: [String] = [
        "Normal VOD startup and first frame",
        "Original source rollback after experimental failure",
        "Automatic source failover remains pre-first-frame only",
        "Alternate Audio prepare, handoff, restore and cancellation",
        "Embedded audio and subtitle switching",
        "Subtitle delay and per-title playback memory",
        "Resume persistence and repeated seeking",
        "Up Next exact episode ownership",
        "Search and Favorites focus restoration",
        "Live TV guide, Gracenote persistence and playback",
        "Trailer playback and audio",
        "Episode alerts during VOD and Live TV",
        "Phase 11 codec compatibility regression",
        "Phase 12 diagnostics and recovery",
        "Long-session memory plateau",
        "Backend restart and secure bridge recovery",
        "Cast Explorer credit search, details navigation and VOD switch confirmation",
        "Full episode browser search/filter and exact episode handoff",
        "VOD volume amplification Off/+3/+6/+9/+12 dB and Live TV/trailer isolation",
        "Cancelled VOD cross-title switch leaves current presentation paused and unchanged",
        "Feature kill switch and stable rollback"
    ]

    private static func currentBuildNumber() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private static func sanitizedReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Unspecified playback failure" : trimmed).prefix(320))
    }
}
