import SwiftUI
import Foundation

/// v790 Production Hardening Pass 1: navigation and focus audit helper.
///
/// This manager is intentionally small and deterministic. It centralizes the
/// focus-routing decisions that were previously repeated inline, while leaving
/// view layout and visual behavior unchanged.
final class NavigationFocusAuditManager {
    static let shared = NavigationFocusAuditManager()

    private init() {}

    /// Top menu should yield focus to content only on Down. Other directions stay
    /// owned by the top menu/search row so tvOS does not leak focus sideways.
    func topMenuShouldYieldToContent(direction: SignalMoveDirection) -> Bool {
        direction == .down
    }

    /// Catalog quick panels own Up/Down while they are active. Boundary presses
    /// should be consumed instead of leaking focus to the top menu.
    func catalogQuickPanelConsumesBoundaryMove() -> Bool {
        true
    }

    /// Closing a full-screen catalog overlay should always release any temporary
    /// top-menu lock, then let the owning shell restore normal focus routing.
    func shouldReleaseTopMenuLockWhenClosingOverlay() -> Bool {
        true
    }

    /// Production-hardening audit labels used for build notes and debug logging.
    let auditedAreas: [String] = [
        "Back/Menu overlay close order",
        "Top menu Down-to-content routing",
        "Quick panel Up/Down focus ownership",
        "Quick panel boundary focus consumption",
        "Search overlay exit behavior",
        "Details/Source Intelligence overlay ownership",
        "Player overlay exit behavior",
        "Live TV guide/quick guide focus return",
        "Sports focus return",
        "Membership lockout top-menu access"
    ]
}
