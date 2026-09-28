import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ConnectedServiceHealthState: String, Hashable {
    case connected
    case partial
    case failed
    case notConfigured
}

struct ConnectedServiceHealth: Hashable, Identifiable {
    let id: String
    let name: String
    let state: ConnectedServiceHealthState
    let headline: String
    let details: [String]
}

private struct StremioManifestHealthInfo {
    let name: String
    let resources: [String]
}

enum ConnectedServicesHealthClient {
    static func verifyAll(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> [ConnectedServiceHealth] {
        DebridCredentialBridge.migrateLegacyOverridesIfNeeded(defaults: defaults)
        async let torBox = verifyTorBox(defaults: defaults, session: session)
        async let realDebrid = verifyRealDebrid(defaults: defaults, session: session)
        async let premiumize = verifyBearerDebrid(.premiumize, urlString: "https://www.premiumize.me/api/account/info", defaults: defaults, session: session)
        async let allDebrid = verifyBearerDebrid(.allDebrid, urlString: "https://api.alldebrid.com/v4/user", defaults: defaults, session: session)
        async let debridLink = verifyBearerDebrid(.debridLink, urlString: "https://debrid-link.com/api/v2/account/infos", defaults: defaults, session: session)
        async let easyDebrid = verifyBearerDebrid(.easyDebrid, urlString: "https://easydebrid.com/api/v1/user/details", defaults: defaults, session: session)
        async let offcloud = verifyOffcloud(defaults: defaults, session: session)
        async let putio = verifyPutio(defaults: defaults, session: session)
        async let managedTorrentio = verifyManagedTorrentio(defaults: defaults, session: session)
        async let savedAddons = verifySavedStremioAddons(defaults: defaults, session: session)
        return [
            await torBox, await realDebrid, await premiumize, await allDebrid,
            await debridLink, await easyDebrid, await offcloud, await putio,
            await managedTorrentio
        ] + (await savedAddons)
    }

    static func verifyTorBox(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> ConnectedServiceHealth {
        let key = DebridCredentialBridge.effectiveTorBoxAPIKey(defaults: defaults)
        guard !key.isEmpty else {
            return ConnectedServiceHealth(
                id: "torbox",
                name: "TorBox",
                state: .notConfigured,
                headline: "No API key detected",
                details: ["Add the TorBox key once in Global Debrid Credentials."]
            )
        }

        // vBRDC060 connection boundary:
        // TorBox account authentication and the standard Usenet API both live on
        // api.torbox.app and are the authoritative connection checks for the app.
        // search-api.torbox.app is a separate discovery/index service and must never
        // make a healthy TorBox account appear partially connected.
        async let accountResult = healthJSON(
            urlString: "https://api.torbox.app/v1/api/user/me?settings=false",
            bearer: key,
            session: session
        )
        async let usenetResult = healthJSON(
            urlString: "https://api.torbox.app/v1/api/usenet/mylist?limit=1",
            bearer: key,
            session: session
        )

        let account = await accountResult
        let usenet = await usenetResult
        var details: [String] = []
        var successes = 0

        if let value = account.value {
            successes += 1
            details.append("✓ Main API authenticated")
            let planNumber = integerValue(in: value, keys: ["plan", "plan_id", "planId"])
            if let plan = torBoxPlanName(planNumber) { details.append("Account: \(plan)") }
        } else {
            details.append("⚠ Main API (api.torbox.app): \(account.error ?? "Unknown error")")
        }

        if usenet.value != nil {
            successes += 1
            details.append("✓ Usenet processing API connected")
            details.append("Find Links tests release discovery separately")
        } else {
            details.append("⚠ Usenet processing API (api.torbox.app): \(usenet.error ?? "Unknown error")")
        }

        let state: ConnectedServiceHealthState = successes == 2 ? .connected : (successes == 0 ? .failed : .partial)
        let headline: String
        switch successes {
        case 2: headline = "API + Usenet processing connected"
        case 0: headline = "TorBox endpoints unreachable"
        default: headline = "Partially connected (\(successes)/2 checks)"
        }
        return ConnectedServiceHealth(
            id: "torbox",
            name: "TorBox",
            state: state,
            headline: headline,
            details: details
        )
    }

    static func verifyRealDebrid(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> ConnectedServiceHealth {
        let key = DebridCredentialBridge.effectiveRealDebridAPIKey(defaults: defaults)
        guard !key.isEmpty else {
            return ConnectedServiceHealth(
                id: "realdebrid",
                name: "Real-Debrid",
                state: .notConfigured,
                headline: "No API key detected",
                details: ["No global Real-Debrid credential is configured."]
            )
        }
        do {
            _ = try await getJSON(
                urlString: "https://api.real-debrid.com/rest/1.0/user",
                bearer: key,
                session: session
            )
            return ConnectedServiceHealth(
                id: "realdebrid",
                name: "Real-Debrid",
                state: .connected,
                headline: "API connected",
                details: ["Global credential connected", "Torrentio may reuse it only when explicitly enabled"]
            )
        } catch {
            return ConnectedServiceHealth(
                id: "realdebrid",
                name: "Real-Debrid",
                state: .failed,
                headline: "Connection check failed",
                details: [safeMessage(error)]
            )
        }
    }

    private static func verifyBearerDebrid(_ service: DebridServiceID, urlString: String, defaults: UserDefaults, session: URLSession) async -> ConnectedServiceHealth {
        guard let credential = DebridCredentialBridge.credential(for: service, defaults: defaults)?.credential,
              !credential.isEmpty else {
            return ConnectedServiceHealth(
                id: service.rawValue,
                name: service.displayName,
                state: .notConfigured,
                headline: "No credential detected",
                details: ["Add the \(service.displayName) credential in Global Debrid Credentials."]
            )
        }
        do {
            _ = try await getJSON(urlString: urlString, bearer: credential, session: session)
            return ConnectedServiceHealth(
                id: service.rawValue,
                name: service.displayName,
                state: .connected,
                headline: "API connected",
                details: ["Credential authenticated", "Torrentio attachment is controlled independently"]
            )
        } catch {
            return ConnectedServiceHealth(
                id: service.rawValue,
                name: service.displayName,
                state: .failed,
                headline: "Connection check failed",
                details: [safeMessage(error)]
            )
        }
    }

    private static func verifyOffcloud(defaults: UserDefaults, session: URLSession) async -> ConnectedServiceHealth {
        let key = (defaults.string(forKey: DebridServiceID.offcloud.primaryCredentialKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return ConnectedServiceHealth(id: "offcloud", name: "Offcloud", state: .notConfigured, headline: "No API key detected", details: ["Add the Offcloud API key in Global Debrid Credentials."])
        }
        guard var components = URLComponents(string: "https://offcloud.com/api/proxy") else {
            return ConnectedServiceHealth(id: "offcloud", name: "Offcloud", state: .failed, headline: "Connection check failed", details: ["Invalid Offcloud API endpoint"])
        }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else {
            return ConnectedServiceHealth(id: "offcloud", name: "Offcloud", state: .failed, headline: "Connection check failed", details: ["Invalid Offcloud API endpoint"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/vBRDC075", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await dataWithTransientRetry(request: request, session: session, maxAttempts: 2)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "OffcloudHealth", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(errorDetail(from: data))"])
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] != nil {
                throw NSError(domain: "OffcloudHealth", code: -2, userInfo: [NSLocalizedDescriptionKey: String(describing: object["error"] ?? "Offcloud rejected the API key")])
            }
            return ConnectedServiceHealth(id: "offcloud", name: "Offcloud", state: .connected, headline: "API connected", details: ["API key accepted", "Torrentio attachment is controlled independently"])
        } catch {
            return ConnectedServiceHealth(id: "offcloud", name: "Offcloud", state: .failed, headline: "Connection check failed", details: [safeMessage(error)])
        }
    }

    private static func verifyPutio(defaults: UserDefaults, session: URLSession) async -> ConnectedServiceHealth {
        let clientID = (defaults.string(forKey: DebridServiceID.putio.primaryCredentialKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (defaults.string(forKey: DebridServiceID.putio.secondaryCredentialKey ?? "") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !token.isEmpty else {
            return ConnectedServiceHealth(id: "putio", name: "Put.io", state: .notConfigured, headline: "Client ID + token required", details: ["Add both Put.io OAuth values in Global Debrid Credentials."])
        }
        do {
            _ = try await getJSON(urlString: "https://api.put.io/v2/account/info", bearer: token, session: session)
            return ConnectedServiceHealth(id: "putio", name: "Put.io", state: .connected, headline: "API connected", details: ["OAuth token authenticated", "Torrentio uses Client ID + token only when enabled"])
        } catch {
            return ConnectedServiceHealth(id: "putio", name: "Put.io", state: .failed, headline: "Connection check failed", details: [safeMessage(error)])
        }
    }

    static func verifyManagedTorrentio(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> ConnectedServiceHealth {
        let enabledServices = DebridServiceID.allCases.filter { DebridCredentialBridge.torrentioEnabled(for: $0, defaults: defaults) }
        guard !enabledServices.isEmpty else {
            return ConnectedServiceHealth(
                id: "torrentio",
                name: "Torrentio",
                state: .notConfigured,
                headline: "No account attachments enabled",
                details: ["Enable Torrentio separately under any debrid account.", "TorBox native Usenet remains independent."]
            )
        }

        let missingCredentials = enabledServices.filter { DebridCredentialBridge.credential(for: $0, defaults: defaults) == nil }
        let manifests = ManagedAddonBridge.coreDebridStreamManifests(defaults: defaults)
        guard !manifests.isEmpty else {
            return ConnectedServiceHealth(
                id: "torrentio",
                name: "Torrentio",
                state: .notConfigured,
                headline: "Enabled • credential required",
                details: missingCredentials.map { "⚠ \($0.displayName): add credential" }
            )
        }

        let outcomes = await withTaskGroup(of: (Int, String, String?).self, returning: [(Int, String, String?)].self) { group in
            for (index, manifest) in manifests.enumerated() {
                group.addTask {
                    do {
                        _ = try await fetchManifestInfo(urlString: manifest.manifestURL, session: session)
                        return (index, manifest.displayName, nil)
                    } catch {
                        return (index, manifest.displayName, safeMessage(error))
                    }
                }
            }
            var values: [(Int, String, String?)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }

        let successes = outcomes.compactMap { $0.2 == nil ? $0.1 : nil }
        let failures = outcomes.compactMap { result -> String? in
            guard let error = result.2 else { return nil }
            return "\(result.1): \(error)"
        }
        var details = successes.map { "✓ \($0)" }
        details.append(contentsOf: failures.map { "⚠ \($0)" })
        details.append(contentsOf: missingCredentials.map { "⚠ Torrentio • \($0.displayName): enabled but credential missing" })
        let issueCount = failures.count + missingCredentials.count
        let state: ConnectedServiceHealthState = issueCount == 0 ? .connected : (successes.isEmpty ? .failed : .partial)
        let headline = issueCount == 0
            ? "\(successes.count) account attachment\(successes.count == 1 ? "" : "s") connected"
            : (successes.isEmpty ? "Connection check failed" : "Partially connected")
        return ConnectedServiceHealth(id: "torrentio", name: "Torrentio", state: state, headline: headline, details: details)
    }

    /// Checks every user-saved Stremio manifest without injecting any global credential.
    /// This gives Settings a positive/negative connection report for arbitrary addons,
    /// including a manually configured Debridio URL, without needing an app-specific adapter.
    static func verifySavedStremioAddons(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> [ConnectedServiceHealth] {
        let raw = defaults.stringArray(forKey: "stremioManifestURLs") ?? []
        var seen = Set<String>()
        let saved = raw.compactMap { value -> String? in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !isDebridChannelsInternalManifest(clean) else { return nil }
            let key = clean.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return clean
        }
        guard !saved.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, ConnectedServiceHealth).self, returning: [ConnectedServiceHealth].self) { group in
            for (index, rawURL) in saved.enumerated() {
                group.addTask {
                    let result = await verifySavedAddon(index: index, rawURL: rawURL, session: session)
                    return (index, result)
                }
            }
            var values: [(Int, ConnectedServiceHealth)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func verifySavedAddon(index: Int, rawURL: String, session: URLSession) async -> ConnectedServiceHealth {
        let fallbackName = sanitizedAddonName(from: rawURL)
        var lastError: Error?
        for candidate in manifestCandidates(from: rawURL) {
            do {
                let info = try await fetchManifestInfo(urlString: candidate, session: session)
                var details = ["Manifest reachable"]
                if info.resources.contains("stream") { details.append("Streams advertised") }
                if info.resources.contains("catalog") { details.append("Catalogs advertised") }
                if info.resources.contains("meta") { details.append("Metadata advertised") }
                if info.resources.contains("subtitles") { details.append("Subtitles advertised") }
                return ConnectedServiceHealth(
                    id: "saved-stremio-\(index)",
                    name: info.name.isEmpty ? fallbackName : info.name,
                    state: .connected,
                    headline: "Stremio addon connected",
                    details: details
                )
            } catch {
                lastError = error
            }
        }
        return ConnectedServiceHealth(
            id: "saved-stremio-\(index)",
            name: fallbackName,
            state: .failed,
            headline: "Stremio addon unreachable",
            details: [safeMessage(lastError ?? URLError(.badURL))]
        )
    }

    private static func fetchManifestInfo(urlString: String, session: URLSession) async throws -> StremioManifestHealthInfo {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("DebridChannels-tvOS/vBRDC075", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "StremioHealth", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] != nil || object["name"] != nil || object["resources"] != nil else {
            throw NSError(domain: "StremioHealth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest response"])
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var resources: [String] = []
        if let values = object["resources"] as? [String] {
            resources = values.map { $0.lowercased() }
        } else if let values = object["resources"] as? [[String: Any]] {
            resources = values.compactMap { ($0["name"] as? String)?.lowercased() }
        }
        return StremioManifestHealthInfo(name: name, resources: resources)
    }

    private static func manifestCandidates(from raw: String) -> [String] {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("stremio:///") {
            clean = "https://" + String(clean.dropFirst("stremio:///".count))
        } else if clean.hasPrefix("stremio://") {
            clean = "https://" + String(clean.dropFirst("stremio://".count))
        }
        while clean.hasSuffix("/") { clean.removeLast() }
        var values: [String] = []
        func append(_ value: String) {
            if !value.isEmpty, !values.contains(value) { values.append(value) }
        }
        let lower = clean.lowercased()
        if lower.hasSuffix("/configure") {
            append(String(clean.dropLast("/configure".count)) + "/manifest.json")
            append(clean)
        } else if lower.hasSuffix("/manifest.json") {
            append(clean)
        } else {
            append(clean + "/manifest.json")
            append(clean)
        }
        return values
    }

    private static func sanitizedAddonName(from raw: String) -> String {
        for candidate in manifestCandidates(from: raw) {
            if let host = URL(string: candidate)?.host, !host.isEmpty {
                return host
            }
        }
        return "Saved Stremio Addon"
    }

    private static func isDebridChannelsInternalManifest(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("api.skylinejay187.it.com")
            || lower.contains("catalog.skylinejay187.it.com")
            || lower.contains("catalog.debridchannels")
            || lower.contains("192.168.100.55:8484")
    }

    private struct HealthJSONOutcome {
        let value: Any?
        let error: String?
    }

    private static func healthJSON(urlString: String, bearer: String, session: URLSession) async -> HealthJSONOutcome {
        do {
            let value = try await getJSON(urlString: urlString, bearer: bearer, session: session)
            return HealthJSONOutcome(value: value, error: nil)
        } catch {
            let message = safeMessage(error)
            return HealthJSONOutcome(value: nil, error: message)
        }
    }

    private static func getJSON(urlString: String, bearer: String, session: URLSession) async throws -> Any {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/vBRDC075", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataWithTransientRetry(request: request, session: session, maxAttempts: 3)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = errorDetail(from: data)
            throw NSError(domain: "ConnectedServicesHealth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(detail)"])
        }
        if data.isEmpty { return [:] as [String: Any] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? ([:] as [String: Any])
    }

    private static func dataWithTransientRetry(request: URLRequest, session: URLSession, maxAttempts: Int) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await session.data(for: request)
            } catch {
                attempt += 1
                guard attempt < maxAttempts, isTransientNetworkError(error) else { throw error }
                let delay = UInt64(350_000_000 * attempt)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let code: Int
        if let urlError = error as? URLError {
            code = urlError.errorCode
        } else {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return false }
            code = ns.code
        }
        let transientCodes: Set<Int> = [
            URLError.cannotFindHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.notConnectedToInternet.rawValue,
            URLError.timedOut.rawValue
        ]
        return transientCodes.contains(code)
    }

    private static func integerValue(in object: Any, keys: [String]) -> Int? {
        func search(_ value: Any) -> Int? {
            if let dict = value as? [String: Any] {
                for key in keys {
                    if let number = dict[key] as? NSNumber { return number.intValue }
                    if let string = dict[key] as? String, let number = Int(string) { return number }
                }
                for nested in dict.values {
                    if let found = search(nested) { return found }
                }
            }
            return nil
        }
        return search(object)
    }

    private static func torBoxPlanName(_ plan: Int?) -> String? {
        guard let plan else { return nil }
        switch plan {
        case 0: return "Free"
        case 1: return "Essential"
        case 2: return "Pro"
        case 3: return "Standard"
        default: return "Plan \(plan)"
        }
    }

    private static func errorDetail(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message", "error"] {
                if let value = object[key] as? String { return value }
            }
        }
        return String(data: data.prefix(240), encoding: .utf8) ?? ""
    }

    private static func safeMessage(_ error: Error) -> String {
        let value = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = ReleaseCandidateSecurityManager.redactedText(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? "Unknown connection error" : redacted
    }
}
