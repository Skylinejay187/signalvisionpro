import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AlternateAudioMatchClassification: String, Codable, CaseIterable, Hashable {
    case exactMatch = "Exact Match"
    case offsetMatch = "Offset Match"
    case driftCorrectable = "Drift Correctable"
    case possibleMatch = "Possible Match"
    case incompatible = "Incompatible"

    var isSelectable: Bool { true } // vBRDC162: local dual-source audio never uses bridge-era compatibility as a gate.
}

enum AlternateAudioDiscoveryState: String, Hashable {
    case idle
    case preparing
    case probing
    case complete
    case failed
}

private struct AlternateAudioDiscoveryIdentity: Encodable {
    let mediaID: String
    let imdbID: String?
    let tmdbID: String?
    let tvdbID: String?
    let mediaType: String
    let title: String
    let year: String
    let seasonNumber: Int?
    let episodeNumber: Int?
}

private struct AlternateAudioDiscoveryMediaSource: Encodable {
    let url: String
    let provider: String
    let filename: String
    let quality: String
    let size: String
    let infoHash: String?
    let fileIndex: Int?
}

private struct AlternateAudioDiscoveryRequest: Encodable {
    let schemaVersion: Int
    let requestUUID: String
    let playbackPresentationID: String
    let identity: AlternateAudioDiscoveryIdentity
    let currentSource: AlternateAudioDiscoveryMediaSource
    let candidates: [AlternateAudioDiscoveryMediaSource]
    let preferredLanguages: [String]
    let includeCommentary: Bool
    let includeDescriptiveAudio: Bool
    let enableSampledVideoFingerprint: Bool
}

private struct AlternateAudioTrackProbe: Decodable {
    let streamIndex: Int?
    let codec: String?
    let language: String?
    let title: String?
    let isDefault: Bool?
    let isCommentary: Bool?
    let isDescriptive: Bool?
}

private struct AlternateAudioDiscoveryResult: Decodable {
    let url: String
    let provider: String?
    let filename: String?
    let quality: String?
    let size: String?
    let classification: AlternateAudioMatchClassification
    let confidence: String?
    let selectedAudioTrack: AlternateAudioTrackProbe?
    let durationSeconds: Double?
    let startTimeSeconds: Double?
    let frameRate: Double?
    let edition: String?
    let chapterCount: Int?
    let fingerprintSimilarity: Double?
    let fingerprintStatus: String?
    let rejectionReason: String?
    let releaseMetadata: String?
}

private struct AlternateAudioDiscoveryResponse: Decodable {
    let schemaVersion: Int?
    let status: String?
    let scannedCount: Int?
    let compatibleCount: Int?
    let results: [AlternateAudioDiscoveryResult]
}

enum AlternateAudioDiscoveryClientError: LocalizedError {
    case backendNotConfigured
    case noResolvedCandidates
    case invalidResponse
    case responseTooLarge
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "The Debrid Channels backend URL is not configured."
        case .noResolvedCandidates:
            return "No resolved Source Intelligence candidates are available to inspect."
        case .invalidResponse:
            return "The Alternate Audio discovery service returned an invalid response."
        case .responseTooLarge:
            return "The Alternate Audio discovery response exceeded the safe size limit."
        case .backendRejected(let message):
            return message
        }
    }
}

enum AlternateAudioDiscoveryClient {
    private static let maximumCandidates = 16
    private static let maximumResponseBytes = 2_000_000

    static func discover(
        backendBaseURL: String,
        item: MediaItem,
        currentURL: URL,
        currentLabel: String,
        links: [StreamLink],
        requestUUID: UUID,
        playbackPresentationID: UUID,
        preferredLanguage: String = "English",
        includeCommentary: Bool = false,
        includeDescriptiveAudio: Bool = false
    ) async throws -> [AlternateAudioSource] {
        let trimmedBase = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let endpoint = URL(string: trimmedBase + "/api/alternate-audio/discover") else {
            throw AlternateAudioDiscoveryClientError.backendNotConfigured
        }

        var seen = Set<String>()
        let resolvedCandidates = links.compactMap { link -> AlternateAudioDiscoveryMediaSource? in
            guard link.isDirectPlayable,
                  let raw = link.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != currentURL.absoluteString,
                  !seen.contains(raw) else { return nil }
            seen.insert(raw)
            return AlternateAudioDiscoveryMediaSource(
                url: raw,
                provider: link.source,
                filename: link.title,
                quality: link.quality,
                size: link.size,
                infoHash: link.infoHash,
                fileIndex: link.fileIndex
            )
        }
        .prefix(maximumCandidates)

        guard !resolvedCandidates.isEmpty else {
            throw AlternateAudioDiscoveryClientError.noResolvedCandidates
        }

        let identity = AlternateAudioDiscoveryIdentity(
            mediaID: item.id,
            imdbID: item.imdbId,
            tmdbID: item.tmdbId,
            tvdbID: item.tvdbId,
            mediaType: item.type,
            title: item.title,
            year: item.year,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber
        )
        let currentSource = AlternateAudioDiscoveryMediaSource(
            url: currentURL.absoluteString,
            provider: "Current playback source",
            filename: currentLabel,
            quality: "",
            size: "",
            infoHash: nil,
            fileIndex: nil
        )
        let requestPayload = AlternateAudioDiscoveryRequest(
            schemaVersion: 1,
            requestUUID: requestUUID.uuidString,
            playbackPresentationID: playbackPresentationID.uuidString,
            identity: identity,
            currentSource: currentSource,
            candidates: Array(resolvedCandidates),
            preferredLanguages: [preferredLanguage, "eng", "en"],
            includeCommentary: includeCommentary,
            includeDescriptiveAudio: includeDescriptiveAudio,
            enableSampledVideoFingerprint: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else {
            throw AlternateAudioDiscoveryClientError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw AlternateAudioDiscoveryClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: Data(data.prefix(1_000)), encoding: .utf8) ?? ""
            throw AlternateAudioDiscoveryClientError.backendRejected(
                body.isEmpty ? "Alternate Audio discovery failed with HTTP \(http.statusCode)." : body
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(AlternateAudioDiscoveryResponse.self, from: data)

        return payload.results.map { result in
            let track = result.selectedAudioTrack
            return AlternateAudioSource(
                title: result.filename?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Alternate source",
                url: result.url,
                quality: result.quality ?? "",
                source: result.provider ?? "Source Intelligence",
                confidence: result.confidence ?? result.classification.rawValue,
                matchClassification: result.classification.rawValue,
                audioTrackIndex: track?.streamIndex,
                audioCodec: track?.codec,
                audioLanguage: track?.language,
                audioTrackTitle: track?.title,
                durationSeconds: result.durationSeconds,
                startTimeSeconds: result.startTimeSeconds,
                frameRate: result.frameRate,
                edition: result.edition,
                chapterCount: result.chapterCount,
                fingerprintSimilarity: result.fingerprintSimilarity,
                fingerprintStatus: result.fingerprintStatus,
                rejectionReason: result.rejectionReason,
                releaseMetadata: result.releaseMetadata,
                isCommentary: track?.isCommentary ?? false,
                isDescriptiveAudio: track?.isDescriptive ?? false
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
