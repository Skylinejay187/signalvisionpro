import Foundation

struct ManagedAddonManifest: Hashable, Identifiable {
    let id: String
    let displayName: String
    let manifestURL: String
    let bridgedService: DebridServiceID?
}

/// Managed Torrentio is optional and account-scoped.
///
/// vBRDC072: there is no global Torrentio switch. Every debrid account has its own
/// attachment toggle, so a user can keep Torrentio on Real-Debrid while removing it
/// from TorBox (or vice versa) without deleting or sharing either credential.
enum ManagedAddonBridge {
    static func coreDebridStreamManifests(defaults: UserDefaults = .standard) -> [ManagedAddonManifest] {
        DebridCredentialBridge.migrateLegacyOverridesIfNeeded(defaults: defaults)
        let cachedOnly = defaults.object(forKey: "builtInAddonCachedOnly") as? Bool ?? true
        let excludeCam = defaults.object(forKey: "builtInAddonExcludeCam") as? Bool ?? true
        var output: [ManagedAddonManifest] = []

        for service in DebridServiceID.allCases {
            guard DebridCredentialBridge.torrentioEnabled(for: service, defaults: defaults),
                  let credential = DebridCredentialBridge.credential(for: service, defaults: defaults),
                  let torrentio = torrentioManifestURL(
                    credential: credential,
                    cachedOnly: cachedOnly,
                    excludeCam: excludeCam
                  ) else { continue }
            output.append(ManagedAddonManifest(
                id: "torrentio-\(service.rawValue)",
                displayName: "Torrentio • \(service.displayName)",
                manifestURL: torrentio,
                bridgedService: service
            ))
        }
        return output
    }

    static func torrentioManifestURL(
        credential: DebridCredentialSnapshot,
        cachedOnly: Bool,
        excludeCam: Bool
    ) -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "|"))
        let key = credential.credential.addingPercentEncoding(withAllowedCharacters: allowed) ?? credential.credential
        var parts = ["\(credential.service.torrentioServiceKey)=\(key)"]
        if cachedOnly { parts.append("debridoptions=nodownloadlinks") }
        if excludeCam { parts.append("qualityfilter=cam,ts,telesync,hdcam,scr") }
        return "https://torrentio.strem.fun/\(parts.joined(separator: "|"))/manifest.json"
    }
}
