import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BackendProfileBackupResponse {
    let ok: Bool
    let code: String?
    let updatedAt: String?
    let profile: [String: Any]?
    let message: String?
    let payloadByteCount: Int
    let statusCode: Int
}

enum BackendProfileBackupClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The backend address is invalid."
        case .invalidResponse:
            return "The backend returned an invalid response."
        case let .httpStatus(status, message):
            return message.isEmpty ? "The backend returned HTTP \(status)." : "HTTP \(status): \(message)"
        case let .malformedJSON(message):
            return message.isEmpty ? "The backend response was not valid JSON." : message
        }
    }
}

/// Phase 12 full-profile transport used by Settings → Backup / Restore.
///
/// The backend has evolved across releases, so this client accepts both the
/// original route-shaped API and a body-based fallback. It also validates HTTP
/// status codes and flexible response envelopes instead of treating any bytes as
/// success. No credentials are added here; the caller supplies an explicitly allowlisted full profile, including the user
/// configuration required to rebuild Live TV and Source Intelligence on another device.
enum BackendProfileBackupClient {
    static func save(
        baseURL: String,
        code: String,
        profile: [String: Any],
        deviceName: String,
        appBuild: String
    ) async throws -> BackendProfileBackupResponse {
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        var body: [String: Any] = [
            "profile": profile,
            "deviceName": deviceName,
            "platform": "tvOS",
            "appBuild": appBuild,
            "payloadSize": profileData.count,
            "schema": "DebridChannelsProfileBackup.v3"
        ]
        if !code.isEmpty { body["code"] = code }

        let request = try makeJSONRequest(baseURL: baseURL, path: "/api/profile/backup", method: "POST", body: body)
        return try await perform(request)
    }

    static func restore(baseURL: String, code: String) async throws -> BackendProfileBackupResponse {
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        do {
            let request = try makeJSONRequest(baseURL: baseURL, path: "/api/profile/restore/\(escaped)", method: "GET", body: nil)
            return try await perform(request)
        } catch BackendProfileBackupClientError.httpStatus(let status, _) where status == 404 || status == 405 {
            let fallback = try makeJSONRequest(
                baseURL: baseURL,
                path: "/api/profile/restore",
                method: "POST",
                body: ["code": code, "platform": "tvOS"]
            )
            return try await perform(fallback)
        }
    }

    static func clear(baseURL: String, code: String) async throws -> BackendProfileBackupResponse {
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        do {
            let request = try makeJSONRequest(baseURL: baseURL, path: "/api/profile/clear/\(escaped)", method: "DELETE", body: nil)
            return try await perform(request)
        } catch BackendProfileBackupClientError.httpStatus(let status, _) where status == 404 || status == 405 {
            let fallback = try makeJSONRequest(
                baseURL: baseURL,
                path: "/api/profile/clear",
                method: "POST",
                body: ["code": code, "platform": "tvOS"]
            )
            return try await perform(fallback)
        }
    }

    private static func makeJSONRequest(
        baseURL: String,
        path: String,
        method: String,
        body: [String: Any]?
    ) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + path) else {
            throw BackendProfileBackupClientError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: 24)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DebridChannels-tvOS/Phase12", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return request
    }

    private static func perform(_ request: URLRequest) async throws -> BackendProfileBackupResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 24
        configuration.timeoutIntervalForResource = 36
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        #if !os(Linux)
        configuration.waitsForConnectivity = true
        #endif
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendProfileBackupClientError.invalidResponse
        }

        let decoded = decodeEnvelope(data: data, statusCode: http.statusCode)
        guard (200...299).contains(http.statusCode) else {
            throw BackendProfileBackupClientError.httpStatus(http.statusCode, decoded.message ?? "")
        }
        return decoded
    }

    private static func decodeEnvelope(data: Data, statusCode: Int) -> BackendProfileBackupResponse {
        guard !data.isEmpty else {
            return BackendProfileBackupResponse(
                ok: (200...299).contains(statusCode),
                code: nil,
                updatedAt: nil,
                profile: nil,
                message: nil,
                payloadByteCount: 0,
                statusCode: statusCode
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BackendProfileBackupResponse(
                ok: false,
                code: nil,
                updatedAt: nil,
                profile: nil,
                message: text.isEmpty ? "The backend response was not valid JSON." : String(text.prefix(220)),
                payloadByteCount: data.count,
                statusCode: statusCode
            )
        }

        let nested = root["data"] as? [String: Any]
        let ok = boolValue(root["ok"]) ?? boolValue(nested?["ok"]) ?? (200...299).contains(statusCode)
        let code = stringValue(root["code"]) ?? stringValue(nested?["code"]) ?? stringValue(root["backupCode"]) ?? stringValue(nested?["backupCode"])
        let updatedAt = stringValue(root["updatedAt"]) ?? stringValue(nested?["updatedAt"]) ?? stringValue(root["updated_at"]) ?? stringValue(nested?["updated_at"])
        let profile = dictionaryValue(root["profile"])
            ?? dictionaryValue(nested?["profile"])
            ?? dictionaryValue(root["payload"])
            ?? dictionaryValue(nested?["payload"])
            ?? ((root["settings"] as? [String: Any]) != nil ? root : nil)
        let message = stringValue(root["error"])
            ?? stringValue(root["message"])
            ?? stringValue(root["detail"])
            ?? stringValue(nested?["error"])
            ?? stringValue(nested?["message"])
            ?? stringValue(nested?["detail"])

        return BackendProfileBackupResponse(
            ok: ok,
            code: code,
            updatedAt: updatedAt,
            profile: profile,
            message: message,
            payloadByteCount: data.count,
            statusCode: statusCode
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1", "ok", "success": return true
            case "false", "no", "0", "failed", "error": return false
            default: return nil
            }
        }
        return nil
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        return nil
    }
}
