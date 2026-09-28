import Foundation

struct MembershipEntitlementApplyResult {
    let membershipActive: Bool
    let entitlementStatus: String
    let trialStartedAt: String
    let trialExpiresAt: String
    let planType: String
}

enum MembershipEntitlementManager {
    private static let bootstrapBuildKey = "v584_24_hour_membership_trial"
    private static let bootstrapDefaultsKey = "membershipBootstrapBuild"
    private static let trialExpiresDefaultsKey = "membershipTrialExpiresAt"
    private static let trialStartedDefaultsKey = "membershipTrialStartedAt"
    private static let trialConsumedDefaultsKey = "membershipTrialConsumed"
    private static let activeDefaultsKey = "membershipActive"

    static func auditAndBootstrapFreshTrialIfNeeded() {
        // Backend entitlement is still the source of truth. This keeps the legacy
        // bootstrap marker without creating or extending a local trial.
        UserDefaults.standard.set(bootstrapBuildKey, forKey: bootstrapDefaultsKey)
    }

    static func markExpiredIfNeeded(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: activeDefaultsKey),
              let raw = defaults.string(forKey: trialExpiresDefaultsKey),
              let expires = ISO8601DateFormatter().date(from: raw),
              now >= expires else { return }
        defaults.set(true, forKey: trialConsumedDefaultsKey)
    }

    static func trialExpiryDate(from rawValue: String) -> Date? {
        guard !rawValue.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: rawValue)
    }

    static func isCurrentDeviceLocked(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        isLocked(
            active: defaults.bool(forKey: "membershipActive"),
            entitlementStatusRaw: defaults.string(forKey: "membershipEntitlementStatus") ?? ProductionEntitlementStatus.unknown.rawValue,
            trialExpiresAt: defaults.string(forKey: "membershipTrialExpiresAt") ?? "",
            now: now
        )
    }

    static func isLocked(active: Bool, entitlementStatusRaw: String, trialExpiresAt: String, now: Date) -> Bool {
        let status = ProductionEntitlementStatus(rawBackendValue: entitlementStatusRaw)
        if active && (status == .paidActive || status == .adminActive) { return false }

        switch status {
        case .paidActive, .adminActive:
            return false
        case .trialActive:
            guard let expires = trialExpiryDate(from: trialExpiresAt) else { return true }
            return now >= expires
        case .trialExpired, .locked, .unknown:
            return true
        }
    }

    static func entitlementRequestContext(backendBaseURLString: String) -> (backendBaseURL: URL, deviceId: String, deviceName: String)? {
        guard let backendBaseURL = URL(string: backendBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let deviceId = StableDeviceIdentity.deviceId()
        let deviceName = UserDefaults.standard.string(forKey: "DebridChannelsDeviceName") ?? "Apple TV"
        return (backendBaseURL, deviceId, deviceName)
    }

    static func apply(result: ProductionEntitlementResult, currentTrialStartedAt: String, currentTrialExpiresAt: String) -> MembershipEntitlementApplyResult {
        var active = false
        var expiresAt = currentTrialExpiresAt

        switch result.status {
        case .paidActive, .adminActive:
            active = true
            expiresAt = result.trialExpiresAt ?? ""
        case .trialActive:
            active = false
            expiresAt = result.trialExpiresAt ?? ""
        case .trialExpired, .locked, .unknown:
            active = false
            expiresAt = result.trialExpiresAt ?? currentTrialExpiresAt
        }

        return MembershipEntitlementApplyResult(
            membershipActive: active,
            entitlementStatus: result.status.rawValue,
            trialStartedAt: result.trialStartedAt ?? currentTrialStartedAt,
            trialExpiresAt: expiresAt,
            planType: result.planType ?? ""
        )
    }
}
