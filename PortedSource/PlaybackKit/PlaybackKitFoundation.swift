import Foundation
import Combine
import SwiftUI
import UIKit

// Phase 1 architectural boundary for all non-Live-TV playback.
// Phase 2 adds a separate throttled overlay publication lane without changing player ownership.
// Phase 3 moves clock ownership into each playback session while preserving the existing KSPlayer callback path.
// Phase 4 adds a session-owned presentation lifecycle lane; it mirrors UI events without controlling KSPlayer or SwiftUI.
// Phase 5 adds passive session-owned render-host lifecycle metadata.
// Phase 6 registers the existing KSPlayer container weakly with the session render host; it never reparents or mutates the view.
// Phase 7 adds session-scoped registration leases and ordered activation/suspension guards without changing the render hierarchy.
// Phase 8 adds one persistent, session-owned UIKit host foundation.
// Phase 9 mounts the existing KSPlayer container beneath that host while SwiftUI retains a stable outer anchor.
// Phase 10 makes the active session the sole teardown owner; Phase 11 gates redundant SwiftUI updates.
// Phase 12 extracts the complete KSPlayer/FFmpeg surface tree and decode policy into PlaybackKit.
enum PlaybackKind: String, Equatable {
    case movie
    case episode
    case trailer
    case vod
}

struct PlaybackRequest: Equatable {
    let id: UUID
    let url: URL
    let title: String
    let kind: PlaybackKind
    let startTime: TimeInterval

    init(id: UUID = UUID(), url: URL, title: String, kind: PlaybackKind, startTime: TimeInterval = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.kind = kind
        self.startTime = max(0, startTime)
    }
}

enum PlaybackSessionState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case stopped
    case failed(String)
}

struct PlaybackSnapshot: Equatable {
    let sessionID: UUID?
    let elapsed: TimeInterval
    let duration: TimeInterval
    let remaining: TimeInterval
    let progress: Double
    let isPlaying: Bool
    let isBuffering: Bool

    static let idle = PlaybackSnapshot(
        sessionID: nil,
        elapsed: 0,
        duration: 0,
        remaining: 0,
        progress: 0,
        isPlaying: false,
        isBuffering: false
    )
}

@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    private var sessionID: UUID?

    func attach(sessionID: UUID, startTime: TimeInterval) {
        self.sessionID = sessionID
        publish(elapsed: startTime, duration: 0, isPlaying: false, isBuffering: true)
    }

    func ingest(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool, isBuffering: Bool = false) {
        guard sessionID != nil, elapsed.isFinite, duration.isFinite else { return }
        publish(elapsed: elapsed, duration: duration, isPlaying: isPlaying, isBuffering: isBuffering)
    }

    func setPlaying(_ isPlaying: Bool) {
        let current = snapshot
        publish(elapsed: current.elapsed, duration: current.duration, isPlaying: isPlaying, isBuffering: current.isBuffering)
    }

    func setBuffering(_ isBuffering: Bool) {
        let current = snapshot
        publish(elapsed: current.elapsed, duration: current.duration, isPlaying: current.isPlaying, isBuffering: isBuffering)
    }

    func seek(to seconds: TimeInterval) {
        guard sessionID != nil, seconds.isFinite else { return }
        let current = snapshot
        publish(elapsed: max(0, seconds), duration: current.duration, isPlaying: current.isPlaying, isBuffering: current.isBuffering)
    }

    func reset() {
        sessionID = nil
        if snapshot != .idle { snapshot = .idle }
    }

    private func publish(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool, isBuffering: Bool) {
        let safeDuration = max(0, duration)
        let safeElapsed = max(0, safeDuration > 0 ? min(elapsed, safeDuration) : elapsed)
        let next = PlaybackSnapshot(
            sessionID: sessionID,
            elapsed: safeElapsed,
            duration: safeDuration,
            remaining: max(0, safeDuration - safeElapsed),
            progress: safeDuration > 0 ? min(1, max(0, safeElapsed / safeDuration)) : 0,
            isPlaying: isPlaying,
            isBuffering: isBuffering
        )
        if next != snapshot { snapshot = next }
    }
}

@MainActor
final class PlaybackSnapshotPublisher: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    private var cancellable: AnyCancellable?
    private weak var clock: PlaybackClock?
    private var publishingEnabled = true

    func bind(to clock: PlaybackClock?) {
        cancellable?.cancel()
        cancellable = nil
        self.clock = clock

        guard let clock else {
            if snapshot != .idle { snapshot = .idle }
            return
        }

        guard publishingEnabled else { return }
        subscribe(to: clock)
    }

    func setPublishingEnabled(_ enabled: Bool) {
        guard publishingEnabled != enabled else { return }
        publishingEnabled = enabled
        cancellable?.cancel()
        cancellable = nil
        guard enabled, let clock else { return }
        subscribe(to: clock)
    }

    private func subscribe(to clock: PlaybackClock) {
        snapshot = clock.snapshot
        cancellable = clock.$snapshot
            .removeDuplicates()
            .sink { [weak self] value in self?.snapshot = value }
    }
}



enum PlaybackPresentationPhase: Equatable {
    case preparing
    case presented
    case dismissing
    case completed
    case failed(String)
}

struct PlaybackPresentationSnapshot: Equatable {
    let sessionID: UUID?
    let phase: PlaybackPresentationPhase
    let overlayVisible: Bool
    let isLoading: Bool
    let firstFrameReady: Bool

    static let idle = PlaybackPresentationSnapshot(
        sessionID: nil,
        phase: .completed,
        overlayVisible: false,
        isLoading: false,
        firstFrameReady: false
    )
}

@MainActor
final class PlaybackPresentationCoordinator: ObservableObject {
    @Published private(set) var snapshot: PlaybackPresentationSnapshot

    private let sessionID: UUID
    private var isTerminal = false

    init(sessionID: UUID) {
        self.sessionID = sessionID
        self.snapshot = PlaybackPresentationSnapshot(
            sessionID: sessionID,
            phase: .preparing,
            overlayVisible: true,
            isLoading: true,
            firstFrameReady: false
        )
    }

    func setOverlayVisible(_ visible: Bool) {
        mutate(overlayVisible: visible)
    }

    func setLoading(_ loading: Bool) {
        mutate(isLoading: loading)
    }

    func setFirstFrameReady(_ ready: Bool) {
        guard !isTerminal else { return }
        let nextPhase: PlaybackPresentationPhase = ready ? .presented : snapshot.phase
        mutate(phase: nextPhase, firstFrameReady: ready)
    }

    func beginDismissal() {
        guard !isTerminal else { return }
        mutate(phase: .dismissing)
    }

    func complete() {
        guard !isTerminal else { return }
        isTerminal = true
        mutate(phase: .completed, overlayVisible: false, isLoading: false)
    }

    func fail(_ message: String) {
        guard !isTerminal else { return }
        isTerminal = true
        mutate(phase: .failed(message), isLoading: false)
    }

    private func mutate(
        phase: PlaybackPresentationPhase? = nil,
        overlayVisible: Bool? = nil,
        isLoading: Bool? = nil,
        firstFrameReady: Bool? = nil
    ) {
        let next = PlaybackPresentationSnapshot(
            sessionID: sessionID,
            phase: phase ?? snapshot.phase,
            overlayVisible: overlayVisible ?? snapshot.overlayVisible,
            isLoading: isLoading ?? snapshot.isLoading,
            firstFrameReady: firstFrameReady ?? snapshot.firstFrameReady
        )
        if next != snapshot { snapshot = next }
    }
}

enum PlaybackPersistentHostPhase: Equatable {
    case idle
    case prepared
    case suspended
    case released
}

/// Persistent UIKit render host created once per playback session.
/// Phase 9 allows it to adopt the already-created KSPlayer container without recreating the player,
/// decoder, render view, or layer tree.
@MainActor
final class PlaybackPersistentRenderHostView: UIView {
    let sessionID: UUID
    private(set) var phase: PlaybackPersistentHostPhase = .idle

    init(sessionID: UUID) {
        self.sessionID = sessionID
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = false
        clipsToBounds = true
        backgroundColor = .black
        accessibilityIdentifier = "PlaybackKit.PersistentRenderHost.\(sessionID.uuidString)"
        prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare() {
        guard phase == .idle else { return }
        phase = .prepared
    }

    func suspendHost() {
        guard phase == .prepared else { return }
        phase = .suspended
    }

    func resumeHost() {
        guard phase == .suspended else { return }
        phase = .prepared
    }

    func mount(surface: UIView) {
        guard phase != .released else { return }
        if surface.superview !== self {
            surface.removeFromSuperview()
            addSubview(surface)
        }
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if phase == .suspended { phase = .prepared }
    }

    func unmount(surface: UIView, returningTo anchor: UIView?) {
        guard surface.superview === self else { return }
        surface.removeFromSuperview()
        guard let anchor else { return }
        anchor.addSubview(surface)
        surface.frame = anchor.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func releaseHost() {
        guard phase != .released else { return }
        phase = .released
        removeFromSuperview()
    }
}

enum PlaybackRenderHostPhase: Equatable {
    case detached
    case registered
    case activating
    case active
    case suspending
    case suspended
    case destroyed
}

struct PlaybackRenderSurfaceRegistration: Equatable {
    let surfaceID: UUID
    let sessionID: UUID?
}

/// Session-retained teardown boundary implemented by the existing KSPlayer coordinator.
/// SwiftUI may request dismantling, but an active PlaybackSession remains the sole authority
/// that can stop the player and release its render hierarchy.
@MainActor
protocol PlaybackRenderSurfaceLifecycleOwner: AnyObject {
    func playbackKitStopAndReleaseSurface()
}

struct PlaybackRenderHostSnapshot: Equatable {
    let sessionID: UUID
    let phase: PlaybackRenderHostPhase
    let hasRegisteredSurface: Bool
    let surfaceID: UUID?
}

/// Phase 7 session-scoped surface lifecycle boundary.
///
/// The host keeps only a weak reference to the existing KSPlayer container. It validates every
/// lifecycle operation against a registration lease, but never reparents, resizes, hides, or
/// otherwise mutates the view or its layer hierarchy.
@MainActor
final class PlaybackRenderHost: ObservableObject {
    @Published private(set) var snapshot: PlaybackRenderHostSnapshot

    private let sessionID: UUID
    let persistentHostView: PlaybackPersistentRenderHostView
    // Phase 10: these references are intentionally strong for the active session lifetime.
    // SwiftUI can invalidate its representable without deallocating or stopping the player tree.
    private var registeredSurface: UIView?
    private var surfaceAnchor: UIView?
    private var lifecycleOwner: PlaybackRenderSurfaceLifecycleOwner?
    private var registeredSurfaceID: UUID?

    init(sessionID: UUID) {
        self.sessionID = sessionID
        self.persistentHostView = PlaybackPersistentRenderHostView(sessionID: sessionID)
        self.snapshot = PlaybackRenderHostSnapshot(
            sessionID: sessionID,
            phase: .detached,
            hasRegisteredSurface: false,
            surfaceID: nil
        )
    }

    @discardableResult
    func register(
        surface: UIView,
        surfaceID: UUID,
        lifecycleOwner: PlaybackRenderSurfaceLifecycleOwner?
    ) -> PlaybackRenderSurfaceRegistration? {
        guard snapshot.phase != .destroyed else { return nil }
        registeredSurface = surface
        surfaceAnchor = surface.superview
        self.lifecycleOwner = lifecycleOwner
        registeredSurfaceID = surfaceID
        mountRegisteredSurfaceIfPossible()
        publish(phase: .registered)
        return PlaybackRenderSurfaceRegistration(surfaceID: surfaceID, sessionID: sessionID)
    }

    func unregister(surface: UIView, registration: PlaybackRenderSurfaceRegistration) {
        guard registration.sessionID == sessionID,
              registration.surfaceID == registeredSurfaceID,
              registeredSurface === surface else { return }
        orderedSuspendAndDetach(registration: registration)
        unmountRegisteredSurface()
        lifecycleOwner?.playbackKitStopAndReleaseSurface()
        lifecycleOwner = nil
        registeredSurface = nil
        surfaceAnchor = nil
        registeredSurfaceID = nil
        publish(phase: .detached)
    }

    func attach(registration: PlaybackRenderSurfaceRegistration) {
        guard registration.sessionID == sessionID,
              registration.surfaceID == registeredSurfaceID,
              registeredSurface != nil,
              snapshot.phase != .destroyed else { return }
        mountRegisteredSurfaceIfPossible()
        if snapshot.phase == .detached { publish(phase: .registered) }
    }

    func activate(registration: PlaybackRenderSurfaceRegistration) {
        guard registration.sessionID == sessionID,
              registration.surfaceID == registeredSurfaceID,
              registeredSurface != nil,
              snapshot.phase != .destroyed else { return }
        guard snapshot.phase == .registered || snapshot.phase == .suspended else { return }
        mountRegisteredSurfaceIfPossible()
        persistentHostView.resumeHost()
        publish(phase: .activating)
        publish(phase: .active)
    }

    func suspend(registration: PlaybackRenderSurfaceRegistration) {
        guard registration.sessionID == sessionID,
              registration.surfaceID == registeredSurfaceID,
              registeredSurface != nil,
              snapshot.phase == .active else { return }
        publish(phase: .suspending)
        publish(phase: .suspended)
    }

    func orderedSuspendAndDetach(registration: PlaybackRenderSurfaceRegistration?) {
        guard snapshot.phase != .destroyed else { return }
        if let registration {
            guard registration.sessionID == sessionID,
                  registration.surfaceID == registeredSurfaceID else { return }
        }
        if snapshot.phase == .active {
            publish(phase: .suspending)
            persistentHostView.suspendHost()
            publish(phase: .suspended)
        }
        if snapshot.phase != .detached { publish(phase: .detached) }
    }

    func releaseSurfaceForEngineHandoff() {
        guard snapshot.phase != .destroyed else { return }
        orderedSuspendAndDetach(registration: nil)
        // vBRDC267: an in-session engine handoff must stop the outgoing KSPlayer
        // decoder/audio owner immediately without destroying the PlaybackSession itself.
        // Previously the active session deliberately retained KSPlayer across SwiftUI
        // dismantle, so KS -> Aether could leave the old KS audio graph alive underneath
        // the new Aether surface. Keep the persistent host/session reusable, but release
        // this exact surface lease before the new engine mounts.
        lifecycleOwner?.playbackKitStopAndReleaseSurface()
        lifecycleOwner = nil
        unmountRegisteredSurface()
        registeredSurface = nil
        surfaceAnchor = nil
        registeredSurfaceID = nil
        publish(phase: .detached)
    }

    func destroy() {
        guard snapshot.phase != .destroyed else { return }
        releaseSurfaceForEngineHandoff()
        persistentHostView.releaseHost()
        publish(phase: .destroyed)
    }

    func mountForTheater(in anchor: UIView) {
        guard snapshot.phase != .destroyed, let surface = registeredSurface else { return }
        if persistentHostView.superview !== anchor {
            persistentHostView.removeFromSuperview()
            anchor.addSubview(persistentHostView)
        }
        persistentHostView.frame = anchor.bounds
        persistentHostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        persistentHostView.mount(surface: surface)
        persistentHostView.resumeHost()
        if snapshot.phase != .active { publish(phase: .active) }
    }

    func restoreOriginalAnchor() {
        guard snapshot.phase != .destroyed else { return }
        mountRegisteredSurfaceIfPossible()
    }

    private func mountRegisteredSurfaceIfPossible() {
        guard let surface = registeredSurface, let anchor = surfaceAnchor else { return }
        if persistentHostView.superview !== anchor {
            persistentHostView.removeFromSuperview()
            anchor.addSubview(persistentHostView)
        }
        persistentHostView.frame = anchor.bounds
        persistentHostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        persistentHostView.mount(surface: surface)
    }

    private func unmountRegisteredSurface() {
        guard let surface = registeredSurface else { return }
        persistentHostView.unmount(surface: surface, returningTo: surfaceAnchor)
        persistentHostView.removeFromSuperview()
    }

    private func publish(phase: PlaybackRenderHostPhase) {
        let next = PlaybackRenderHostSnapshot(
            sessionID: sessionID,
            phase: phase,
            hasRegisteredSurface: registeredSurface != nil,
            surfaceID: registeredSurfaceID
        )
        if next != snapshot { snapshot = next }
    }
}

@MainActor
final class PlaybackSession: ObservableObject, Identifiable {
    let id: UUID
    let request: PlaybackRequest
    let clock: PlaybackClock
    let presentation: PlaybackPresentationCoordinator
    let renderHost: PlaybackRenderHost
    @Published private(set) var state: PlaybackSessionState = .preparing

    init(request: PlaybackRequest) {
        self.id = request.id
        self.request = request
        self.clock = PlaybackClock()
        self.presentation = PlaybackPresentationCoordinator(sessionID: request.id)
        self.renderHost = PlaybackRenderHost(sessionID: request.id)
        self.clock.attach(sessionID: request.id, startTime: request.startTime)
    }

    func markPlaying() { state = .playing }
    func markPaused() { state = .paused }
    func markStopped() { state = .stopped }
    func markFailed(_ message: String) { state = .failed(message) }
}

@MainActor
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    @Published private(set) var activeSession: PlaybackSession?
    let snapshots = PlaybackSnapshotPublisher()

    // Weak handoff only. This never owns or changes the KSPlayer container hierarchy.
    private var renderSurfaceCandidate: UIView?
    private weak var renderSurfaceLifecycleOwner: PlaybackRenderSurfaceLifecycleOwner?
    private var renderSurfaceCandidateID: UUID?
    // v1054: the pending UIKit surface belongs to one explicit playback launch.
    // Never adopt an unscoped surface left behind by a previous VOD screen.
    private var renderSurfaceCandidateSessionID: UUID?
    private var activeRenderRegistration: PlaybackRenderSurfaceRegistration?

    private init() {}

    @discardableResult
    func play(_ request: PlaybackRequest) -> PlaybackSession {
        // Preserve only a surface that explicitly declared ownership of this request.
        // This prevents link B from temporarily mounting link A's stale KSPlayer view.
        stopActiveSession(preservingRenderCandidateFor: request.id)
        let session = PlaybackSession(request: request)
        activeSession = session
        if renderSurfaceCandidateSessionID == request.id,
           let renderSurfaceCandidate,
           let renderSurfaceCandidateID {
            activeRenderRegistration = session.renderHost.register(
                surface: renderSurfaceCandidate,
                surfaceID: renderSurfaceCandidateID,
                lifecycleOwner: renderSurfaceLifecycleOwner
            )
        }
        snapshots.bind(to: session.clock)
        return session
    }

    func pause() {
        activeSession?.markPaused()
        activeSession?.clock.setPlaying(false)
    }

    func resume() {
        activeSession?.markPlaying()
        activeSession?.clock.setPlaying(true)
    }

    func ingestClock(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard activeSession != nil else { return }
        if isPlaying { activeSession?.markPlaying() } else { activeSession?.markPaused() }
        activeSession?.clock.ingest(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
    }

    /// v1053: KSPlayer surfaces can overlap briefly while one VOD screen dismisses and
    /// another opens. A late callback from the departing surface must never mutate the
    /// new session's clock. Every full-screen VOD callback is therefore scoped to the
    /// session that created it.
    func ingestClock(
        sessionID: UUID,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        guard activeSession?.id == sessionID else { return }
        ingestClock(elapsed: elapsed, duration: duration, isPlaying: isPlaying)
    }

    func ownsSession(_ sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activeSession?.id == sessionID
    }

    func seek(to seconds: TimeInterval) {
        guard activeSession != nil else { return }
        activeSession?.clock.seek(to: seconds)
    }

    func setBuffering(_ buffering: Bool, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        activeSession?.clock.setBuffering(buffering)
    }

    func setOverlayVisible(_ visible: Bool) {
        activeSession?.presentation.setOverlayVisible(visible)
        snapshots.setPublishingEnabled(visible)
    }

    func setOverlayVisible(_ visible: Bool, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        setOverlayVisible(visible)
    }

    func setLoading(_ loading: Bool) {
        activeSession?.presentation.setLoading(loading)
    }

    func setLoading(_ loading: Bool, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        setLoading(loading)
    }

    func setFirstFrameReady(_ ready: Bool) {
        activeSession?.presentation.setFirstFrameReady(ready)
    }

    func setFirstFrameReady(_ ready: Bool, sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        setFirstFrameReady(ready)
    }

    func beginPresentationDismissal() {
        activeSession?.presentation.beginDismissal()
    }

    func beginPresentationDismissal(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        beginPresentationDismissal()
    }

    @discardableResult
    func registerRenderSurfaceCandidate(
        _ surface: UIView,
        surfaceID: UUID,
        sessionID: UUID,
        lifecycleOwner: PlaybackRenderSurfaceLifecycleOwner?
    ) -> PlaybackRenderSurfaceRegistration {
        renderSurfaceCandidate = surface
        renderSurfaceLifecycleOwner = lifecycleOwner
        renderSurfaceCandidateID = surfaceID
        renderSurfaceCandidateSessionID = sessionID
        if let session = activeSession,
           session.id == sessionID,
           let registration = session.renderHost.register(
               surface: surface,
               surfaceID: surfaceID,
               lifecycleOwner: lifecycleOwner
           ) {
            activeRenderRegistration = registration
            // vBRDC267: an engine switch can create a new KS surface after the VOD
            // screen's one-time onAppear lifecycle markers already ran. Activate the
            // newly registered surface here as well so the reused PlaybackSession host
            // cannot remain suspended after KS -> Aether -> KS.
            session.renderHost.attach(registration: registration)
            session.renderHost.activate(registration: registration)
            return registration
        }
        // Return the requested ownership even when the surface arrived before onAppear.
        // play(_:) will adopt it only if the request carries this exact session UUID.
        return PlaybackRenderSurfaceRegistration(surfaceID: surfaceID, sessionID: sessionID)
    }

    func unregisterRenderSurfaceCandidate(_ surface: UIView, registration: PlaybackRenderSurfaceRegistration) {
        let resolvedRegistration: PlaybackRenderSurfaceRegistration
        if registration.sessionID == nil,
           let activeRenderRegistration,
           activeRenderRegistration.surfaceID == registration.surfaceID {
            resolvedRegistration = activeRenderRegistration
        } else {
            resolvedRegistration = registration
        }
        if resolvedRegistration.sessionID == activeSession?.id {
            activeSession?.renderHost.unregister(surface: surface, registration: resolvedRegistration)
        }
        if renderSurfaceCandidate === surface,
           renderSurfaceCandidateID == registration.surfaceID,
           renderSurfaceCandidateSessionID == registration.sessionID {
            renderSurfaceCandidate = nil
            renderSurfaceLifecycleOwner = nil
            renderSurfaceCandidateID = nil
            renderSurfaceCandidateSessionID = nil
        }
        if activeRenderRegistration?.surfaceID == registration.surfaceID { activeRenderRegistration = nil }
    }

    func sessionOwnsRenderSurface(_ registration: PlaybackRenderSurfaceRegistration?) -> Bool {
        guard let registration,
              let session = activeSession,
              registration.sessionID == session.id,
              activeRenderRegistration == registration else { return false }
        return session.renderHost.snapshot.hasRegisteredSurface
    }

    func attachRenderHost() {
        guard let registration = activeRenderRegistration else { return }
        activeSession?.renderHost.attach(registration: registration)
    }

    func attachRenderHost(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        attachRenderHost()
    }

    func activateRenderHost() {
        guard let registration = activeRenderRegistration else { return }
        activeSession?.renderHost.activate(registration: registration)
    }

    func activateRenderHost(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        activateRenderHost()
    }

    func suspendRenderHost() {
        guard let registration = activeRenderRegistration else { return }
        activeSession?.renderHost.suspend(registration: registration)
    }

    func suspendRenderHost(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        suspendRenderHost()
    }

    func detachRenderHost() {
        activeSession?.renderHost.orderedSuspendAndDetach(registration: activeRenderRegistration)
    }

    func detachRenderHost(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        detachRenderHost()
    }

    // Build 38: move the already-running PlaybackKit render surface to the immersive
    // theater attachment without stopping/recreating its decoder or audio graph.
    func mountRenderHost(in anchor: UIView, sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID else { return }
        session.renderHost.mountForTheater(in: anchor)
    }

    func restoreRenderHostToOriginalAnchor(sessionID: UUID?) {
        guard let session = activeSession else { return }
        if let sessionID, session.id != sessionID { return }
        session.renderHost.restoreOriginalAnchor()
    }

    func hasRegisteredRenderSurface(sessionID: UUID) -> Bool {
        guard let session = activeSession, session.id == sessionID else { return false }
        return session.renderHost.snapshot.hasRegisteredSurface
    }

    /// vBRDC267: release only the currently registered UIKit/KSPlayer surface while
    /// preserving the session clock/presentation identity for an Aether <-> KS handoff.
    func releaseRenderSurfaceForEngineHandoff(sessionID: UUID) {
        guard let session = activeSession, session.id == sessionID else { return }
        session.renderHost.releaseSurfaceForEngineHandoff()
        activeRenderRegistration = nil
        if renderSurfaceCandidateSessionID == sessionID {
            renderSurfaceCandidate = nil
            renderSurfaceLifecycleOwner = nil
            renderSurfaceCandidateID = nil
            renderSurfaceCandidateSessionID = nil
        }
    }

    func failPresentation(_ message: String) {
        activeSession?.presentation.fail(message)
    }

    func stop() {
        stopActiveSession(preservingRenderCandidateFor: nil)
    }

    private func stopActiveSession(preservingRenderCandidateFor preservedSessionID: UUID?) {
        let stoppedSessionID = activeSession?.id
        activeSession?.markStopped()
        activeSession?.presentation.complete()
        activeSession?.renderHost.orderedSuspendAndDetach(registration: activeRenderRegistration)
        activeSession?.renderHost.destroy()
        activeRenderRegistration = nil
        activeSession?.clock.reset()
        activeSession = nil
        snapshots.setPublishingEnabled(true)
        snapshots.bind(to: nil)

        // Retain only the pending surface for the incoming session. Everything belonging
        // to the stopped session is released so it cannot be adopted by the next link.
        if renderSurfaceCandidateSessionID != preservedSessionID {
            renderSurfaceCandidate = nil
            renderSurfaceLifecycleOwner = nil
            renderSurfaceCandidateID = nil
            renderSurfaceCandidateSessionID = nil
        } else if stoppedSessionID == preservedSessionID {
            // Defensive: never preserve the surface of the session we just stopped.
            renderSurfaceCandidate = nil
            renderSurfaceLifecycleOwner = nil
            renderSurfaceCandidateID = nil
            renderSurfaceCandidateSessionID = nil
        }
    }

    /// Stops only the session owned by the caller. A delayed onDisappear from an old
    /// VOD screen must not tear down a newer source that has already started playing.
    func stop(sessionID: UUID) {
        guard activeSession?.id == sessionID else { return }
        stopActiveSession(preservingRenderCandidateFor: nil)
    }
}

@MainActor
final class OverlayBridge: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot = .idle

    private var cancellable: AnyCancellable?
    private var overlayVisible = true
    private var lastPublicationDate = Date.distantPast
    private var pendingSnapshot: PlaybackSnapshot = .idle

    // The bridge is the only PlaybackKit object the SwiftUI overlay observes.
    // Raw player/clock callbacks never publish directly into the overlay tree.
    func connect(to publisher: PlaybackSnapshotPublisher) {
        guard cancellable == nil else { return }
        cancellable = publisher.$snapshot
            .removeDuplicates()
            .sink { [weak self] value in
                self?.receive(value)
            }
    }

    func setOverlayVisible(_ visible: Bool) {
        guard overlayVisible != visible else { return }
        overlayVisible = visible
        publishPending(force: true)
    }

    func disconnect() {
        cancellable?.cancel()
        cancellable = nil
        pendingSnapshot = .idle
        lastPublicationDate = .distantPast
        if snapshot != .idle { snapshot = .idle }
    }

    private func receive(_ value: PlaybackSnapshot) {
        pendingSnapshot = value

        let stateChanged = value.sessionID != snapshot.sessionID
            || value.isPlaying != snapshot.isPlaying
            || value.isBuffering != snapshot.isBuffering
            || (snapshot.duration <= 1 && value.duration > 1)

        // v963 VOD Quiet Mode: while the overlay is hidden, retain only the latest
        // snapshot in memory. Do not publish any playback tick into SwiftUI. State is
        // flushed immediately when controls become visible again.
        guard overlayVisible else { return }
        // vBRDC076 Playback Priority: the visible overlay does not need a 5 Hz bridge.
        // KSPlayer's authoritative clock is already coalesced; cap normal SwiftUI snapshot
        // publication at 1 Hz so video presentation owns the main run loop/compositor.
        let intervalElapsed = Date().timeIntervalSince(lastPublicationDate) >= 1.00
        if stateChanged || intervalElapsed {
            publishPending(force: stateChanged)
        }
    }

    private func publishPending(force: Bool) {
        guard force || pendingSnapshot != snapshot else { return }
        guard pendingSnapshot != snapshot else { return }
        snapshot = pendingSnapshot
        lastPublicationDate = Date()
    }
}

@MainActor final class PlaybackAudioManager: ObservableObject {}
@MainActor final class PlaybackSubtitleManager: ObservableObject {}

struct PlaybackConfiguration: Equatable {
    let hardwareDecode: Bool
    let asynchronousDecompression: Bool
    let decoderThreadCount: String
    let decoderThreadType: String?

    // Phase 12: PlaybackKit is the only KSPlayer decode-policy authority.
    // Hardware decode stays enabled; unsupported formats may still use KSPlayer/FFmpeg's
    // internal compatibility fallback, but there is no user-facing Force Off path.
    static let vod = PlaybackConfiguration(
        hardwareDecode: true,
        asynchronousDecompression: true,
        decoderThreadCount: "auto",
        decoderThreadType: "slice"
    )

    // Preserve the existing Live TV KSPlayer behavior while centralizing policy ownership.
    static let live = PlaybackConfiguration(
        hardwareDecode: true,
        asynchronousDecompression: true,
        decoderThreadCount: "auto",
        decoderThreadType: nil
    )
}

enum PlaybackDiagnostics {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "vodPlaybackDiagnosticsEnabled") }
}

#if canImport(KSPlayer)
struct PlaybackKitKSPlayerHost: View {
    let url: URL
    let shouldPlay: Bool
    var playAssertionSerial: Int = 0
    let seekSerial: Int
    let seekSeconds: Double
    let seekIsAbsolute: Bool
    let reloadToken: Int
    let startTimeSeconds: Double
    let externalAudioURL: URL?
    let externalAudioOffsetMS: Int
    var externalAudioTrackIndex: Int? = nil
    var externalAudioHTTPHeaders: [String: String] = [:]
    var muteAudio: Bool = false
    var contentMode: UIView.ContentMode = .scaleAspectFit
    var isLiveStream: Bool = false
    var playbackSessionID: UUID? = nil
    var routeHint: String = ""
    // vBRDC089: request headers resolved by an In-S/Stremio/FebBox provider travel
    // with the playback request instead of being discarded at the engine boundary.
    var httpHeaders: [String: String] = [:]
    var enableDisplayMatch: Bool = false
    var displayMatchIsLive: Bool = false
    var selectedAudioTrackIndex: Int? = nil
    var selectedSubtitleTrackIndex: Int? = nil
    var selectedExternalSubtitleURL: URL? = nil
    var subtitleDelayMS: Int = 0
    var trackSelectionSerial: Int = 0
    var audioGainDB: Double = 0
    var onPlaybackTimeUpdate: ((Double, Double) -> Void)? = nil
    var onBufferUpdate: ((Double, Double) -> Void)? = nil
    var onTracksDiscovered: (([RealMediaTrackOption], [RealMediaTrackOption]) -> Void)? = nil
    var onPlaybackFailure: ((String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onExternalAudioReady: (() -> Void)? = nil
    var onExternalAudioFailure: ((String) -> Void)? = nil
    // vBRDC043: client-side Skip Intro receives only local playback-engine metadata
    // and tiny irreversible audio fingerprints. No media is sent to the backend.
    var onChaptersDiscovered: (([PlaybackChapterMarker]) -> Void)? = nil
    var onAudioFingerprintSample: ((PlaybackAudioFingerprintSample) -> Void)? = nil

    var body: some View {
        KSPlayerVideoSurface(
            url: url,
            shouldPlay: shouldPlay,
            playAssertionSerial: playAssertionSerial,
            seekSerial: seekSerial,
            seekSeconds: seekSeconds,
            seekIsAbsolute: seekIsAbsolute,
            reloadToken: reloadToken,
            startTimeSeconds: startTimeSeconds,
            externalAudioURL: externalAudioURL,
            externalAudioOffsetMS: externalAudioOffsetMS,
            externalAudioTrackIndex: externalAudioTrackIndex,
            externalAudioHTTPHeaders: externalAudioHTTPHeaders,
            muteAudio: muteAudio,
            contentMode: contentMode,
            isLiveStream: isLiveStream,
            playbackSessionID: playbackSessionID,
            routeHint: routeHint,
            httpHeaders: httpHeaders,
            enableDisplayMatch: enableDisplayMatch,
            displayMatchIsLive: displayMatchIsLive,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            selectedExternalSubtitleURL: selectedExternalSubtitleURL,
            subtitleDelayMS: subtitleDelayMS,
            trackSelectionSerial: trackSelectionSerial,
            audioGainDB: audioGainDB,
            onPlaybackTimeUpdate: onPlaybackTimeUpdate,
            onBufferUpdate: onBufferUpdate,
            onTracksDiscovered: onTracksDiscovered,
            onPlaybackFailure: onPlaybackFailure,
            onPlaybackEnded: onPlaybackEnded,
            onExternalAudioReady: onExternalAudioReady,
            onExternalAudioFailure: onExternalAudioFailure,
            onChaptersDiscovered: onChaptersDiscovered,
            onAudioFingerprintSample: onAudioFingerprintSample
        )
    }
}
#endif
