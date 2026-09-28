import SwiftUI
import Combine
import UIKit

/// vBRDC182 — UNITY App Core
///
/// One process-wide navigation/theme/runtime authority for Debrid Channels.
/// Existing feature/data managers remain intact; this layer replaces ad-hoc cross-surface
/// handoff signals with a shared app shell that every surface can observe.
///
/// Migration rule:
/// - `UnityAppCore.activeTab` is the shell/navigation truth.
/// - `CatalogStore.selectedTab` remains the compatibility mirror while older feature code
///   is migrated in stages. Any legacy mutation is immediately folded back into UNITY.
/// - The top navigation is persistent and never recreated between normal app surfaces.
/// - Surface presentation can vary independently while colors/runtime policy come from one core.

final class UnityAppCore: ObservableObject {
    static let shared = UnityAppCore()

    enum Surface: String, CaseIterable, Equatable {
        case home
        case movies
        case shows
        case sports
        case favorites
        case liveTV
        case membership
        case settings
        case search
        case detail
        case playback
    }

    struct ThemeState: Equatable {
        var backgroundPreset: String = "Midnight Graphite"
        var accentPreset: String = "Orange"
        var liveTVThemePreset: String = "Classic Dark"
    }

    struct SurfacePolicy: Equatable {
        let keepStateResident: Bool
        let keepPixelsMountedWhenCovered: Bool
        let permitsAmbientMotionWhenVisible: Bool
        let permitsBackgroundPrefetchWhenHidden: Bool

        static let persistentInteractive = SurfacePolicy(
            keepStateResident: true,
            keepPixelsMountedWhenCovered: true,
            permitsAmbientMotionWhenVisible: true,
            permitsBackgroundPrefetchWhenHidden: false
        )
        static let residentDormant = SurfacePolicy(
            keepStateResident: true,
            keepPixelsMountedWhenCovered: false,
            permitsAmbientMotionWhenVisible: true,
            permitsBackgroundPrefetchWhenHidden: false
        )
        static let exclusive = SurfacePolicy(
            keepStateResident: false,
            keepPixelsMountedWhenCovered: false,
            permitsAmbientMotionWhenVisible: false,
            permitsBackgroundPrefetchWhenHidden: false
        )
    }

    @Published private(set) var activeTab: AppTab = .live
    @Published private(set) var previousTab: AppTab = .live
    @Published private(set) var effectiveSurface: Surface = .liveTV
    @Published private(set) var navigationRevision: UInt64 = 0
    @Published private(set) var surfaceRevision: UInt64 = 0
    @Published private(set) var topNavigationActive: Bool = false
    @Published private(set) var topNavigationSession: UInt64 = 0
    @Published private(set) var topNavigationFocusRequest: UInt64 = 0
    @Published private(set) var mirrorTopMenuRevealed: Bool = false
    @Published private(set) var mirrorTopMenuActivityRevision: UInt64 = 0
    @Published private(set) var themeRevision: UInt64 = 0
    @Published private(set) var trailerExclusiveActive: Bool = false
    @Published private(set) var memoryPressureRevision: UInt64 = 0

    private(set) var themeState = ThemeState()
    private(set) var lastNavigationReason: String = "launch"
    private var applyingCoreSelection = false
    private var systemCancellables: Set<AnyCancellable> = []

    private init() {
        let trailerBegin = Notification.Name("DebridChannels.TrailerExclusivePlaybackDidBegin")
        let trailerEnd = Notification.Name("DebridChannels.TrailerExclusivePlaybackDidEnd")

        NotificationCenter.default.publisher(for: trailerBegin)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.trailerExclusiveActive else { return }
                self.trailerExclusiveActive = true
                self.surfaceRevision &+= 1
            }
            .store(in: &systemCancellables)

        NotificationCenter.default.publisher(for: trailerEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.trailerExclusiveActive else { return }
                self.trailerExclusiveActive = false
                self.surfaceRevision &+= 1
            }
            .store(in: &systemCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.memoryPressureRevision &+= 1
            }
            .store(in: &systemCancellables)
    }

    func bootstrap(tab: AppTab) {
        guard navigationRevision == 0 else { return }
        activeTab = tab
        previousTab = tab
        effectiveSurface = surface(for: tab)
        navigationRevision = 1
        surfaceRevision = 1
        lastNavigationReason = "bootstrap"
    }

    /// Compatibility bridge for code that still writes CatalogStore.selectedTab directly.
    /// This prevents two independent navigation truths while the app is migrated surface-by-surface.
    func observeLegacyTabMutation(from oldTab: AppTab, to newTab: AppTab, reason: String = "legacy selectedTab") {
        guard !applyingCoreSelection else { return }
        guard activeTab != newTab || previousTab != oldTab else { return }
        previousTab = oldTab
        activeTab = newTab
        if effectiveSurface != .search && effectiveSurface != .detail && effectiveSurface != .playback {
            effectiveSurface = surface(for: newTab)
            surfaceRevision &+= 1
        }
        lastNavigationReason = reason
        navigationRevision &+= 1
    }

    /// Preferred vBRDC182 navigation entry point. The compatibility store is updated once,
    /// but the shell state is committed first so TopMenu/Root share the same transaction.
    @MainActor
    func select(_ tab: AppTab, store: CatalogStore, reason: String) {
        let old = activeTab
        guard tab != old || store.selectedTab != tab else {
            lastNavigationReason = reason
            return
        }

        previousTab = old
        activeTab = tab
        if effectiveSurface != .search && effectiveSurface != .detail && effectiveSurface != .playback {
            effectiveSurface = surface(for: tab)
            surfaceRevision &+= 1
        }
        lastNavigationReason = reason
        navigationRevision &+= 1

        applyingCoreSelection = true
        if store.selectedTab != tab { store.selectedTab = tab }
        applyingCoreSelection = false
    }

    // vBRDC351: explicitly expose disabled Mirror chrome BEFORE requesting native focus.
    // Focus alone cannot reveal a control whose entire tree is disabled/hidden.
    func revealMirrorTopMenu() {
        mirrorTopMenuRevealed = true
        mirrorTopMenuActivityRevision &+= 1
    }

    func touchMirrorTopMenu() {
        guard mirrorTopMenuRevealed else { return }
        mirrorTopMenuActivityRevision &+= 1
    }

    func hideMirrorTopMenu() {
        guard mirrorTopMenuRevealed else { return }
        mirrorTopMenuRevealed = false
        mirrorTopMenuActivityRevision &+= 1
    }

    func requestTopNavigationFocus(origin: AppTab, reason: String) {
        topNavigationFocusRequest &+= 1
        lastNavigationReason = "top-nav focus request \(origin.rawValue): \(reason)"
        navigationRevision &+= 1
    }

    func setTopNavigationActive(_ active: Bool, origin: AppTab, reason: String) {
        if active {
            guard !topNavigationActive else { return }
            topNavigationActive = true
            topNavigationSession &+= 1
            lastNavigationReason = "top-nav \(origin.rawValue): \(reason)"
        } else {
            guard topNavigationActive else { return }
            topNavigationActive = false
            lastNavigationReason = "top-nav exit: \(reason)"
        }
        navigationRevision &+= 1
    }

    /// One overlay/surface ownership decision for Search, detail and playback. Existing view
    /// trees may remain mounted for restoration, but only this effective surface is considered
    /// the active runtime owner.
    func synchronizeSurfaceOwnership(searchActive: Bool, detailActive: Bool, playbackActive: Bool, reason: String) {
        let next: Surface
        if playbackActive {
            next = .playback
        } else if detailActive {
            next = .detail
        } else if searchActive {
            next = .search
        } else {
            next = surface(for: activeTab)
        }
        guard next != effectiveSurface else { return }
        effectiveSurface = next
        surfaceRevision &+= 1
        lastNavigationReason = "surface ownership: \(reason)"
    }

    func synchronizeTheme(backgroundPreset: String, accentPreset: String, liveTVThemePreset: String) {
        let next = ThemeState(
            backgroundPreset: backgroundPreset,
            accentPreset: accentPreset,
            liveTVThemePreset: liveTVThemePreset
        )
        guard next != themeState else { return }
        themeState = next
        themeRevision &+= 1
    }

    var palette: UnityAppPalette {
        UnityAppPalette(theme: themeState)
    }

    func surface(for tab: AppTab) -> Surface {
        switch tab {
        case .home: return .home
        case .movies: return .movies
        case .shows: return .shows
        case .sports: return .sports
        case .favorites: return .favorites
        case .live: return .liveTV
        case .membership: return .membership
        case .settings: return .settings
        }
    }

    func isRuntimeOwner(_ surface: Surface) -> Bool {
        effectiveSurface == surface
    }

    func policy(for surface: Surface) -> SurfacePolicy {
        switch surface {
        case .liveTV, .home, .movies, .shows:
            return .persistentInteractive
        case .sports, .favorites, .membership, .settings, .search, .detail:
            return .residentDormant
        case .playback:
            return .exclusive
        }
    }
}

/// Shared color tokens. Geometry remains surface-specific: a Guide can look like a Guide,
/// Favorites can look like Favorites, and Live TV cards can retain their own design while all
/// of them consume the same application palette.
struct UnityAppPalette {
    let theme: UnityAppCore.ThemeState

    var backgroundGradient: [Color] {
        MainGridBackgroundStyle.gradientColors(for: theme.backgroundPreset)
    }

    var background: Color {
        backgroundGradient.first ?? .black
    }

    var accent: Color {
        TopMenuAccentColorSystem.color(
            for: theme.accentPreset,
            themeAccent: LiveTVGridThemeStyle.accent(for: theme.liveTVThemePreset)
        )
    }

    var elevatedSurface: Color { Color.white.opacity(isPureBlack ? 0.055 : 0.075) }
    var surface: Color { Color.white.opacity(isPureBlack ? 0.035 : 0.055) }
    var border: Color { Color.white.opacity(isPureBlack ? 0.11 : 0.14) }
    var divider: Color { accent.opacity(isPureBlack ? 0.20 : 0.30) }
    var primaryText: Color { .white }
    var secondaryText: Color { Color.white.opacity(0.64) }
    var tertiaryText: Color { Color.white.opacity(0.42) }
    var focus: Color { accent }

    var isPureBlack: Bool {
        theme.backgroundPreset.lowercased().contains("pure black")
    }
}

/// One shared backdrop for surfaces that opt into UNITY palette ownership. It deliberately
/// contains no surface geometry, cards, blur theme or focus behavior.
struct UnitySurfaceBackdrop: View {
    @EnvironmentObject private var unityCore: UnityAppCore

    var body: some View {
        let palette = unityCore.palette
        LinearGradient(
            colors: palette.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [palette.accent.opacity(palette.isPureBlack ? 0.0 : 0.10), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 920
            )
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
