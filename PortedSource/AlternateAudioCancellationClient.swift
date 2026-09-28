import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct AlternateAudioCancellationRequest: Encodable {
    let schemaVersion: Int
    let playbackPresentationID: String
    let requestUUID: String?
    let bridgeUUID: String?
    let reason: String
}

private struct AlternateAudioCancellationResponse: Decodable {
    let cancelled: Bool?
    let cancelledJobs: Int?
    let cancelledBridges: Int?
}

enum AlternateAudioCancellationClient {
    /// Best-effort lifecycle cancellation. The app never blocks player dismissal on this
    /// request, but backend v668 uses it to terminate the complete ffprobe/ffmpeg process
    /// groups and remove temporary bridge files immediately.
    @discardableResult
    static func cancel(
        backendBaseURL: String,
        playbackPresentationID: UUID,
        requestUUID: UUID? = nil,
        bridgeUUID: UUID? = nil,
        reason: String
    ) async -> Bool {
        let trimmedBase = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let endpoint = URL(string: trimmedBase + "/api/alternate-audio/cancel") else {
            return false
        }

        let payload = AlternateAudioCancellationRequest(
            schemaVersion: 2,
            playbackPresentationID: playbackPresentationID.uuidString,
            requestUUID: requestUUID?.uuidString,
            bridgeUUID: bridgeUUID?.uuidString,
            reason: String(reason.prefix(240))
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return false }
            let decoded = try? JSONDecoder().decode(AlternateAudioCancellationResponse.self, from: data)
            return decoded?.cancelled ?? true
        } catch {
            return false
        }
    }
}
