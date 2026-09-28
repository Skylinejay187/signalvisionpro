import Foundation
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NuvioSettingValue: Codable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return String(value)
        case .null: return ""
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["1", "true", "yes", "on"].contains(value.lowercased())
        case .number(let value): return value != 0
        case .null: return false
        }
    }
}

struct NuvioPluginSettingOption: Codable, Hashable, Identifiable {
    let label: String
    let value: String
    var id: String { value }
}

struct NuvioPluginSettingField: Codable, Hashable, Identifiable {
    let type: String
    let key: String?
    let label: String
    let description: String?
    let placeholder: String?
    let isPassword: Bool
    let defaultValue: NuvioSettingValue?
    let options: [NuvioPluginSettingOption]

    var id: String { "\(type)|\(key ?? label)" }
}

struct NuvioPluginProviderDescriptor: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String
    let filename: String
    let enabledByDefault: Bool
    let hasSettings: Bool
    let limited: Bool
    let formats: [String]
    let supportedTypes: [String]
    let contentLanguage: [String]
    let disabledPlatforms: [String]
    let supportsExternalPlayer: Bool
    let logo: String?
}

struct NuvioPluginRepositorySnapshot: Codable, Hashable {
    let schemaVersion: Int
    let repositoryURL: String
    let name: String
    let version: String
    let description: String
    let providers: [NuvioPluginProviderDescriptor]
}

struct NuvioPluginRepositoryConfiguration: Codable, Hashable, Identifiable {
    var repositoryURL: String
    var name: String
    var version: String
    var description: String
    var providers: [NuvioPluginProviderDescriptor]
    var enabledProviderIDs: [String]
    var settingsByProvider: [String: [String: NuvioSettingValue]]
    var passwordSettingKeysByProvider: [String: [String]]
    var lastUpdatedAt: Date

    var id: String { repositoryURL }
    var enabledProviders: [NuvioPluginProviderDescriptor] {
        let enabled = Set(enabledProviderIDs)
        return providers.filter { enabled.contains($0.id) }
    }
}

private struct NuvioRepositoryInspectRequest: Encodable {
    let repositoryURL: String
    let force: Bool
}

private struct NuvioProviderSettingsRequest: Encodable {
    let repositoryURL: String
    let providerID: String
}

private struct NuvioProviderSettingsResponse: Decodable {
    let schemaVersion: Int?
    let repositoryURL: String?
    let providerID: String?
    let providerName: String?
    let fields: [NuvioPluginSettingField]
}

fileprivate struct NuvioResolveRepository: Encodable {
    let url: String
    let enabledProviderIDs: [String]
    let settingsByProvider: [String: [String: NuvioSettingValue]]
}

struct NuvioEnabledProviderRequest: Hashable {
    let repositoryURL: String
    let repositoryName: String
    let providerID: String
    let providerName: String
    let settings: [String: NuvioSettingValue]
}

private struct NuvioSingleProviderResolveRequest: Encodable {
    let schemaVersion: Int
    let tmdbId: String
    let mediaType: String
    let season: Int?
    let episode: Int?
    let tmdbApiKey: String?
    let repositoryURL: String
    let providerID: String
    let settings: [String: NuvioSettingValue]
}

private struct NuvioResolveRequest: Encodable {
    let schemaVersion: Int
    let tmdbId: String
    let mediaType: String
    let season: Int?
    let episode: Int?
    let tmdbApiKey: String?
    let repositories: [NuvioResolveRepository]
}

struct NuvioProviderResolutionStatus: Decodable, Hashable, Identifiable {
    let provider: String
    let providerID: String
    let repository: String
    let state: String
    let count: Int
    let message: String
    var id: String { "\(repository)|\(providerID)|\(provider)" }
}

private struct NuvioResolvedSubtitle: Decodable {
    let url: String?
    let language: String?
    let name: String?
}

private struct NuvioResolvedProxyHeaders: Decodable {
    let request: [String: String]?
}

private struct NuvioResolvedBehaviorHints: Decodable {
    let videoSize: NuvioSettingValue?
    let filename: String?
    let proxyHeaders: NuvioResolvedProxyHeaders?
}

private struct NuvioResolvedStream: Decodable {
    let provider: String?
    let providerID: String?
    let repository: String?
    let title: String?
    let description: String?
    let url: String?
    let quality: String?
    let size: NuvioSettingValue?
    let videoSize: NuvioSettingValue?
    let fileSize: NuvioSettingValue?
    let sizeBytes: NuvioSettingValue?
    let filename: String?
    let subtitles: [NuvioResolvedSubtitle]?
    let format: String?
    let sourceName: String?
    // Provider runtimes in the wild use both the Nuvio/Stremio behaviorHints form
    // and simple top-level aliases. Decode all of them so the bridge can evolve
    // without making previously valid providers unplayable.
    let headers: [String: String]?
    let httpHeaders: [String: String]?
    let requestHeaders: [String: String]?
    let behaviorHints: NuvioResolvedBehaviorHints?
}

private struct NuvioResolveResponse: Decodable {
    let schemaVersion: Int?
    let status: String?
    let message: String?
    let streams: [NuvioResolvedStream]
    let providers: [NuvioProviderResolutionStatus]
}

struct NuvioPluginResolveResult {
    let links: [StreamLink]
    let providerStatuses: [NuvioProviderResolutionStatus]
    let message: String
}

enum NuvioPluginClientError: LocalizedError {
    case backendNotConfigured
    case invalidResponse
    case responseTooLarge
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured: return "The Debrid Channels backend URL is not configured."
        case .invalidResponse: return "The In-S source bridge returned an invalid response."
        case .responseTooLarge: return "The In-S source response exceeded the safe size limit."
        case .backendRejected(let message): return message
        }
    }
}

private enum NuvioPluginCredentialStore {
    private static let service = "com.channelsdebrid.tvos.nuvioplugins"

    private static func account(repositoryURL: String, providerID: String, key: String) -> String {
        let raw = "\(repositoryURL)|\(providerID)|\(key)"
        return Data(raw.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    static func read(repositoryURL: String, providerID: String, key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(repositoryURL: repositoryURL, providerID: providerID, key: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    @discardableResult
    static func save(_ value: String, repositoryURL: String, providerID: String, key: String) -> Bool {
        let accountValue = account(repositoryURL: repositoryURL, providerID: providerID, key: key)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountValue
        ]
        if value.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func purgeAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private struct NuvioPluginBackupSecret: Codable {
    let repositoryURL: String
    let providerID: String
    let key: String
    let value: String
}

private struct NuvioPluginBackupEnvelope: Codable {
    let schemaVersion: Int
    let repositories: [NuvioPluginRepositoryConfiguration]
    let secrets: [NuvioPluginBackupSecret]
}

enum NuvioPluginPreferences {
    static let storageKey = "nuvioPluginRepositories.v1"
    static let groupByRepositoryStorageKey = "nuvioPluginGroupProvidersByRepository.v1"
    static let changedNotification = Notification.Name("DebridChannelsNuvioPluginPreferencesChanged")

    // vBRDC040: match Nuvio's optional repository grouping. Default ON for Debrid Channels
    // so a 20+ provider repository produces one clean Source Intelligence chip instead of
    // scattering every scraper across the provider rail. The setting remains user-toggleable.
    static func groupProvidersByRepository() -> Bool {
        if UserDefaults.standard.object(forKey: groupByRepositoryStorageKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: groupByRepositoryStorageKey)
    }

    static func setGroupProvidersByRepository(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: groupByRepositoryStorageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func repositories() -> [NuvioPluginRepositoryConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([NuvioPluginRepositoryConfiguration].self, from: data) else { return [] }
        return decoded
    }

    static func saveRepositories(_ repositories: [NuvioPluginRepositoryConfiguration]) {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Removes repository configuration and every password-style provider secret. This is
    /// used only by the app's fresh-install boundary so deleting/reinstalling Debrid Channels
    /// cannot resurrect In-S credentials from Keychain.
    @discardableResult
    static func purgeForFreshInstall(defaults: UserDefaults = .standard) -> Bool {
        let keychainOK = NuvioPluginCredentialStore.purgeAll()
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: groupByRepositoryStorageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return keychainOK
    }

    /// Explicit profile backups are the one supported way to carry In-S repository settings
    /// and password fields to a new installation. The returned blob is never written to local
    /// defaults; it is placed only inside the user-requested protected profile backup.
    static func exportBackupBlob() -> String {
        let repos = repositories()
        var secrets: [NuvioPluginBackupSecret] = []
        for repository in repos {
            for (providerID, keys) in repository.passwordSettingKeysByProvider {
                for key in keys {
                    let value = NuvioPluginCredentialStore.read(
                        repositoryURL: repository.repositoryURL,
                        providerID: providerID,
                        key: key
                    )
                    if !value.isEmpty {
                        secrets.append(NuvioPluginBackupSecret(
                            repositoryURL: repository.repositoryURL,
                            providerID: providerID,
                            key: key,
                            value: value
                        ))
                    }
                }
            }
        }
        let envelope = NuvioPluginBackupEnvelope(schemaVersion: 1, repositories: repos, secrets: secrets)
        guard let data = try? JSONEncoder().encode(envelope) else { return "" }
        return data.base64EncodedString()
    }

    @discardableResult
    static func restoreBackupBlob(_ raw: String) -> Int {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 2_000_000,
              let data = Data(base64Encoded: clean),
              let envelope = try? JSONDecoder().decode(NuvioPluginBackupEnvelope.self, from: data),
              envelope.schemaVersion == 1 else { return 0 }

        // Repositories define the only provider/password keys that may be restored. Do not
        // accept arbitrary Keychain account material from a malformed backup payload.
        var allowed = Set<String>()
        for repository in envelope.repositories {
            for (providerID, keys) in repository.passwordSettingKeysByProvider {
                for key in keys {
                    allowed.insert("\(repository.repositoryURL)|\(providerID)|\(key)")
                }
            }
        }

        _ = NuvioPluginCredentialStore.purgeAll()
        saveRepositories(envelope.repositories)
        var restored = envelope.repositories.isEmpty ? 0 : 1
        for secret in envelope.secrets {
            let identity = "\(secret.repositoryURL)|\(secret.providerID)|\(secret.key)"
            guard allowed.contains(identity), secret.value.count <= 32_768 else { continue }
            if NuvioPluginCredentialStore.save(
                secret.value,
                repositoryURL: secret.repositoryURL,
                providerID: secret.providerID,
                key: secret.key
            ) {
                restored += 1
            }
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return restored
    }

    static func upsert(snapshot: NuvioPluginRepositorySnapshot) {
        var all = repositories()
        if let index = all.firstIndex(where: { $0.repositoryURL == snapshot.repositoryURL }) {
            let old = all[index]
            let validIDs = Set(snapshot.providers.map(\.id))
            all[index] = NuvioPluginRepositoryConfiguration(
                repositoryURL: snapshot.repositoryURL,
                name: snapshot.name,
                version: snapshot.version,
                description: snapshot.description,
                providers: snapshot.providers,
                enabledProviderIDs: old.enabledProviderIDs.filter { validIDs.contains($0) },
                settingsByProvider: old.settingsByProvider.filter { validIDs.contains($0.key) },
                passwordSettingKeysByProvider: old.passwordSettingKeysByProvider.filter { validIDs.contains($0.key) },
                lastUpdatedAt: Date()
            )
        } else {
            all.append(NuvioPluginRepositoryConfiguration(
                repositoryURL: snapshot.repositoryURL,
                name: snapshot.name,
                version: snapshot.version,
                description: snapshot.description,
                providers: snapshot.providers,
                enabledProviderIDs: snapshot.providers.filter { $0.enabledByDefault }.map(\.id),
                settingsByProvider: [:],
                passwordSettingKeysByProvider: [:],
                lastUpdatedAt: Date()
            ))
        }
        saveRepositories(all)
    }

    static func setProviderEnabled(repositoryURL: String, providerID: String, enabled: Bool) {
        var all = repositories()
        guard let index = all.firstIndex(where: { $0.repositoryURL == repositoryURL }) else { return }
        var ids = Set(all[index].enabledProviderIDs)
        if enabled { ids.insert(providerID) } else { ids.remove(providerID) }
        all[index].enabledProviderIDs = all[index].providers.map(\.id).filter { ids.contains($0) }
        saveRepositories(all)
    }

    static func remove(repositoryURL: String) {
        var all = repositories()
        if let existing = all.first(where: { $0.repositoryURL == repositoryURL }) {
            for (providerID, keys) in existing.passwordSettingKeysByProvider {
                for key in keys { _ = NuvioPluginCredentialStore.save("", repositoryURL: repositoryURL, providerID: providerID, key: key) }
            }
        }
        all.removeAll { $0.repositoryURL == repositoryURL }
        saveRepositories(all)
    }

    static func settingValues(repositoryURL: String, providerID: String, fields: [NuvioPluginSettingField]) -> [String: NuvioSettingValue] {
        let repo = repositories().first { $0.repositoryURL == repositoryURL }
        var values = repo?.settingsByProvider[providerID] ?? [:]
        for field in fields {
            guard let key = field.key else { continue }
            if field.isPassword {
                let secret = NuvioPluginCredentialStore.read(repositoryURL: repositoryURL, providerID: providerID, key: key)
                if !secret.isEmpty { values[key] = .string(secret) }
            } else if values[key] == nil, let fallback = field.defaultValue {
                values[key] = fallback
            }
        }
        return values
    }

    static func saveSettings(repositoryURL: String, providerID: String, fields: [NuvioPluginSettingField], values: [String: NuvioSettingValue]) {
        var all = repositories()
        guard let index = all.firstIndex(where: { $0.repositoryURL == repositoryURL }) else { return }
        var publicValues = all[index].settingsByProvider[providerID] ?? [:]
        var passwordKeys = Set(all[index].passwordSettingKeysByProvider[providerID] ?? [])
        for field in fields {
            guard let key = field.key else { continue }
            let value = values[key] ?? field.defaultValue ?? .null
            if field.isPassword {
                _ = NuvioPluginCredentialStore.save(value.stringValue, repositoryURL: repositoryURL, providerID: providerID, key: key)
                publicValues.removeValue(forKey: key)
                passwordKeys.insert(key)
            } else {
                publicValues[key] = value
            }
        }
        all[index].settingsByProvider[providerID] = publicValues
        all[index].passwordSettingKeysByProvider[providerID] = Array(passwordKeys).sorted()
        saveRepositories(all)
    }

    fileprivate static func resolveRepositories() -> [NuvioResolveRepository] {
        repositories().compactMap { repository in
            guard !repository.enabledProviderIDs.isEmpty else { return nil }
            var settings = repository.settingsByProvider
            for (providerID, keys) in repository.passwordSettingKeysByProvider {
                var providerSettings = settings[providerID] ?? [:]
                for key in keys {
                    let secret = NuvioPluginCredentialStore.read(repositoryURL: repository.repositoryURL, providerID: providerID, key: key)
                    if !secret.isEmpty { providerSettings[key] = .string(secret) }
                }
                settings[providerID] = providerSettings
            }
            return NuvioResolveRepository(url: repository.repositoryURL, enabledProviderIDs: repository.enabledProviderIDs, settingsByProvider: settings)
        }
    }

    static func enabledProviderRequests() -> [NuvioEnabledProviderRequest] {
        repositories().flatMap { repository -> [NuvioEnabledProviderRequest] in
            let enabled = Set(repository.enabledProviderIDs)
            return repository.providers.compactMap { provider in
                guard enabled.contains(provider.id) else { return nil }
                var settings = repository.settingsByProvider[provider.id] ?? [:]
                for key in repository.passwordSettingKeysByProvider[provider.id] ?? [] {
                    let secret = NuvioPluginCredentialStore.read(repositoryURL: repository.repositoryURL, providerID: provider.id, key: key)
                    if !secret.isEmpty { settings[key] = .string(secret) }
                }
                return NuvioEnabledProviderRequest(
                    repositoryURL: repository.repositoryURL,
                    repositoryName: repository.name,
                    providerID: provider.id,
                    providerName: provider.name,
                    settings: settings
                )
            }
        }
    }

    static func enabledRepositoryNames() -> Set<String> {
        Set(repositories().filter { !$0.enabledProviderIDs.isEmpty }.map { repository in
            let clean = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "In-S Repository" : clean
        })
    }

    static func repositoryName(forProviderName providerName: String) -> String? {
        let target = canonicalProviderLabel(providerName)
        guard !target.isEmpty else { return nil }
        for repository in repositories() {
            let enabled = Set(repository.enabledProviderIDs)
            for provider in repository.providers where enabled.contains(provider.id) {
                let key = canonicalProviderLabel(provider.name)
                if !key.isEmpty && (target == key || target.contains(key) || key.contains(target)) {
                    let clean = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.isEmpty ? "In-S Repository" : clean
                }
            }
        }
        return nil
    }

    static func providerBelongsToRepository(providerName: String, repositoryName: String) -> Bool {
        let wantedRepository = canonicalProviderLabel(repositoryName)
        guard !wantedRepository.isEmpty else { return false }
        let targetProvider = canonicalProviderLabel(providerName)
        for repository in repositories() {
            let cleanRepositoryName = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveRepositoryName = cleanRepositoryName.isEmpty ? "In-S Repository" : cleanRepositoryName
            guard canonicalProviderLabel(effectiveRepositoryName) == wantedRepository else { continue }
            let enabled = Set(repository.enabledProviderIDs)
            return repository.providers.contains { provider in
                guard enabled.contains(provider.id) else { return false }
                let key = canonicalProviderLabel(provider.name)
                return !key.isEmpty && (targetProvider == key || targetProvider.contains(key) || key.contains(targetProvider))
            }
        }
        return false
    }

    static func enabledProviderNames() -> Set<String> {
        Set(repositories().flatMap { $0.enabledProviders.map(\.name) })
    }

    private static func canonicalProviderLabel(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum NuvioPluginClient {
    private static let maximumResponseBytes = 8_000_000

    static func inspectRepository(backendBaseURL: String, repositoryURL: String, force: Bool = false) async throws -> NuvioPluginRepositorySnapshot {
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/nuvio/repository/inspect")
        return try await postJSON(endpoint: endpoint, payload: NuvioRepositoryInspectRequest(repositoryURL: repositoryURL, force: force))
    }

    static func providerSettings(backendBaseURL: String, repositoryURL: String, providerID: String) async throws -> [NuvioPluginSettingField] {
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/nuvio/provider/settings")
        let response: NuvioProviderSettingsResponse = try await postJSON(endpoint: endpoint, payload: NuvioProviderSettingsRequest(repositoryURL: repositoryURL, providerID: providerID))
        return response.fields
    }

    static func resolveProvider(
        backendBaseURL: String,
        item: MediaItem,
        providerRequest: NuvioEnabledProviderRequest
    ) async throws -> NuvioPluginResolveResult {
        guard let tmdbID = normalizedTMDBID(item.tmdbId) ?? normalizedTMDBID(item.id) else {
            return NuvioPluginResolveResult(
                links: [],
                providerStatuses: [NuvioProviderResolutionStatus(
                    provider: providerRequest.providerName,
                    providerID: providerRequest.providerID,
                    repository: providerRequest.repositoryName,
                    state: "no_links",
                    count: 0,
                    message: "TMDB identity unavailable"
                )],
                message: "In-S requires a TMDB ID for this title."
            )
        }
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/nuvio/resolve/provider")
        let payload = NuvioSingleProviderResolveRequest(
            schemaVersion: 1,
            tmdbId: tmdbID,
            mediaType: normalizedMediaType(item.type),
            season: item.seasonNumber,
            episode: item.episodeNumber,
            tmdbApiKey: configuredTMDBApiKey(),
            repositoryURL: providerRequest.repositoryURL,
            providerID: providerRequest.providerID,
            settings: providerRequest.settings
        )
        let response: NuvioResolveResponse = try await postJSON(
            endpoint: endpoint,
            payload: payload,
            requestTimeout: 190,
            resourceTimeout: 210
        )
        return try resolveResult(from: response)
    }

    static func resolve(backendBaseURL: String, item: MediaItem) async throws -> NuvioPluginResolveResult {
        guard let tmdbID = normalizedTMDBID(item.tmdbId) ?? normalizedTMDBID(item.id) else {
            return NuvioPluginResolveResult(links: [], providerStatuses: [], message: "In-S requires a TMDB ID for this title.")
        }
        let repositories = NuvioPluginPreferences.resolveRepositories()
        guard !repositories.isEmpty else {
            return NuvioPluginResolveResult(links: [], providerStatuses: [], message: "No In-S providers are enabled.")
        }
        let endpoint = try endpointURL(baseURL: backendBaseURL, path: "/api/nuvio/resolve")
        let payload = NuvioResolveRequest(
            schemaVersion: 1,
            tmdbId: tmdbID,
            mediaType: normalizedMediaType(item.type),
            season: item.seasonNumber,
            episode: item.episodeNumber,
            tmdbApiKey: configuredTMDBApiKey(),
            repositories: repositories
        )
        // vBRDC040: Nuvio's real plugin runtime allows a provider up to 60 seconds and
        // its HTTP bridge up to 30 seconds per request. Keep the Apple TV request alive
        // long enough for the backend to honor that contract instead of cancelling at 60s.
        let response: NuvioResolveResponse = try await postJSON(
            endpoint: endpoint,
            payload: payload,
            requestTimeout: 130,
            resourceTimeout: 145
        )
        return try resolveResult(from: response)
    }

    private static func resolveResult(from response: NuvioResolveResponse) throws -> NuvioPluginResolveResult {
        let state = response.status?.lowercased() ?? ""
        if state == "unavailable" {
            throw NuvioPluginClientError.backendRejected(response.message ?? "In-S providers are unavailable.")
        }
        // A single provider may return state=error while still supplying a useful provider
        // status object. Preserve that status in the UI instead of converting every provider
        // failure into a bridge-wide exception.
        if state == "error" && response.providers.isEmpty {
            throw NuvioPluginClientError.backendRejected(response.message ?? "In-S provider failed.")
        }
        var seen = Set<String>()
        let links = response.streams.compactMap { stream -> StreamLink? in
            guard let rawURL = stream.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = URL(string: rawURL),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  seen.insert(rawURL).inserted else { return nil }
            let provider = stream.provider?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty ?? "In-S Provider"
            let title = stream.title?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty ?? provider
            let format = stream.format?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty
            let displayTitle = format == nil || title.localizedCaseInsensitiveContains(format!) ? title : "\(title) • \(format!)"
            let subtitleURLs = (stream.subtitles ?? []).compactMap { subtitle -> String? in
                guard let value = subtitle.url?.trimmingCharacters(in: .whitespacesAndNewlines), URL(string: value) != nil else { return nil }
                return value
            }
            let metadataHaystack = [stream.title, stream.description, stream.filename, stream.behaviorHints?.filename, stream.sourceName, stream.format]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty }
                .joined(separator: " ")
            var resolvedHeaders = normalizedPlaybackHeaders(
                stream.behaviorHints?.proxyHeaders?.request,
                stream.headers,
                stream.httpHeaders,
                stream.requestHeaders
            )
            // vBRDC089 Shoebox/FebBox parity: these In-S providers ultimately hand the
            // player a FebBox-backed CDN URL. Resolution can succeed with the ui cookie
            // while playback still 401/403s if that same credential is not attached to
            // the final media request. Reuse only the local FebBox credential already
            // owned by this Apple TV, and never send it back through the plugin bridge.
            let providerContext = [provider, stream.providerID ?? "", stream.sourceName ?? "", stream.title ?? "", rawURL]
                .joined(separator: " ").lowercased()
            if providerContext.contains("febbox") || providerContext.contains("shoebox") || providerContext.contains("showbox") {
                let localCookie = BackupStreamingCredentialStore.normalizedCookieValue(BackupStreamingCredentialStore.readFebBoxCookie())
                if !localCookie.isEmpty, resolvedHeaders.keys.first(where: { $0.caseInsensitiveCompare("Cookie") == .orderedSame }) == nil {
                    resolvedHeaders["Cookie"] = "ui=\(localCookie); oss_group=USA7"
                }
                if resolvedHeaders.keys.first(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }) == nil { resolvedHeaders["Referer"] = "https://www.febbox.com/" }
                if resolvedHeaders.keys.first(where: { $0.caseInsensitiveCompare("Origin") == .orderedSame }) == nil { resolvedHeaders["Origin"] = "https://www.febbox.com" }
                if resolvedHeaders.keys.first(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) == nil {
                    resolvedHeaders["User-Agent"] = "Mozilla/5.0 (AppleTV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
                }
            }
            return StreamLink(
                title: displayTitle,
                url: rawURL,
                quality: normalizedQuality(stream.quality, fallbackText: metadataHaystack),
                size: normalizedSize(
                    [stream.behaviorHints?.videoSize, stream.videoSize, stream.fileSize, stream.sizeBytes, stream.size],
                    fallbackText: metadataHaystack
                ),
                source: provider,
                providerService: "In-S",
                infoHash: nil,
                fileIndex: nil,
                subtitleURLs: subtitleURLs,
                requestHeaders: resolvedHeaders.map { StreamRequestHeader(name: $0.key, value: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                isExternalURL: false
            )
        }
        return NuvioPluginResolveResult(links: links, providerStatuses: response.providers, message: response.message ?? "")
    }


    private static func configuredTMDBApiKey() -> String? {
        let value = UserDefaults.standard.string(forKey: "tmdbApiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func normalizedTMDBID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, clean.allSatisfy(\.isNumber) { return clean }
        let lower = clean.lowercased()
        if lower.contains("tmdb") {
            let digits = clean.drop { !$0.isNumber }.prefix { $0.isNumber }
            if !digits.isEmpty { return String(digits) }
        }
        return nil
    }

    private static func normalizedPlaybackHeaders(_ sources: [String: String]?...) -> [String: String] {
        let blocked = Set(["host", "content-length", "transfer-encoding", "range", "content-range"])
        var result: [String: String] = [:]
        for source in sources {
            guard let source else { continue }
            for (rawName, rawValue) in source.prefix(64) {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 128, !blocked.contains(name.lowercased()),
                      !value.isEmpty, value.utf8.count <= 8192,
                      !name.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f || $0.value == 58 }),
                      !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else { continue }
                if let existing = result.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    result.removeValue(forKey: existing)
                }
                result[name] = value
            }
        }
        return result
    }

    private static func normalizedQuality(_ explicit: String?, fallbackText: String) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty,
           explicit.caseInsensitiveCompare("auto") != .orderedSame,
           explicit.caseInsensitiveCompare("unknown") != .orderedSame { return explicit }
        let lower = fallbackText.lowercased()
        for (needle, label) in [("4320p", "4320p"), ("8k", "4320p"), ("2160p", "2160p"), ("4k", "2160p"), ("1440p", "1440p"), ("1080p", "1080p"), ("720p", "720p"), ("576p", "576p"), ("480p", "480p"), ("360p", "360p")] {
            if lower.contains(needle) { return label }
        }
        return explicit?.trimmingCharacters(in: .whitespacesAndNewlines).nuvioNonEmpty ?? "Auto"
    }

    private static func normalizedSize(_ values: [NuvioSettingValue?], fallbackText: String) -> String {
        for value in values.compactMap({ $0 }) {
            switch value {
            case .number(let bytes):
                if let formatted = formattedByteSize(bytes) { return formatted }
            case .string(let text):
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let numeric = Double(clean), let formatted = formattedByteSize(numeric) { return formatted }
                if let parsed = parsedHumanSize(from: clean) { return parsed }
                if !clean.isEmpty, clean.caseInsensitiveCompare("unknown") != .orderedSame, clean.caseInsensitiveCompare("unknown size") != .orderedSame { return clean }
            default: break
            }
        }
        return parsedHumanSize(from: fallbackText) ?? "Unknown size"
    }

    private static func formattedByteSize(_ rawBytes: Double) -> String? {
        guard rawBytes.isFinite, rawBytes > 0 else { return nil }
        if rawBytes >= 1_099_511_627_776 { return String(format: "%.2f TB", rawBytes / 1_099_511_627_776) }
        if rawBytes >= 1_073_741_824 { return String(format: "%.2f GB", rawBytes / 1_073_741_824) }
        if rawBytes >= 1_048_576 { return String(format: "%.0f MB", rawBytes / 1_048_576) }
        if rawBytes >= 1024 { return String(format: "%.0f KB", rawBytes / 1024) }
        return String(format: "%.0f B", rawBytes)
    }

    private static func parsedHumanSize(from text: String) -> String? {
        let pattern = #"(\d+(?:[\.,]\d+)?)\s*(tb|tib|gb|gib|mb|mib|kb|kib)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let number = text[numberRange].replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(number), amount > 0 else { return nil }
        let unit = text[unitRange].lowercased()
        let label: String
        if unit.hasPrefix("t") { label = "TB" }
        else if unit.hasPrefix("g") { label = "GB" }
        else if unit.hasPrefix("m") { label = "MB" }
        else { label = "KB" }
        return amount.rounded() == amount ? String(format: "%.0f %@", amount, label) : String(format: "%.2f %@", amount, label)
    }

    private static func normalizedMediaType(_ raw: String) -> String {
        let lower = raw.lowercased()
        return (lower.contains("series") || lower.contains("show") || lower == "tv" || lower == "episode") ? "tv" : "movie"
    }

    private static func endpointURL(baseURL: String, path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + path) else { throw NuvioPluginClientError.backendNotConfigured }
        return url
    }

    private static func postJSON<Request: Encodable, Response: Decodable>(
        endpoint: URL,
        payload: Request,
        requestTimeout: TimeInterval = 60,
        resourceTimeout: TimeInterval = 90
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/InSBridge", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // vBRDC097: fresh-install Find Links must wait for tvOS connectivity instead of
        // failing the first In-S request and only succeeding after an app restart.
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else { throw NuvioPluginClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw NuvioPluginClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw NuvioPluginClientError.backendRejected("In-S source bridge failed with HTTP \(http.statusCode).")
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw NuvioPluginClientError.invalidResponse }
    }
}

private extension String {
    var nuvioNonEmpty: String? { isEmpty ? nil : self }
}
