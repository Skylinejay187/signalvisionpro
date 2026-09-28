import Foundation
import SwiftUI

/// v793 Production Hardening: Performance + Loading Optimization.
///
/// Passive helper for startup, scrolling, artwork decode, and background-loading
/// decisions. It does not change UI layout, navigation, player engines, or feature
/// behavior. Screens/managers can consult these policies to avoid unnecessary
/// refreshes and keep work off the critical focus/scroll path.
@MainActor
final class PerformanceLoadingOptimizationManager: ObservableObject {
    static let shared = PerformanceLoadingOptimizationManager()

    struct LoadingPolicy: Equatable {
        let name: String
        let debounceSeconds: TimeInterval
        let minimumRefreshIntervalSeconds: TimeInterval
        let maxConcurrentTasks: Int
        let prefersBackgroundWork: Bool
    }

    let startupPolicy = LoadingPolicy(
        name: "Startup",
        debounceSeconds: 0.10,
        minimumRefreshIntervalSeconds: 2.0,
        maxConcurrentTasks: 3,
        prefersBackgroundWork: true
    )

    let artworkPolicy = LoadingPolicy(
        name: "Artwork Decode",
        debounceSeconds: 0.05,
        minimumRefreshIntervalSeconds: 0.75,
        maxConcurrentTasks: 4,
        prefersBackgroundWork: true
    )

    let catalogPolicy = LoadingPolicy(
        name: "Catalog Rows",
        debounceSeconds: 0.20,
        minimumRefreshIntervalSeconds: 8.0,
        maxConcurrentTasks: 3,
        prefersBackgroundWork: true
    )

    let guidePolicy = LoadingPolicy(
        name: "Live TV Guide",
        debounceSeconds: 0.25,
        minimumRefreshIntervalSeconds: 60.0,
        maxConcurrentTasks: 2,
        prefersBackgroundWork: true
    )

    let sourceSearchPolicy = LoadingPolicy(
        name: "Source Search",
        debounceSeconds: 0.15,
        minimumRefreshIntervalSeconds: 3.0,
        maxConcurrentTasks: 2,
        prefersBackgroundWork: true
    )

    @Published private(set) var lastOptimizationNote: String?

    private var lastRefreshDates: [String: Date] = [:]

    private init() {}

    func canRefresh(key: String, policy: LoadingPolicy, now: Date = Date()) -> Bool {
        guard let last = lastRefreshDates[key] else { return true }
        return now.timeIntervalSince(last) >= policy.minimumRefreshIntervalSeconds
    }

    func markRefreshed(key: String, now: Date = Date()) {
        lastRefreshDates[key] = now
    }

    func shouldDeferHeavyWork(isUserInteracting: Bool, policy: LoadingPolicy) -> Bool {
        return isUserInteracting && policy.prefersBackgroundWork
    }

    func recommendedTaskPriority(for policy: LoadingPolicy, isVisibleWork: Bool) -> TaskPriority {
        if isVisibleWork { return .userInitiated }
        return policy.prefersBackgroundWork ? .utility : .userInitiated
    }

    func clampedConcurrentLimit(requested: Int, policy: LoadingPolicy) -> Int {
        max(1, min(requested, policy.maxConcurrentTasks))
    }

    func note(_ message: String) {
        lastOptimizationNote = message
    }

    func auditSummary() -> [String] {
        [startupPolicy, artworkPolicy, catalogPolicy, guidePolicy, sourceSearchPolicy].map { policy in
            "\(policy.name): debounce=\(policy.debounceSeconds)s minRefresh=\(policy.minimumRefreshIntervalSeconds)s maxTasks=\(policy.maxConcurrentTasks) background=\(policy.prefersBackgroundWork)"
        }
    }
}

struct PerformanceLoadGate: Equatable {
    let key: String
    let policyName: String
    let allowed: Bool
    let reason: String?
}
