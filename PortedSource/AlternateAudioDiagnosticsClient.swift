import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AlternateAudioBridgeDiagnosticsSnapshot: Equatable {
    var preparationStage: String = "Not prepared"
    var preparationPercentage: Int = 0
    var originalVideoSource: String = "Original playback source"
    var alternateAudioSource: String = "Not selected"
    var selectedStreamIndex: String = "Not selected"
    var matchClassification: String = "Not classified"
    var offset: String = "0ms"
    var driftCorrection: String = "Not required"
    var streamModes: String = "Video stream-copy • audio pending"
    var candidateRejectionReason: String = "None"
    var bridgeStatus: String = "Idle"

    static let empty = AlternateAudioBridgeDiagnosticsSnapshot()
}

private struct AlternateAudioBridgeStatusEnvelope: Decodable {
    let status: String?
    let preparationStage: String?
    let preparationPercentage: Int?
    let originalVideoSource: String?
    let alternateAudioSource: String?
    let selectedStreamIndex: Int?
    let matchClassification: String?
    let classification: String?
    let offsetMS: Int?
    let driftCorrection: String?
    let videoMode: String?
    let audioMode: String?
    let audioReason: String?
    let rejectionReason: String?
}

enum AlternateAudioDiagnosticsClient {
    static func fetch(backendBaseURL: String, bridgeUUID: UUID) async -> AlternateAudioBridgeDiagnosticsSnapshot? {
        let base = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/api/alternate-audio/bridge/\(bridgeUUID.uuidString)/status") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 256_000,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let status = try decoder.decode(AlternateAudioBridgeStatusEnvelope.self, from: data)
            let classification = status.matchClassification ?? status.classification ?? "Not classified"
            let modes = "Video \(status.videoMode ?? "stream-copy") • Audio \(status.audioMode ?? "pending")"
            return AlternateAudioBridgeDiagnosticsSnapshot(
                preparationStage: status.preparationStage ?? status.status ?? "Unknown",
                preparationPercentage: max(0, min(100, status.preparationPercentage ?? 0)),
                originalVideoSource: status.originalVideoSource ?? "Original playback source",
                alternateAudioSource: status.alternateAudioSource ?? "Alternate source",
                selectedStreamIndex: status.selectedStreamIndex.map(String.init) ?? "Not selected",
                matchClassification: classification,
                offset: "\(status.offsetMS ?? 0)ms",
                driftCorrection: status.driftCorrection ?? "Not required",
                streamModes: modes + ((status.audioReason?.isEmpty == false) ? " • \(status.audioReason!)" : ""),
                candidateRejectionReason: status.rejectionReason?.isEmpty == false ? status.rejectionReason! : "None",
                bridgeStatus: status.status?.capitalized ?? "Unknown"
            )
        } catch {
            return nil
        }
    }
}
