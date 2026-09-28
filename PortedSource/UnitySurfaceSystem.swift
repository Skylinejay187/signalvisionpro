import Foundation

// vBRDC182 — Code Name: UNITY Re-Core
//
// The app is one persistent shell with independently modifiable surfaces. Visual unity now
// means shared navigation, palette, focus/motion/lifecycle and resource ownership — not that
// every section must reuse the same layout or card theme.
//
// Compatibility note: the pre-v182 catalog/live-root contracts are preserved below while
// surface-by-surface migration moves their navigation authority into UnityAppCore.
enum UnitySurfaceSystem {
    static let codeName = "Unity"
    static let displayCodeName = "UNITY"

    enum SurfaceRole: String {
        case liveRoot
        case catalogBranch
        case sportsBranch
        case dedicatedSurface
    }

    /// Rendering policy is intentionally separate from presentation style. A surface can keep
    /// its state resident while its pixels and expensive work are dormant underneath another
    /// owner. This is the core distinction between UNITY and simply stacking SwiftUI views.
    struct RuntimePolicy: Equatable {
        let stateResident: Bool
        let pixelsResidentWhenCovered: Bool
        let backgroundWorkWhenCovered: Bool
        let ownsGlobalTopNavigation: Bool
    }

    static func role(for tab: AppTab) -> SurfaceRole {
        switch tab {
        case .live:
            return .liveRoot
        case .home, .movies, .shows:
            return .catalogBranch
        case .sports:
            return .sportsBranch
        case .favorites, .membership, .settings:
            return .dedicatedSurface
        }
    }

    static func runtimePolicy(for tab: AppTab) -> RuntimePolicy {
        switch tab {
        case .live:
            return RuntimePolicy(
                stateResident: true,
                pixelsResidentWhenCovered: true,
                backgroundWorkWhenCovered: false,
                ownsGlobalTopNavigation: true
            )
        case .home, .movies, .shows:
            return RuntimePolicy(
                stateResident: true,
                pixelsResidentWhenCovered: true,
                backgroundWorkWhenCovered: false,
                ownsGlobalTopNavigation: true
            )
        case .sports, .favorites, .membership, .settings:
            return RuntimePolicy(
                stateResident: true,
                pixelsResidentWhenCovered: false,
                backgroundWorkWhenCovered: false,
                ownsGlobalTopNavigation: true
            )
        }
    }

    // UNITY visual invariant: preserve the physical Live TV root, its decoded artwork,
    // and the shared catalog backdrop across every non-playback tab. Covered work is
    // suspended independently of visual identity.
    static func keepsLiveTVRootMounted(for tab: AppTab) -> Bool {
        runtimePolicy(for: tab).stateResident
    }

    static func shouldCompositeLiveTVRoot(for tab: AppTab) -> Bool {
        switch role(for: tab) {
        case .liveRoot, .catalogBranch:
            return true
        case .sportsBranch, .dedicatedSurface:
            return false
        }
    }

    static func catalogBranchActive(for tab: AppTab) -> Bool {
        role(for: tab) == .catalogBranch
    }

    static func quickPanelBranchActive(for tab: AppTab) -> Bool {
        switch role(for: tab) {
        case .catalogBranch, .sportsBranch:
            return true
        case .liveRoot, .dedicatedSurface:
            return false
        }
    }

    static func backDestination(from tab: AppTab) -> AppTab {
        switch role(for: tab) {
        case .catalogBranch, .sportsBranch:
            return .live
        case .liveRoot, .dedicatedSurface:
            return tab
        }
    }
}
