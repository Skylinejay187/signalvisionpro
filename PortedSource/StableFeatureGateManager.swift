import Foundation

/// Phase 0 release protection for features that are not part of the verified stable UI.
///
/// Every feature flag is versioned, defaults to disabled, and is migrated before the
/// rest of the app reads settings. The manager owns only experimental flags and a small
/// allowlist of presentation defaults; account, provider, favorites, progress, Live TV,
/// and episode-alert data are never removed by these operations.
enum StableFeatureGateManager {
    static let schemaVersion = 2

    private static let schemaKey = "experimentalFeatureSchemaVersion.v1"
    private static let stableDefaultsVersionKey = "stableUIDefaultsVersion.v1"
    private static let emergencyRollbackDateKey = "experimentalPlaybackEmergencyRollbackDate.v1"
    private static let emergencyRollbackReasonKey = "experimentalPlaybackEmergencyRollbackReason.v1"

    enum Feature: String, CaseIterable {
        case playbackHealthPanel = "feature.playbackHealthPanel.v1"
        case alternateAudioMaster = "feature.alternateAudioMaster.v1"
        case alternateAudioDiscovery = "feature.alternateAudioDiscovery.v1"
        case alternateAudioBridge = "feature.alternateAudioBridge.v1"
        case alternateAudioHandoff = "feature.alternateAudioHandoff.v1"
        case catalogHealthSection = "feature.catalogHealthSection.v1"
        case automaticSourceFailover = "feature.automaticSourceFailover.v1"
        case perTitlePlaybackMemory = "feature.perTitlePlaybackMemory.v1"
        case upNextEpisodeIntelligence = "feature.upNextEpisodeIntelligence.v1"
        case bridgeLifecycleControls = "feature.bridgeLifecycleControls.v1"
        case secureBridgePlayback = "feature.secureBridgePlayback.v1"
        case codecCompatibilityOptimizations = "feature.codecCompatibilityOptimizations.v1"
        case bridgeRecoveryDiagnostics = "feature.bridgeRecoveryDiagnostics.v1"
        case stagedRolloutControls = "feature.stagedRolloutControls.v1"
        case accessibilityUXPolish = "feature.accessibilityUXPolish.v1"

        var isPlaybackFeature: Bool {
            switch self {
            case .playbackHealthPanel,
                 .catalogHealthSection,
                 .accessibilityUXPolish:
                return false
            case .alternateAudioMaster,
                 .alternateAudioDiscovery,
                 .alternateAudioBridge,
                 .alternateAudioHandoff,
                 .automaticSourceFailover,
                 .perTitlePlaybackMemory,
                 .upNextEpisodeIntelligence,
                 .bridgeLifecycleControls,
                 .secureBridgePlayback,
                 .codecCompatibilityOptimizations,
                 .bridgeRecoveryDiagnostics,
                 .stagedRolloutControls:
                return true
            }
        }
    }

    struct StableUIDefault {
        let key: String
        let value: Any
    }

    /// The verified v1089 presentation baseline. This is intentionally an allowlist.
    /// It does not contain identity, entitlement, provider, catalog, favorite, progress,
    /// Live TV source, backup, or episode-alert keys.
    private static let stableUIDefaults: [StableUIDefault] = [
        StableUIDefault(key: "gridLockedMode", value: false),
        StableUIDefault(key: "popupFontPreset", value: "SF Rounded"),
        StableUIDefault(key: "topMenuThemePreset", value: "Classic"),
        StableUIDefault(key: "topMenuAccentColor", value: "Orange"),
        StableUIDefault(key: "topMenuFontPreset", value: "SF Rounded"),
        StableUIDefault(key: "homeGridThemePreset", value: "Classic Glow"),
        StableUIDefault(key: "catalogRowScrollingAnimationPreset", value: "Native Smooth"),
        StableUIDefault(key: "focusedCardPreviewsEnabled", value: false),
        StableUIDefault(key: "liveTVGridThemePreset", value: "Classic Dark"),
        StableUIDefault(key: "liveTVGridProgramProgressEnabled", value: true),
        StableUIDefault(key: "liveTVGridFocusPreviewEnabledV1", value: true),
        StableUIDefault(key: "liveTVGridFocusPreviewDurationV1", value: "15 Seconds"),
        StableUIDefault(key: "liveTVGridDimOthersDuringPreviewV1", value: true),
        StableUIDefault(key: "liveTVGridFocusRingColorV1", value: "White"),
        StableUIDefault(key: "liveTVGridFocusRingMotionV1", value: "Classic Glow"),
        StableUIDefault(key: "liveTVCardArtworkStyle", value: "frosted"),
        StableUIDefault(key: "liveTVAnimatedHeaderLogoEnabledV1", value: true),
        StableUIDefault(key: "liveTVAnimatedHeaderLogoStyleV1", value: "Signal TV"),
        StableUIDefault(key: "liveTVGridLayoutStyleV1", value: "Current"),
        StableUIDefault(key: "launchAppInGuide", value: false),
        StableUIDefault(key: "showMediaInfoPortraitPoster", value: true),
        StableUIDefault(key: "connectedMediaPopupArtworkEnabled", value: false),
        StableUIDefault(key: "mediaInfoConnectorLineEnabledV1", value: true),
        StableUIDefault(key: "topLeftDebridChannelsLogoEnabledV1", value: true),
        StableUIDefault(key: "topBarMediaInfoLayout", value: "Center"),
        StableUIDefault(key: "mediaInfoTopBarTransparency", value: "Solid"),
        StableUIDefault(key: "advisoryDisplayEnabled", value: true),
        StableUIDefault(key: "vodInternalPlayerEngine", value: "ksplayer"),
        StableUIDefault(key: "vodControlsDockStyle", value: "visible"),
        StableUIDefault(key: "vodControlShelfMode", value: "hidden"),
        StableUIDefault(key: "vodControlShelfAutoHideSeconds", value: 5),
        StableUIDefault(key: "vodControlShelfLastExpanded", value: false),
        StableUIDefault(key: "vodProductionRatingsPanelEnabled", value: false),
        StableUIDefault(key: "vodCollectorShowcasePanelEnabledV1", value: false),
        StableUIDefault(key: "vodPortraitPosterThemedLogoEnabledV1", value: false),
        StableUIDefault(key: "vodProductionRatingsThemedLogoEnabledV1", value: false),
        StableUIDefault(key: "liveTVPlaybackGuideModeV1", value: "quick"),
        StableUIDefault(key: "trailerEngineMode", value: "auto"),
    ]

    @discardableResult
    static func performSafeMigrations(defaults: UserDefaults = .standard) -> [String] {
        let storedVersion = defaults.integer(forKey: schemaKey)
        guard storedVersion < schemaVersion else { return [] }

        var changes: [String] = []

        // v1098 lifecycle stabilization: earlier development builds automatically enabled
        // Alternate Audio when Scan/Prepare was pressed. Fail closed exactly once on upgrade
        // so no ffprobe/ffmpeg work can resume until the user explicitly turns the new master
        // switch back On. This does not touch accounts, providers, favorites, or progress.
        if storedVersion < 2 {
            defaults.set(false, forKey: Feature.alternateAudioMaster.rawValue)
            defaults.set(false, forKey: Feature.alternateAudioDiscovery.rawValue)
            defaults.set(false, forKey: Feature.alternateAudioBridge.rawValue)
            defaults.set(false, forKey: Feature.alternateAudioHandoff.rawValue)
            changes.append("Alternate Audio reset Off for lifecycle-safe opt-in")
        }

        // vBRDC297: migrate the old shipped catalog-motion default exactly once. Existing
        // installs commonly carry an explicit "Classic Spring" value because stable UI
        // restore persisted the former default. Move only that legacy/default value to the
        // new no-overshoot Native Smooth curve; after this marker is set, a user may freely
        // choose Classic Spring again and it will never be rewritten.
        let nativeCatalogMotionMigrationKey = "catalogMotionNativeDefaultMigration.v297"
        if !defaults.bool(forKey: nativeCatalogMotionMigrationKey) {
            let currentMotion = defaults.string(forKey: "catalogRowScrollingAnimationPreset")
            if currentMotion == nil || currentMotion == "Classic Spring" {
                defaults.set("Native Smooth", forKey: "catalogRowScrollingAnimationPreset")
                changes.append("catalog row motion migrated to Native Smooth")
            }
            defaults.set(true, forKey: nativeCatalogMotionMigrationKey)
        }

        // Future/experimental values must never become enabled merely because an older
        // build wrote an unversioned placeholder key. Only the versioned keys below are
        // authoritative, and absent values are explicitly initialized to false.
        for feature in Feature.allCases where defaults.object(forKey: feature.rawValue) == nil {
            defaults.set(false, forKey: feature.rawValue)
        }

        // Normalize any non-Boolean payloads that may have been written by development
        // builds. This migration is deliberately fail-closed.
        for feature in Feature.allCases {
            let value = defaults.object(forKey: feature.rawValue)
            if value != nil, !(value is Bool) {
                defaults.set(false, forKey: feature.rawValue)
                changes.append("normalized \(feature.rawValue)")
            }
        }

        defaults.set(schemaVersion, forKey: schemaKey)
        changes.append("experimental feature schema v\(schemaVersion)")
        return changes
    }

    static func isEnabled(_ feature: Feature, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: feature.rawValue) != nil else { return false }
        return defaults.bool(forKey: feature.rawValue)
    }

    static func setEnabled(_ enabled: Bool, for feature: Feature, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: feature.rawValue)
    }

    @discardableResult
    static func disableAllExperimentalFeatures(defaults: UserDefaults = .standard) -> Int {
        var changed = 0
        for feature in Feature.allCases {
            if defaults.bool(forKey: feature.rawValue) { changed += 1 }
            defaults.set(false, forKey: feature.rawValue)
        }
        return changed
    }

    @discardableResult
    static func disableExperimentalPlaybackFeatures(defaults: UserDefaults = .standard) -> Int {
        var changed = 0
        for feature in Feature.allCases where feature.isPlaybackFeature {
            if defaults.bool(forKey: feature.rawValue) { changed += 1 }
            defaults.set(false, forKey: feature.rawValue)
        }
        return changed
    }

    @discardableResult
    static func restoreStableUIDefaults(defaults: UserDefaults = .standard) -> Int {
        var changed = 0
        for entry in stableUIDefaults {
            if !valuesEqual(defaults.object(forKey: entry.key), entry.value) { changed += 1 }
            defaults.set(entry.value, forKey: entry.key)
        }
        changed += disableAllExperimentalFeatures(defaults: defaults)
        defaults.set(schemaVersion, forKey: stableDefaultsVersionKey)
        return changed
    }

    static func recordEmergencyPlaybackRollback(reason: String, defaults: UserDefaults = .standard) {
        defaults.set(Date().timeIntervalSince1970, forKey: emergencyRollbackDateKey)
        defaults.set(String(reason.prefix(240)), forKey: emergencyRollbackReasonKey)
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        switch (lhs, rhs) {
        case let (left as Bool, right as Bool): return left == right
        case let (left as Int, right as Int): return left == right
        case let (left as NSNumber, right as Int): return left.intValue == right
        case let (left as String, right as String): return left == right
        default: return false
        }
    }
}
