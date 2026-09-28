import Foundation
import Combine

/// vBRDC102 — Code Name: UNITY
///
/// Compatibility facade for every existing visual feature. The actual frame-ownership
/// policy now lives in UnityFrameRuntime so themes, row motion, Live TV, wallpaper and
/// artwork publication share one clock instead of independently guessing when to yield.
final class UnityAnimationCoordinator: ObservableObject {
    static let shared = UnityAnimationCoordinator()

    enum Feature: String, CaseIterable {
        case dynamicWallpaper
        case catalogFocusArrival
        case catalogPulse
        case catalogPreview
        case catalogRowMotion
        case detailTransition
        case detailConnector
        case sourceIntelligenceMotion
        case liveTVMotion
        case guideMotion
        case sportsMotion
        case tickerMotion
        case overlayChrome
        case playbackChrome
        case alertMotion
    }

    struct GlobalContext: Equatable {
        var sceneActive: Bool = true
        var globalSearchActive: Bool = false
        var settingsActive: Bool = false
        var detailActive: Bool = false
        var fullScreenPlaybackActive: Bool = false
    }

    @Published private(set) var revision: UInt64 = 0
    private(set) var context = GlobalContext()
    private(set) var sourceSearchActive: Bool = false
    private(set) var sourceOpeningActive: Bool = false
    private(set) var trailerExclusiveActive: Bool = false
    private(set) var guideActive: Bool = false

    private let frameRuntime = UnityFrameRuntime.shared
    private var frameRuntimeSubscription: AnyCancellable?

    var navigationBurstActive: Bool { frameRuntime.snapshot.navigationActive }
    var navigationBurstSource: String { frameRuntime.snapshot.navigationSource }
    var postNavigationVisualRecoveryActive: Bool { frameRuntime.snapshot.postNavigationRecoveryActive }
    var surfaceHandoffActive: Bool { frameRuntime.snapshot.surfaceTransitionActive }

    private init() {
        frameRuntimeSubscription = frameRuntime.$revision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.revision &+= 1
            }
    }

    func synchronizeGlobal(
        sceneActive: Bool,
        globalSearchActive: Bool,
        settingsActive: Bool,
        detailActive: Bool,
        fullScreenPlaybackActive: Bool
    ) {
        let next = GlobalContext(
            sceneActive: sceneActive,
            globalSearchActive: globalSearchActive,
            settingsActive: settingsActive,
            detailActive: detailActive,
            fullScreenPlaybackActive: fullScreenPlaybackActive
        )
        let changed = next != context
        context = next
        let runtimeRevisionBefore = frameRuntime.revision
        frameRuntime.synchronizeExclusiveState(
            sceneActive: sceneActive,
            sourceOpeningActive: sourceOpeningActive,
            trailerActive: trailerExclusiveActive,
            playbackActive: fullScreenPlaybackActive
        )
        if changed, frameRuntime.revision == runtimeRevisionBefore { bumpIfRuntimeDidNotPublish() }
    }

    func registerNavigationActivity(source: String, settleAfter: TimeInterval = 0.18) {
        frameRuntime.registerNavigationActivity(source: source, settleAfter: settleAfter)
    }

    /// High-churn image/model publishers use this compatibility API. A caller explicitly
    /// marked for surface-handoff publication is treated as critical visible artwork.
    func shouldDeferVisualPublication(
        allowDuringSurfaceHandoff: Bool = false,
        allowDuringPlayback: Bool = false
    ) -> Bool {
        frameRuntime.shouldDeferVisualPublication(
            critical: allowDuringSurfaceHandoff,
            allowDuringPlayback: allowDuringPlayback
        )
    }

    var shouldDeferNoncriticalVisualPublication: Bool {
        frameRuntime.shouldDeferVisualPublication(critical: false)
    }

    func setSourceIntelligence(searching: Bool, opening: Bool) {
        guard searching != sourceSearchActive || opening != sourceOpeningActive else { return }
        sourceSearchActive = searching
        sourceOpeningActive = opening
        let runtimeRevisionBefore = frameRuntime.revision
        frameRuntime.synchronizeExclusiveState(
            sceneActive: context.sceneActive,
            sourceOpeningActive: opening,
            trailerActive: trailerExclusiveActive,
            playbackActive: context.fullScreenPlaybackActive
        )
        if frameRuntime.revision == runtimeRevisionBefore { bumpIfRuntimeDidNotPublish() }
    }

    func setTrailerExclusiveActive(_ active: Bool) {
        guard active != trailerExclusiveActive else { return }
        trailerExclusiveActive = active
        let runtimeRevisionBefore = frameRuntime.revision
        frameRuntime.synchronizeExclusiveState(
            sceneActive: context.sceneActive,
            sourceOpeningActive: sourceOpeningActive,
            trailerActive: active,
            playbackActive: context.fullScreenPlaybackActive
        )
        if frameRuntime.revision == runtimeRevisionBefore { bumpIfRuntimeDidNotPublish() }
    }

    func setGuideActive(_ active: Bool) {
        guard active != guideActive else { return }
        guideActive = active
        revision &+= 1
    }

    func setSurfaceHandoffActive(_ active: Bool) {
        frameRuntime.setSurfaceTransitionActive(active, source: "surface-handoff")
    }

    func resetTransientOwnership() {
        let changed = sourceSearchActive || sourceOpeningActive || trailerExclusiveActive || guideActive || surfaceHandoffActive || navigationBurstActive || postNavigationVisualRecoveryActive
        sourceSearchActive = false
        sourceOpeningActive = false
        trailerExclusiveActive = false
        guideActive = false
        frameRuntime.resetTransientOwnership()
        frameRuntime.synchronizeExclusiveState(
            sceneActive: context.sceneActive,
            sourceOpeningActive: false,
            trailerActive: false,
            playbackActive: context.fullScreenPlaybackActive
        )
        if changed { revision &+= 1 }
    }

    func allows(_ feature: Feature) -> Bool {
        guard context.sceneActive else { return false }
        guard frameRuntime.permits(runtimeLane(for: feature)) else { return false }

        switch feature {
        case .dynamicWallpaper:
            return !context.globalSearchActive
                && !context.settingsActive
                && !context.detailActive
                && !guideActive
                && !sourceSearchActive

        case .catalogPreview:
            return !context.globalSearchActive
                && !context.settingsActive
                && !guideActive

        case .catalogPulse:
            return !context.globalSearchActive
                && !context.settingsActive
                && !guideActive
                && !context.detailActive

        case .catalogFocusArrival, .catalogRowMotion:
            return !context.globalSearchActive
                && !context.settingsActive
                && !guideActive
                && !context.detailActive

        case .detailTransition, .detailConnector:
            return context.detailActive && !context.globalSearchActive

        case .sourceIntelligenceMotion:
            return context.detailActive && !context.globalSearchActive

        case .liveTVMotion:
            return !context.globalSearchActive && !context.settingsActive && !context.detailActive

        case .guideMotion:
            return guideActive && !context.globalSearchActive && !context.settingsActive

        case .sportsMotion:
            return !context.globalSearchActive && !context.settingsActive && !context.detailActive

        case .tickerMotion:
            return !context.globalSearchActive && !context.settingsActive && !context.detailActive && !guideActive

        case .overlayChrome:
            return true

        case .playbackChrome:
            return context.fullScreenPlaybackActive || trailerExclusiveActive

        case .alertMotion:
            return true
        }
    }

    var diagnosticSummary: String {
        "scene=\(context.sceneActive ? "active" : "inactive") search=\(context.globalSearchActive) detail=\(context.detailActive) sourceSearch=\(sourceSearchActive) sourceOpening=\(sourceOpeningActive) trailer=\(trailerExclusiveActive) playback=\(context.fullScreenPlaybackActive) guide=\(guideActive) frame={\(frameRuntime.diagnosticSummary)}"
    }

    private func runtimeLane(for feature: Feature) -> UnityFrameRuntime.Lane {
        switch feature {
        case .dynamicWallpaper, .catalogPulse, .catalogPreview, .tickerMotion:
            return .ambientMotion
        case .catalogFocusArrival, .catalogRowMotion, .liveTVMotion, .guideMotion, .sportsMotion:
            return .navigationGeometry
        case .detailTransition, .detailConnector, .sourceIntelligenceMotion:
            return .transitionGeometry
        case .overlayChrome:
            return .overlayChrome
        case .playbackChrome:
            return .playbackChrome
        case .alertMotion:
            return .alerts
        }
    }

    /// Some compatibility-only context (Search/Settings/Details/Guide) is intentionally not
    /// stored by the frame runtime. Publish one facade revision when only that context moved.
    private func bumpIfRuntimeDidNotPublish() {
        revision &+= 1
        #if DEBUG
        print("[UNITY Animation] revision=\(revision) \(diagnosticSummary)")
        #endif
    }
}
