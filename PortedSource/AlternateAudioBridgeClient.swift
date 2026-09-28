import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AlternateAudioBridgeState: String, Hashable {
    case idle
    case validating
    case preparing
    case ready
    case failed
}

struct AlternateAudioBridgeSession: Identifiable, Hashable {
    let id: UUID
    let hlsURL: URL
    let originalSourceURL: URL
    let expiresAt: Date?
    let classification: String
    let offsetMS: Int
    let videoMode: String
    let audioMode: String
    let audioReason: String
    let selectedStreamIndex: Int
    let selectedAudioCodec: String
    let status: String
    let jobFingerprint: String?
    let reusedExisting: Bool
    let reuseKind: String?
    let signedPlayback: Bool
    let playbackCredentialExpiresAt: Date?
    let preparationStage: String?
    let preparationPercentage: Int?
    let originalVideoSource: String?
    let alternateAudioSource: String?
    let driftCorrection: String?
    let rejectionReason: String?

    var diagnosticSummary: String {
        let reuse = reusedExisting ? " • reused \(reuseKind ?? "existing")" : ""
        let security = signedPlayback ? " • signed playback" : ""
        return "\(status.capitalized) • \(classification) • video \(videoMode) • audio \(audioMode) • stream \(selectedStreamIndex) • \(offsetMS)ms\(reuse)\(security)"
    }
}

private struct AlternateAudioBridgeIdentity: Encodable {
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

private struct AlternateAudioBridgeCurrentSource: Encodable {
    let url: String
    let provider: String
    let filename: String
}

private struct AlternateAudioBridgeTrack: Encodable {
    let streamIndex: Int
    let codec: String
    let language: String
    let title: String
}

private struct AlternateAudioBridgeCandidate: Encodable {
    let url: String
    let provider: String
    let filename: String
    let classification: String
    let selectedAudioTrack: AlternateAudioBridgeTrack
}

private struct AlternateAudioBridgeRequest: Encodable {
    let schemaVersion: Int
    let requestUUID: String
    let identity: AlternateAudioBridgeIdentity
    let currentSource: AlternateAudioBridgeCurrentSource
    let alternateAudioSource: AlternateAudioBridgeCandidate
    let offsetMS: Int
    let playbackPresentationID: String
}

private struct AlternateAudioBridgeResponse: Decodable {
    let schemaVersion: Int?
    let status: String
    let bridgeUUID: String
    let hlsURL: String
    let expiresAt: String?
    let originalSourceURL: String
    let originalSourceAvailable: Bool?
    let classification: String
    let offsetMS: Int
    let videoMode: String
    let audioMode: String
    let audioReason: String
    let selectedStreamIndex: Int
    let selectedAudioCodec: String
    let phase4HandoffRequired: Bool?
    let jobFingerprint: String?
    let reusedExisting: Bool?
    let reuseKind: String?
    let signedPlayback: Bool?
    let playbackCredentialExpiresAt: String?
    let phase10Security: Bool?
    let preparationStage: String?
    let preparationPercentage: Int?
    let originalVideoSource: String?
    let alternateAudioSource: String?
    let driftCorrection: String?
    let rejectionReason: String?
}

enum AlternateAudioBridgeClientError: LocalizedError {
    case backendNotConfigured
    case noCandidateSelected
    case incompatibleCandidate
    case missingAudioStream
    case invalidResponse
    case responseTooLarge
    case originalSourceNotPreserved
    case unsignedPlaybackURL
    case expiredPlaybackCredential
    case backendRejected(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "The Debrid Channels backend URL is not configured."
        case .noCandidateSelected:
            return "Select a compatible Alternate Audio candidate first."
        case .incompatibleCandidate:
            return "Only Exact Match, Offset Match, or Drift Correctable candidates can prepare a bridge."
        case .missingAudioStream:
            return "The selected candidate does not contain a verified English stream index."
        case .invalidResponse:
            return "The Alternate Audio bridge service returned an invalid response."
        case .responseTooLarge:
            return "The Alternate Audio bridge response exceeded the safe size limit."
        case .originalSourceNotPreserved:
            return "The bridge response did not preserve the original playback source."
        case .unsignedPlaybackURL:
            return "The Phase 10 backend did not return a signed, session-owned playback URL."
        case .expiredPlaybackCredential:
            return "The bridge playback credential expired before handoff could begin."
        case .backendRejected(let message):
            return message
        }
    }
}

enum AlternateAudioBridgeClient {
    private static let maximumResponseBytes = 512_000
    private static let bridgeCompatibleClassifications: Set<String> = [
        AlternateAudioMatchClassification.exactMatch.rawValue,
        AlternateAudioMatchClassification.offsetMatch.rawValue,
        AlternateAudioMatchClassification.driftCorrectable.rawValue
    ]

    static func prepare(
        backendBaseURL: String,
        item: MediaItem,
        currentURL: URL,
        currentLabel: String,
        source: AlternateAudioSource,
        offsetMS: Int,
        playbackPresentationID: UUID,
        requestUUID: UUID
    ) async throws -> AlternateAudioBridgeSession {
        let trimmedBase = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let endpoint = URL(string: trimmedBase + "/api/alternate-audio/bridge") else {
            throw AlternateAudioBridgeClientError.backendNotConfigured
        }
        guard bridgeCompatibleClassifications.contains(source.matchClassification) else {
            throw AlternateAudioBridgeClientError.incompatibleCandidate
        }
        guard let streamIndex = source.audioTrackIndex else {
            throw AlternateAudioBridgeClientError.missingAudioStream
        }

        let identity = AlternateAudioBridgeIdentity(
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
        let currentSource = AlternateAudioBridgeCurrentSource(
            url: currentURL.absoluteString,
            provider: "Current playback source",
            filename: currentLabel
        )
        let candidate = AlternateAudioBridgeCandidate(
            url: source.url,
            provider: source.source,
            filename: source.title,
            classification: source.matchClassification,
            selectedAudioTrack: AlternateAudioBridgeTrack(
                streamIndex: streamIndex,
                codec: source.audioCodec ?? "unknown",
                language: source.audioLanguage ?? "eng",
                title: source.audioTrackTitle ?? "English"
            )
        )
        let payload = AlternateAudioBridgeRequest(
            schemaVersion: 2,
            requestUUID: requestUUID.uuidString,
            identity: identity,
            currentSource: currentSource,
            alternateAudioSource: candidate,
            offsetMS: offsetMS,
            playbackPresentationID: playbackPresentationID.uuidString
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else {
            throw AlternateAudioBridgeClientError.responseTooLarge
        }
        guard let http = response as? HTTPURLResponse else {
            throw AlternateAudioBridgeClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: Data(data.prefix(2_000)), encoding: .utf8) ?? ""
            throw AlternateAudioBridgeClientError.backendRejected(
                body.isEmpty ? "Alternate Audio bridge failed with HTTP \(http.statusCode)." : body
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(AlternateAudioBridgeResponse.self, from: data)
        guard result.originalSourceAvailable != false,
              let returnedOriginal = URL(string: result.originalSourceURL),
              returnedOriginal == currentURL else {
            throw AlternateAudioBridgeClientError.originalSourceNotPreserved
        }
        guard let bridgeID = UUID(uuidString: result.bridgeUUID) else {
            throw AlternateAudioBridgeClientError.invalidResponse
        }
        guard result.phase10Security == true, result.signedPlayback == true,
              let hlsURL = resolvedURL(result.hlsURL, backendBaseURL: trimmedBase),
              let components = URLComponents(url: hlsURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw AlternateAudioBridgeClientError.unsignedPlaybackURL
        }
        let credential = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        let expectedPresentationID = playbackPresentationID.uuidString.lowercased()
        guard credential["dc_pid"]?.lowercased() == expectedPresentationID,
              !(credential["dc_sig"] ?? "").isEmpty,
              !(credential["dc_nonce"] ?? "").isEmpty,
              let expiresEpoch = TimeInterval(credential["dc_exp"] ?? ""),
              expiresEpoch > Date().timeIntervalSince1970 else {
            throw AlternateAudioBridgeClientError.unsignedPlaybackURL
        }

        let formatter = ISO8601DateFormatter()
        let expiration: Date? = {
            guard let value = result.expiresAt else { return nil }
            return formatter.date(from: value)
        }()
        let credentialExpiration = result.playbackCredentialExpiresAt.flatMap { formatter.date(from: $0) }
            ?? Date(timeIntervalSince1970: expiresEpoch)
        guard credentialExpiration.timeIntervalSinceNow > 1 else {
            throw AlternateAudioBridgeClientError.expiredPlaybackCredential
        }
        return AlternateAudioBridgeSession(
            id: bridgeID,
            hlsURL: hlsURL,
            originalSourceURL: returnedOriginal,
            expiresAt: expiration,
            classification: result.classification,
            offsetMS: result.offsetMS,
            videoMode: result.videoMode,
            audioMode: result.audioMode,
            audioReason: result.audioReason,
            selectedStreamIndex: result.selectedStreamIndex,
            selectedAudioCodec: result.selectedAudioCodec,
            status: result.status,
            jobFingerprint: result.jobFingerprint,
            reusedExisting: result.reusedExisting ?? false,
            reuseKind: result.reuseKind,
            signedPlayback: true,
            playbackCredentialExpiresAt: credentialExpiration,
            preparationStage: result.preparationStage,
            preparationPercentage: result.preparationPercentage,
            originalVideoSource: result.originalVideoSource,
            alternateAudioSource: result.alternateAudioSource,
            driftCorrection: result.driftCorrection,
            rejectionReason: result.rejectionReason
        )
    }

    private static func resolvedURL(_ raw: String, backendBaseURL: String) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard let base = URL(string: backendBaseURL + "/") else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}
