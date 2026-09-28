import Foundation

/// Release-candidate migration, profile-backup compatibility, and diagnostic redaction.
///
/// Profile backup is an explicit user action protected by a reusable restore code.
/// It must preserve the operational configuration needed on a replacement Apple TV,
/// including user-entered Live TV sources and provider credentials. Internal catalog
/// endpoints, entitlement state, owner state, diagnostics, and release-only values are
/// still excluded.
enum ReleaseCandidateSecurityManager {
    static let migrationVersion = 1

    private static let migrationKey = "releaseCandidateSecurityMigrationVersion"
    private static let credentialBoundaryDefaultsKey = "credentialInstallBoundaryV1"
    private static let credentialBoundarySentinelName = ".debridchannels-credential-install-v1"
    private static let publicBackendURL = "https://api.skylinejay187.it.com"
    private static let cinematetaManifestURL = "https://v3-cinemeta.strem.io/manifest.json"

    private static let officialCatalogMarkers = [
        "catalog.skylinejay187.it.com",
        "192.168.100.55:8484",
        "catalog.debridchannels"
    ]

    private static let sensitiveNames: Set<String> = [
        "api_key", "apikey", "api-key", "api_password", "key", "token", "access_token",
        "auth", "authorization", "password", "pass", "username", "user",
        "realdebrid", "real_debrid", "torbox", "premiumize", "alldebrid", "debridlink", "easydebrid", "offcloud", "putio"
    ]

    /// Enforces an app-install lifetime for user credentials. Apple Keychain items can
    /// survive app deletion, so a fresh Debrid Channels installation must explicitly
    /// clear secrets left by the previous installation. A legacy vBRDC069-or-earlier
    /// installation is bootstrapped without clearing so normal upgrades remain seamless.
    @discardableResult
    private static func enforceFreshInstallCredentialBoundary(defaults: UserDefaults) -> [String] {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let sentinel = support.appendingPathComponent(credentialBoundarySentinelName, isDirectory: false)
        if fileManager.fileExists(atPath: sentinel.path) {
            defaults.set(1, forKey: credentialBoundaryDefaultsKey)
            return []
        }

        let boundaryWasPreviouslyEstablished = defaults.integer(forKey: credentialBoundaryDefaultsKey) >= 1
        let legacyInstallEvidence = defaults.object(forKey: migrationKey) != nil
            || defaults.object(forKey: "lastValidatedReleaseBuild") != nil
            || defaults.object(forKey: "stremioManifestURLs") != nil
            || defaults.object(forKey: "hasSeenFirstRunOnboarding") != nil

        var changes: [String] = []
        if boundaryWasPreviouslyEstablished || !legacyInstallEvidence {
            // This is either a true fresh install or a post-vBRDC070 reinstall/restore whose
            // non-backed-up install sentinel is gone. Do not inherit any old account/source
            // credential simply because Keychain or system-restored defaults survived.
            let credentialDefaults = [
                "stremioManifestURL", "stremioManifestURLs",
                "liveChannelsDvrBaseURL", "liveHDHomeRunManualURL", "liveHDHomeRunManualGuideURL",
                "liveM3UURL", "liveXMLTVURL", "liveXtreamServer", "liveXtreamUsername",
                "liveXtreamPassword", "liveXtreamAccounts", "liveXtreamLoginStatus",
                "sportsCustomSourcesJSON",
                "tmdbApiKey", "omdbApiKey", "fanartTvApiKey", "tvdbApiToken",
                "torrentioRealDebridApiKey", "torrentioTorBoxApiKey", "torBoxApiKey", "torBoxUsenetBridgeManifestURLV1", "realDebridApiKey",
                "premiumizeApiKey", "allDebridApiKey", "debridLinkApiKey", "easyDebridApiKey", "offcloudApiKey",
                "putioClientID", "putioToken", "managedTorrentioEnabled",
                "managedTorrentioEnabled.realdebrid.v1", "managedTorrentioEnabled.torbox.v1",
                "managedTorrentioEnabled.premiumize.v1", "managedTorrentioEnabled.alldebrid.v1",
                "managedTorrentioEnabled.debridlink.v1", "managedTorrentioEnabled.easydebrid.v1",
                "managedTorrentioEnabled.offcloud.v1", "managedTorrentioEnabled.putio.v1",
                "optionalFebBoxEnabledV1",
                "mediaFlowProxyEnabledV1", "mediaFlowProxyURLV1", "mediaFlowProxyPublicIPV1",
                "mediaFlowWebBrowserPlaybackV1", "debridNowShowingServerURLV1", "debridNowShowingPushTokenV1",
                "mediaFlowLastDetectedIPV1", "mediaFlowLastStatusV1",
                "mediaFlowLastTestDateV1", "mediaFlowLastVerifiedV1",
                "backendProfileBackupCode", "backendProfileBackupLastDate",
                "backendProfileBackupLastStatus", "backendProfileBackupPayloadSize"
            ]
            for key in credentialDefaults { defaults.removeObject(forKey: key) }

            _ = BackupStreamingCredentialStore.purgeForFreshInstall()
            _ = MediaFlowCredentialStore.purgeForFreshInstall()
            _ = NuvioPluginPreferences.purgeForFreshInstall(defaults: defaults)
            changes.append("fresh-install user credentials cleared")
        }

        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try Data("v1".utf8).write(to: sentinel, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var sentinelURL = sentinel
            try? sentinelURL.setResourceValues(values)
            defaults.set(1, forKey: credentialBoundaryDefaultsKey)
        } catch {
            // Do not block startup if the marker cannot be written. Credentials were already
            // handled above; the next launch will safely re-evaluate the boundary.
        }
        return changes
    }

    /// Runs before CatalogStore reads persisted manifests. It is idempotent and
    /// preserves every user preference that is not an obsolete internal endpoint.
    @discardableResult
    static func performUpgradeMigration(defaults: UserDefaults = .standard) -> [String] {
        var boundaryChanges = enforceFreshInstallCredentialBoundary(defaults: defaults)
        let storedVersion = defaults.integer(forKey: migrationKey)
        guard storedVersion < migrationVersion else { return boundaryChanges }

        var changes: [String] = boundaryChanges

        let savedManifests = defaults.stringArray(forKey: "stremioManifestURLs") ?? []
        let cleanedManifests = sanitizedSavedManifestURLs(savedManifests)
        if cleanedManifests != savedManifests {
            defaults.set(cleanedManifests, forKey: "stremioManifestURLs")
            changes.append("saved catalog list repaired")
        }

        if let primary = defaults.string(forKey: "stremioManifestURL"), isOfficialCatalogURL(primary) {
            defaults.set(cinematetaManifestURL, forKey: "stremioManifestURL")
            changes.append("legacy official catalog entry removed")
        }

        if let backend = defaults.string(forKey: "backendBaseURL")?.trimmingCharacters(in: .whitespacesAndNewlines),
           backend.isEmpty || backend.lowercased().contains("192.168.100.55:8181") {
            defaults.set(publicBackendURL, forKey: "backendBaseURL")
            changes.append("legacy backend migrated to public HTTPS")
        }

        defaults.set(migrationVersion, forKey: migrationKey)
        defaults.set(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown", forKey: "lastValidatedReleaseBuild")
        return changes
    }

    static func sanitizedSavedManifestURLs(_ urls: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for raw in urls {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !isOfficialCatalogURL(clean), let url = URL(string: clean),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { continue }
            let key = clean.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { continue }
            output.append(clean)
        }
        if !output.contains(where: { $0.lowercased().contains("v3-cinemeta.strem.io") }) {
            output.append(cinematetaManifestURL)
        }
        return output
    }

    /// User-saved add-on manifests are part of a full profile backup, including
    /// configured URLs that carry the user's own provider token. The hidden official
    /// catalog endpoint is never exported.
    static func cloudBackupManifestURLs(_ urls: [String]) -> [String] {
        sanitizedSavedManifestURLs(urls)
    }

    /// Kept for decoding Phase 8/9 call sites and old tests. Full profile backup now
    /// intentionally preserves credential-bearing user manifests.
    static func cloudBackupSafeManifestURLs(_ urls: [String]) -> [String] {
        cloudBackupManifestURLs(urls)
    }

    static func sanitizedRestoredSettings(_ raw: [String: Any]) -> [String: Any] {
        // Explicit application-configuration allowlist. This includes credentials by
        // design because a restore code is expected to rebuild a replacement Apple TV.
        // Entitlement, owner, diagnostics, migration, and backup bookkeeping keys are
        // deliberately absent.
        let allowedKeys: Set<String> = [
            // Catalogs and add-ons
            "stremioManifestURL", "stremioManifestURLs",
            "allInOneCatalogsEnabled",
            "builtInCatalogHiddenRowIDs.v1009", "builtInCatalogCustomRowOrder.v1009",

            // Live TV source configuration and organization
            "liveChannelsDvrBaseURL", "liveHDHomeRunManualURL", "liveHDHomeRunManualGuideURL",
            "liveM3UURL", "liveXMLTVURL",
            "liveXtreamServer", "liveXtreamUsername", "liveXtreamPassword", "liveXtreamAccounts",
            "liveXtreamLoginStatus", "sportsXtreamImportMode",
            "sportsAssignedGroups", "sportsFavoriteTeams", "sportsCustomSourcesJSON",
            "myFavoriteChannelIds", "sportsManualChannelIds",
            "sportsExcludedChannelIds", "sportsExcludedChannelNames",
            "sportsScoreTickerEnabled", "sportsTickerPosition", "moviesShowsReleaseTickerEnabled",

            // Source Intelligence, debrid/add-on providers, and artwork metadata providers
            "backendBaseURL", "tmdbApiKey", "omdbApiKey", "fanartTvApiKey", "tvdbApiToken",
            "torrentioRealDebridApiKey", "torrentioTorBoxApiKey", "torBoxApiKey", "torBoxUsenetBridgeManifestURLV1", "realDebridApiKey",
            "premiumizeApiKey", "allDebridApiKey", "debridLinkApiKey", "easyDebridApiKey", "offcloudApiKey",
            "putioClientID", "putioToken", "managedTorrentioEnabled",
            "managedTorrentioEnabled.realdebrid.v1", "managedTorrentioEnabled.torbox.v1",
            "managedTorrentioEnabled.premiumize.v1", "managedTorrentioEnabled.alldebrid.v1",
            "managedTorrentioEnabled.debridlink.v1", "managedTorrentioEnabled.easydebrid.v1",
            "managedTorrentioEnabled.offcloud.v1", "managedTorrentioEnabled.putio.v1",
            "builtInAddonCachedOnly", "builtInAddonExcludeCam",
            "sourceIntelligenceMaximumLinks", "optionalFebBoxEnabledV1",
            "nuvioPluginGroupProvidersByRepository.v1",
            "mediaFlowProxyEnabledV1", "mediaFlowProxyURLV1", "mediaFlowProxyPublicIPV1",
            "mediaFlowWebBrowserPlaybackV1", "debridNowShowingServerURLV1", "debridNowShowingPushTokenV1",

            // Playback and presentation preferences
            "externalMoviesInfuseDefault", "externalMoviesVLCDefault", "externalMoviesSenPlayerDefault",
            "externalShowsInfuseDefault", "externalShowsVLCDefault", "externalShowsSenPlayerDefault",
            "liveTVUseAVPlayerDefault", "liveTVMatchDisplayEnabled",
            "liveTVGridProgramProgressEnabled", "liveTVGridFocusPreviewEnabledV1",
            "liveTVInternalPlayerEngineV1", "liveTVGridFocusPreviewStyleV1",
            "liveTVGridFocusPreviewDurationV1", "liveTVGridDimOthersDuringPreviewV1",
            "liveTVGridFocusRingColorV1", "liveTVGridFocusRingMotionV1",
            "liveTVCardArtworkStyle", "liveTVAnimatedHeaderLogoEnabledV1", "liveTVAnimatedHeaderLogoStyleV1", "liveTVChannelNumberPositionV1", "liveTVGridLayoutStyleV1", "liveTVDashboardStyleV348", "liveTVPreviewMirrorShowTopMenuV350", "liveQuickGuideTipShown",
            "signalLiveTVCardThemeV342", "signalLiveTVCardEffectV344", "signalLiveTVCardSizeV344", "signalLiveTVCardTypographyV346",
            "launchAppInGuide",
            "gridLockedMode", "trailerEngineMode",
            "vodInternalPlayerEngine", "vodControlsDockStyle", "vodOverlayThemePresetV1",
            "vodControlShelfMode", "vodControlShelfAutoHideSeconds", "vodControlShelfLastExpanded",
            "vodProductionRatingsPanelEnabled", "vodCollectorShowcasePanelEnabledV1",
            "vodPortraitPosterThemedLogoEnabledV1", "vodProductionRatingsThemedLogoEnabledV1",
            "liveTVPlaybackGuideModeV1", "focusedCardPreviewsEnabled", "focusedCardPulseAnimationEnabled",
            "catalogRowScrollingAnimationPreset", "mainGridBackgroundPreset", "dynamicMainGridWallpaperEnabled", "dynamicMainGridWallpaperPreset",
            "appCanvasExpandedV1", "dynamicMainGridWallpaperCustomEnabledV1", "dynamicMainGridWallpaperCustomURLV1",
            "visualPerformanceMode",
            "popupFontPreset", "topMenuThemePreset", "topMenuAccentColor", "topMenuFontPreset",
            "topMenuSizePresetV1", "signalChromeLogoSizeV346",
            "topBarMediaInfoLayout", "mediaInfoTopBarTransparency",
            "showMediaInfoPortraitPoster", "connectedMediaPopupArtworkEnabled", "mediaInfoConnectorLineEnabledV1", "topLeftDebridChannelsLogoEnabledV1", "advisoryDisplayEnabled",
            "homeGridThemePreset", "liveTVGridThemePreset",

            // Library/follow state and alert preferences
            "favoriteMediaIds", "favoriteMediaSnapshotsV1Base64", "favoriteMediaLibraryV2Base64", "followedShowIds",
            "followAlertsEnabled", "followNewEpisodesEnabled",
            "followSportsAlertsEnabled", "followPPVAlertsEnabled", "followVerifiedOnly",
            "newEpisodeAlertScanFrequencyMinutes", "newEpisodeAlertStyle",
            "newEpisodeAlertBannerSide", "newEpisodeAlertTheme",
            "newEpisodeAlertBannerDurationSeconds", "newEpisodeAlertPresentationScopeV1"
        ]

        var sanitized: [String: Any] = [:]
        for (key, value) in raw where allowedKeys.contains(key) {
            if key == "stremioManifestURLs", let urls = value as? [String] {
                sanitized[key] = cloudBackupManifestURLs(urls)
            } else if key == "stremioManifestURL", let url = value as? String {
                sanitized[key] = cloudBackupManifestURLs([url]).first ?? cinematetaManifestURL
            } else if key == "favoriteMediaLibraryV2Base64",
                      let encoded = value as? String,
                      encoded.utf8.count <= 1_250_000,
                      let decoded = Data(base64Encoded: encoded),
                      decoded.count <= 900_000 {
                sanitized[key] = encoded
            } else if key == "favoriteMediaSnapshotsV1Base64",
                      let encoded = value as? String,
                      encoded.utf8.count <= 2_100_000,
                      let decoded = Data(base64Encoded: encoded),
                      decoded.count <= 1_500_000 {
                sanitized[key] = encoded
            } else if isSupportedBackupValue(value) {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    /// Keychain-only secrets are intentionally outside UserDefaults. They are accepted only
    /// from the credentialVault of an explicit protected profile backup and are restored
    /// directly into their credential stores.
    static func sanitizedCredentialVault(_ raw: [String: Any]) -> [String: String] {
        let limits: [String: Int] = [
            "febBoxCookie": 16_384,
            "mediaFlowAPIPassword": 32_768,
            "nuvioPluginBackupBlob": 2_000_000
        ]
        var output: [String: String] = [:]
        for (key, limit) in limits {
            guard let value = raw[key] as? String else { continue }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= limit else { continue }
            output[key] = clean
        }
        return output
    }

    private static func isSupportedBackupValue(_ value: Any) -> Bool {
        if value is String || value is Bool || value is Int || value is Double || value is NSNumber {
            return true
        }
        if let strings = value as? [String] {
            return strings.allSatisfy { !$0.contains("\u{0000}") }
        }
        return false
    }

    static func redactedURLDescription(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Not available" }
        if isOfficialCatalogURL(raw) { return "official-catalog" }
        guard var components = URLComponents(string: raw) else { return redactedText(raw) }
        components.user = nil
        components.password = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                sensitiveNames.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: "REDACTED")
                    : item
            }
        }
        var output = components.string ?? raw
        output = redactSensitivePathValues(output)
        return redactedText(output)
    }

    static func redactedText(_ text: String?) -> String {
        guard var result = text, !result.isEmpty else { return "None" }
        result = result.replacingOccurrences(of: "https://catalog.skylinejay187.it.com/manifest.json", with: "official-catalog", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "catalog.skylinejay187.it.com", with: "official-catalog", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "192.168.100.55:8484", with: "official-catalog", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "192.168.100.55:8181", with: "public-backend", options: .caseInsensitive)
        return redactSensitivePathValues(result)
    }

    static func releaseIdentity() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func isOfficialCatalogURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return officialCatalogMarkers.contains { lower.contains($0) }
            || lower.contains("api.skylinejay187.it.com") && lower.contains("manifest")
    }

    private static func isSafePublicManifestURL(_ value: String) -> Bool {
        guard !isOfficialCatalogURL(value), let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil else { return false }

        if components.queryItems?.contains(where: { sensitiveNames.contains($0.name.lowercased()) }) == true {
            return false
        }
        let lower = value.lowercased()
        let credentialMarkers = sensitiveNames.map { "\($0)=" } + ["/configure/", "authorization=", "bearer="]
        return !credentialMarkers.contains { lower.contains($0) }
    }

    private static func redactSensitivePathValues(_ input: String) -> String {
        var result = input
        for name in sensitiveNames {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = "(?i)(\(escaped)=)[^&/\\s]+"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1REDACTED")
        }
        return result
    }
}
