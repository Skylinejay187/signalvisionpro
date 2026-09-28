import Foundation
#if canImport(Security)
import Security
#endif

enum DebridServiceID: String, CaseIterable, Hashable {
    case realDebrid = "realdebrid"
    case torBox = "torbox"
    case premiumize = "premiumize"
    case allDebrid = "alldebrid"
    case debridLink = "debridlink"
    case easyDebrid = "easydebrid"
    case offcloud = "offcloud"
    case putio = "putio"

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .torBox: return "TorBox"
        case .premiumize: return "Premiumize"
        case .allDebrid: return "AllDebrid"
        case .debridLink: return "Debrid-Link"
        case .easyDebrid: return "EasyDebrid"
        case .offcloud: return "Offcloud"
        case .putio: return "Put.io"
        }
    }

    /// Key name accepted by Torrentio's configured manifest path.
    var torrentioServiceKey: String { rawValue }

    /// Each debrid account owns its Torrentio attachment independently. Removing one
    /// provider never affects any other debrid key or TorBox native Usenet.
    var torrentioEnabledKey: String { "managedTorrentioEnabled.\(rawValue).v1" }

    var primaryCredentialKey: String {
        switch self {
        case .realDebrid: return "realDebridApiKey"
        case .torBox: return "torBoxApiKey"
        case .premiumize: return "premiumizeApiKey"
        case .allDebrid: return "allDebridApiKey"
        case .debridLink: return "debridLinkApiKey"
        case .easyDebrid: return "easyDebridApiKey"
        case .offcloud: return "offcloudApiKey"
        case .putio: return "putioClientID"
        }
    }

    var secondaryCredentialKey: String? {
        switch self {
        case .putio: return "putioToken"
        default: return nil
        }
    }
}

struct DebridCredentialSnapshot: Hashable {
    let service: DebridServiceID
    let credential: String
    let sourceDescription: String
}

/// One authoritative credential bridge for native services and managed Torrentio.
///
/// vBRDC072 expands the bridge from two providers to every provider currently exposed
/// by Torrentio's configure surface while making Torrentio opt-in *per debrid account*.
/// Native provider features (notably TorBox Usenet) never consult Torrentio state.
enum DebridCredentialBridge {
    private static func clean(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func migrateLegacyOverridesIfNeeded(defaults: UserDefaults = .standard) {
        removeRetiredManagedAddonStateIfNeeded(defaults: defaults)
        migrateLegacy(
            mainKey: "realDebridApiKey",
            legacyKey: "torrentioRealDebridApiKey",
            defaults: defaults
        )
        migrateLegacy(
            mainKey: "torBoxApiKey",
            legacyKey: "torrentioTorBoxApiKey",
            defaults: defaults
        )
        migrateLegacyGlobalTorrentioSwitch(defaults: defaults)
    }

    private static func removeRetiredManagedAddonStateIfNeeded(defaults: UserDefaults) {
        let migrationKey = "migration.vBRDC053.retiredManagedAddonsCleaned"
        guard !defaults.bool(forKey: migrationKey) else { return }
        for key in [
            "managedDebridioScraperEnabled.v1",
            "managedDebridioWatchtowerEnabled.v1",
            "managedDebridioTMDBEnabled.v1",
            "managedDebridioTVDBEnabled.v1",
            "managedDebridioTMDBLanguage.v1"
        ] {
            defaults.removeObject(forKey: key)
        }
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.channelsdebrid.tvos.managedaddons",
            kSecAttrAccount as String: "debridio-api-key-v1"
        ]
        SecItemDelete(query as CFDictionary)
#endif
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateLegacy(mainKey: String, legacyKey: String, defaults: UserDefaults) {
        let main = clean(defaults.string(forKey: mainKey))
        let legacy = clean(defaults.string(forKey: legacyKey))
        if main.isEmpty, !legacy.isEmpty {
            defaults.set(legacy, forKey: mainKey)
        }
        if !legacy.isEmpty {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    /// vBRDC071 and older had one global switch. Preserve that user's intent on upgrade,
    /// but only attach Torrentio to accounts that were actually configured at migration
    /// time. From this point onward every provider has an independent switch.
    private static func migrateLegacyGlobalTorrentioSwitch(defaults: UserDefaults) {
        let migrationKey = "migration.vBRDC072.perDebridTorrentioFlags"
        // A vBRDC071-or-older profile backup can restore the legacy global key even on a
        // device that already ran this migration once. Process the key whenever it exists,
        // while never overriding an explicit per-account vBRDC072 choice (including false).
        if defaults.object(forKey: "managedTorrentioEnabled") != nil {
            if defaults.bool(forKey: "managedTorrentioEnabled") {
                for service in DebridServiceID.allCases {
                    if credential(forWithoutMigration: service, defaults: defaults) != nil,
                       defaults.object(forKey: service.torrentioEnabledKey) == nil {
                        defaults.set(true, forKey: service.torrentioEnabledKey)
                    }
                }
            }
            defaults.removeObject(forKey: "managedTorrentioEnabled")
        }
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(true, forKey: migrationKey)
        }
    }

    private static func credential(forWithoutMigration service: DebridServiceID, defaults: UserDefaults) -> DebridCredentialSnapshot? {
        let primary = clean(defaults.string(forKey: service.primaryCredentialKey))
        if service == .putio {
            let token = clean(defaults.string(forKey: service.secondaryCredentialKey ?? ""))
            guard !primary.isEmpty, !token.isEmpty else { return nil }
            return DebridCredentialSnapshot(service: service, credential: "\(primary)@\(token)", sourceDescription: "Main Put.io Client ID + token")
        }
        guard !primary.isEmpty else { return nil }
        return DebridCredentialSnapshot(service: service, credential: primary, sourceDescription: "Main \(service.displayName) credential")
    }

    static func credential(for service: DebridServiceID, defaults: UserDefaults = .standard) -> DebridCredentialSnapshot? {
        migrateLegacyOverridesIfNeeded(defaults: defaults)
        return credential(forWithoutMigration: service, defaults: defaults)
    }

    static func torrentioEnabled(for service: DebridServiceID, defaults: UserDefaults = .standard) -> Bool {
        migrateLegacyOverridesIfNeeded(defaults: defaults)
        return defaults.bool(forKey: service.torrentioEnabledKey)
    }

    static func setTorrentioEnabled(_ enabled: Bool, for service: DebridServiceID, defaults: UserDefaults = .standard) {
        migrateLegacyOverridesIfNeeded(defaults: defaults)
        defaults.set(enabled, forKey: service.torrentioEnabledKey)
    }

    static func effectiveTorBoxAPIKey(defaults: UserDefaults = .standard) -> String {
        credential(for: .torBox, defaults: defaults)?.credential ?? ""
    }

    static func effectiveRealDebridAPIKey(defaults: UserDefaults = .standard) -> String {
        credential(for: .realDebrid, defaults: defaults)?.credential ?? ""
    }

    static func connectedServiceSummary(defaults: UserDefaults = .standard) -> String {
        let values = DebridServiceID.allCases.compactMap {
            credential(for: $0, defaults: defaults)?.service.displayName
        }
        return values.isEmpty ? "No global debrid credentials detected" : values.joined(separator: " + ")
    }
}
