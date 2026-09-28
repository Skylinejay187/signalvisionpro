import Foundation
import SwiftUI

/// v792 Production Hardening: Error Handling + User Feedback cleanup.
///
/// This manager centralizes safe user-facing wording for loading, retry, timeout,
/// offline, and graceful-failure states. It is intentionally UI-neutral so existing
/// screens can adopt it incrementally without changing layout, focus, player engines,
/// or navigation behavior.
@MainActor
final class ErrorUserFeedbackManager: ObservableObject {
    static let shared = ErrorUserFeedbackManager()

    @Published private(set) var activeMessage: UserFeedbackMessage?
    @Published private(set) var lastDismissedMessageID: String?

    private var shownRecently: [String: Date] = [:]
    private let duplicateSuppressionWindow: TimeInterval = 4

    private init() {}

    func loading(_ title: String, context: String? = nil) -> UserFeedbackMessage {
        UserFeedbackMessage(kind: .loading, title: title, detail: context, retryTitle: nil)
    }

    func success(_ title: String, context: String? = nil) -> UserFeedbackMessage {
        UserFeedbackMessage(kind: .success, title: title, detail: context, retryTitle: nil)
    }

    func failure(_ title: String, error: Error? = nil, retryTitle: String? = "Try Again") -> UserFeedbackMessage {
        UserFeedbackMessage(kind: .failure, title: title, detail: Self.friendlyDetail(for: error), retryTitle: retryTitle)
    }

    func timeout(_ title: String, retryTitle: String? = "Retry") -> UserFeedbackMessage {
        UserFeedbackMessage(kind: .timeout, title: title, detail: "The request took too long. Check the source and try again.", retryTitle: retryTitle)
    }

    func offline(_ title: String = "Connection unavailable", retryTitle: String? = "Retry") -> UserFeedbackMessage {
        UserFeedbackMessage(kind: .offline, title: title, detail: "Check your network connection and try again.", retryTitle: retryTitle)
    }

    func present(_ message: UserFeedbackMessage, suppressDuplicates: Bool = true) {
        if suppressDuplicates && wasShownRecently(message) { return }
        shownRecently[message.deduplicationKey] = Date()
        activeMessage = message
        pruneSuppressionCache()
    }

    func dismiss() {
        lastDismissedMessageID = activeMessage?.id
        activeMessage = nil
    }

    func normalize(_ error: Error?, fallbackTitle: String = "Something went wrong") -> UserFeedbackMessage {
        guard let error else {
            return failure(fallbackTitle, error: nil)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return offline()
            case .timedOut:
                return timeout(fallbackTitle)
            default:
                return failure(fallbackTitle, error: urlError)
            }
        }
        return failure(fallbackTitle, error: error)
    }

    private func wasShownRecently(_ message: UserFeedbackMessage) -> Bool {
        guard let previous = shownRecently[message.deduplicationKey] else { return false }
        return Date().timeIntervalSince(previous) < duplicateSuppressionWindow
    }

    private func pruneSuppressionCache() {
        let now = Date()
        shownRecently = shownRecently.filter { now.timeIntervalSince($0.value) < 30 }
    }

    static func friendlyDetail(for error: Error?) -> String? {
        guard let error else { return nil }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The request timed out. Try again in a moment."
            case .notConnectedToInternet, .networkConnectionLost:
                return "The network connection was lost. Check your connection and retry."
            case .cannotFindHost, .cannotConnectToHost:
                return "The server could not be reached. Try again shortly."
            case .badServerResponse:
                return "The server returned an unexpected response."
            default:
                return "The request could not be completed."
            }
        }
        return "The action could not be completed."
    }
}

struct UserFeedbackMessage: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case loading
        case success
        case failure
        case timeout
        case offline
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    let retryTitle: String?

    init(kind: Kind, title: String, detail: String?, retryTitle: String?) {
        self.id = UUID().uuidString
        self.kind = kind
        self.title = title
        self.detail = detail
        self.retryTitle = retryTitle
    }

    var deduplicationKey: String {
        [kind.rawValue, title, detail ?? ""].joined(separator: "|")
    }
}

struct UserFeedbackRetryPolicy: Equatable {
    let maxAttempts: Int
    let baseDelaySeconds: TimeInterval
    let timeoutSeconds: TimeInterval

    static let catalog = UserFeedbackRetryPolicy(maxAttempts: 2, baseDelaySeconds: 0.7, timeoutSeconds: 12)
    static let guide = UserFeedbackRetryPolicy(maxAttempts: 2, baseDelaySeconds: 1.0, timeoutSeconds: 18)
    static let trailer = UserFeedbackRetryPolicy(maxAttempts: 1, baseDelaySeconds: 0.8, timeoutSeconds: 15)
    static let sourceSearch = UserFeedbackRetryPolicy(maxAttempts: 1, baseDelaySeconds: 0.6, timeoutSeconds: 18)
    static let playbackPreflight = UserFeedbackRetryPolicy(maxAttempts: 1, baseDelaySeconds: 0.5, timeoutSeconds: 10)
}
