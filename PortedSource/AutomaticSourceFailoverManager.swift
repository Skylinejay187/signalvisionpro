import Foundation

/// Phase 6 startup-only recovery context.
///
/// The currently selected Source Intelligence link stays authoritative until the
/// playback engine reports a real startup failure. Recovery may advance only through
/// the already-ranked direct links owned by the exact movie/episode playback session.
struct AutomaticSourceFailoverContext: Equatable {
    let failedURL: URL
    let replacementURL: URL
    let targetPresentationID: UUID
    let attempt: Int
    let availableFallbacks: Int
    let resumeSeconds: Double
    let failureReason: String

    static let notice = "Source unavailable — trying the next ranked link"

    var diagnosticSummary: String {
        "attempt \(attempt)/\(availableFallbacks) • resume \(String(format: "%.2f", resumeSeconds))s • \(failureReason)"
    }
}

enum AutomaticSourceFailoverPolicy {
    static func nextCandidate(after failedURL: URL, in rankedURLs: [URL]) -> (index: Int, url: URL)? {
        guard let failedIndex = rankedURLs.firstIndex(of: failedURL) else { return nil }
        let nextIndex = rankedURLs.index(after: failedIndex)
        guard rankedURLs.indices.contains(nextIndex) else { return nil }
        return (nextIndex, rankedURLs[nextIndex])
    }

    static func normalizedResumeSeconds(_ values: Double?...) -> Double {
        values.compactMap { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }.max() ?? 0
    }

    static func compactFailureReason(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(220))
    }
}
