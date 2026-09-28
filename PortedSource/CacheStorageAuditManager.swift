import Foundation

// v791 Production Hardening Pass 2
// Cache & Storage Audit helper. This is intentionally passive and behavior-preserving:
// it centralizes safe cache sizing/age policies without changing existing cache callers.
final class CacheStorageAuditManager {
    static let shared = CacheStorageAuditManager()

    struct CachePolicy: Equatable {
        let name: String
        let maxAgeSeconds: TimeInterval
        let maxEntries: Int
        let trimsAggressively: Bool
    }

    let artworkPolicy = CachePolicy(name: "Artwork", maxAgeSeconds: 7 * 24 * 60 * 60, maxEntries: 1200, trimsAggressively: false)
    let guidePolicy = CachePolicy(name: "Live TV Guide", maxAgeSeconds: 3 * 60 * 60, maxEntries: 43200, trimsAggressively: false)
    let trailerPolicy = CachePolicy(name: "Trailers", maxAgeSeconds: 14 * 24 * 60 * 60, maxEntries: 500, trimsAggressively: false)
    let metadataPolicy = CachePolicy(name: "Metadata", maxAgeSeconds: 24 * 60 * 60, maxEntries: 2000, trimsAggressively: false)

    private init() {}

    func isExpired(storedAt: Date?, policy: CachePolicy, now: Date = Date()) -> Bool {
        guard let storedAt else { return true }
        return now.timeIntervalSince(storedAt) > policy.maxAgeSeconds
    }

    func shouldTrim(entryCount: Int, policy: CachePolicy) -> Bool {
        return entryCount > policy.maxEntries
    }

    func safeTrimCount(entryCount: Int, policy: CachePolicy) -> Int {
        guard shouldTrim(entryCount: entryCount, policy: policy) else { return 0 }
        let target = policy.trimsAggressively ? Int(Double(policy.maxEntries) * 0.75) : policy.maxEntries
        return max(0, entryCount - target)
    }

    func auditSummary() -> [String] {
        [artworkPolicy, guidePolicy, trailerPolicy, metadataPolicy].map { policy in
            "\(policy.name): maxAge=\(Int(policy.maxAgeSeconds))s maxEntries=\(policy.maxEntries)"
        }
    }
}
