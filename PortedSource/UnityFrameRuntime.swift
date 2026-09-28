import Foundation
import Combine

/// Event-driven revision waiters for the process-wide frame authority.
///
/// vBRDC119: the original `waitUntilPermitted` implementation used a private sleep/poll
/// loop per caller. During a D-pad burst, every deferred artwork/guide/persistence task could
/// wake independently ~35 times per second just to discover that navigation still owned the
/// frame. This hub lets callers sleep until the shared ownership revision actually changes
/// (or their timeout/cancellation fires), eliminating that MainActor wake-up storm.
private final class UnityFrameRevisionWaiterHub {
    private struct Waiter {
        let afterRevision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutWorkItem: DispatchWorkItem?
    }

    private let lock = NSLock()
    private var currentRevision: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]
    // Handles the narrow race where cancellation arrives just before the continuation is
    // registered. Entries are consumed immediately by registration; the bounded cleanup is
    // only a defensive backstop for a task that never reaches its operation closure.
    private var pendingCancellationIDs: Set<UUID> = []

    func revision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentRevision
    }

    func publish(_ revision: UInt64) {
        var continuations: [CheckedContinuation<Bool, Never>] = []
        var timeoutItems: [DispatchWorkItem] = []

        lock.lock()
        currentRevision = revision
        let readyIDs = waiters.compactMap { id, waiter in
            waiter.afterRevision == revision ? nil : id
        }
        continuations.reserveCapacity(readyIDs.count)
        timeoutItems.reserveCapacity(readyIDs.count)
        for id in readyIDs {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            if let item = waiter.timeoutWorkItem { timeoutItems.append(item) }
            continuations.append(waiter.continuation)
        }
        lock.unlock()

        timeoutItems.forEach { $0.cancel() }
        continuations.forEach { $0.resume(returning: true) }
    }

    func waitForChange(after revision: UInt64, timeout: TimeInterval?) async -> Bool {
        if self.revision() != revision { return true }
        if Task.isCancelled { return false }

        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                var immediateResult: Bool?
                var timeoutItemToSchedule: DispatchWorkItem?

                lock.lock()
                if pendingCancellationIDs.remove(id) != nil || Task.isCancelled {
                    immediateResult = false
                } else if currentRevision != revision {
                    immediateResult = true
                } else {
                    let timeoutItem: DispatchWorkItem?
                    if let timeout {
                        let work = DispatchWorkItem { [weak self] in
                            self?.finish(id: id, result: false, rememberMissingCancellation: false)
                        }
                        timeoutItem = work
                        timeoutItemToSchedule = work
                    } else {
                        timeoutItem = nil
                    }
                    waiters[id] = Waiter(
                        afterRevision: revision,
                        continuation: continuation,
                        timeoutWorkItem: timeoutItem
                    )
                }
                lock.unlock()

                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                    return
                }
                if let timeoutItemToSchedule, let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + max(0.001, timeout),
                        execute: timeoutItemToSchedule
                    )
                }
            }
        }, onCancel: { [weak self] in
            self?.finish(id: id, result: false, rememberMissingCancellation: true)
        })
    }

    private func finish(id: UUID, result: Bool, rememberMissingCancellation: Bool) {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeoutItem: DispatchWorkItem?

        lock.lock()
        if let waiter = waiters.removeValue(forKey: id) {
            continuation = waiter.continuation
            timeoutItem = waiter.timeoutWorkItem
        } else if rememberMissingCancellation {
            pendingCancellationIDs.insert(id)
            if pendingCancellationIDs.count > 512 { pendingCancellationIDs.removeAll(keepingCapacity: true) }
        }
        lock.unlock()

        timeoutItem?.cancel()
        continuation?.resume(returning: result)
    }
}

/// vBRDC102 — UNITY Frame Runtime
///
/// One process-wide authority for interactive frame ownership. Existing visual themes,
/// row-motion presets, wallpapers and transitions keep their appearance; this runtime
/// decides *when* supporting work may publish so navigation/transition geometry never
/// competes with artwork decoding, Gracenote/EPG publication, prefetch, persistence or
/// perpetual animation on the same frame.
final class UnityFrameRuntime: ObservableObject {
    static let shared = UnityFrameRuntime()

    enum Lane: String, CaseIterable {
        case navigationGeometry
        case transitionGeometry
        case criticalArtwork
        case playbackArtwork
        case interactiveMetadata
        case liveSchedule
        case backgroundPrefetch
        case persistence
        case ambientMotion
        case recovery
        case overlayChrome
        case playbackChrome
        case alerts
    }

    struct TransitionProfile: Equatable {
        let preflight: TimeInterval
        let visibleDuration: TimeInterval
        let branchSettle: TimeInterval
        let focusBind: TimeInterval
        let focusSettle: TimeInterval
        let ambientTail: TimeInterval
    }

    struct Snapshot: Equatable {
        var sceneActive: Bool = true
        var navigationActive: Bool = false
        var postNavigationRecoveryActive: Bool = false
        var surfaceTransitionActive: Bool = false
        var sourceOpeningActive: Bool = false
        var trailerActive: Bool = false
        var playbackActive: Bool = false
        var navigationSource: String = "none"
        var transitionSource: String = "none"
    }

    @Published private(set) var revision: UInt64 = 0
    private(set) var snapshot = Snapshot()

    private let revisionWaiters = UnityFrameRevisionWaiterHub()
    private var navigationGeneration: UInt64 = 0
    private var navigationSettleWorkItem: DispatchWorkItem?
    private var navigationRecoveryWorkItem: DispatchWorkItem?

    private init() {}

    /// Keeps the existing theme motion untouched while providing one shared transaction
    /// schedule for catalog <-> persistent Live TV root handoffs.
    func catalogTransitionProfile(leavingCatalogForLiveRoot: Bool, enteringCatalogFromLiveRoot: Bool) -> TransitionProfile {
        if enteringCatalogFromLiveRoot {
            // vBRDC124: two 60-Hz render turns of invisible preflight, followed by a
            // natural 270 ms ease-out. Focus/visual pinning must be complete before opacity/
            // translation begins, so the card never grows or bounces during the visible motion.
            return TransitionProfile(
                preflight: 0.034,
                visibleDuration: 0.27,
                branchSettle: 0.285,
                focusBind: 0.0,
                focusSettle: 0.016,
                ambientTail: 0.305
            )
        }
        if leavingCatalogForLiveRoot {
            // vBRDC124: Live TV cannot reclaim real FocusState while any catalog pixel remains visible.
            // The old 120ms handoff occurred inside a 200ms fade and visibly shrank/shifted
            // the focused card before the surface disappeared.
            return TransitionProfile(
                preflight: 0.0,
                visibleDuration: 0.24,
                branchSettle: 0.255,
                focusBind: 0.265,
                focusSettle: 0.016,
                ambientTail: 0.060
            )
        }
        return TransitionProfile(
            preflight: 0.0,
            visibleDuration: 0.26,
            branchSettle: 0.28,
            focusBind: 0.060,
            focusSettle: 0.110,
            ambientTail: 0.100
        )
    }

    /// A repeat-heavy Siri Remote burst is one ownership transaction. Repeated key events
    /// extend the deadline without publishing another ObservableObject revision.
    func registerNavigationActivity(source: String, settleAfter: TimeInterval, recoveryAfter: TimeInterval = 0.085) {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : source
        navigationGeneration &+= 1
        let generation = navigationGeneration

        navigationSettleWorkItem?.cancel()
        navigationRecoveryWorkItem?.cancel()
        navigationRecoveryWorkItem = nil

        let wasNavigationActive = snapshot.navigationActive
        let wasRecovering = snapshot.postNavigationRecoveryActive
        snapshot.navigationSource = normalized
        snapshot.postNavigationRecoveryActive = false
        snapshot.navigationActive = true
        if !wasNavigationActive || wasRecovering { publishRevision() }

        let settle = DispatchWorkItem { [weak self] in
            guard let self, generation == self.navigationGeneration else { return }
            self.navigationSettleWorkItem = nil
            guard self.snapshot.navigationActive else { return }
            self.snapshot.navigationActive = false
            self.snapshot.navigationSource = "none"
            self.snapshot.postNavigationRecoveryActive = true
            self.publishRevision()

            let recovery = DispatchWorkItem { [weak self] in
                guard let self, generation == self.navigationGeneration else { return }
                self.navigationRecoveryWorkItem = nil
                guard self.snapshot.postNavigationRecoveryActive else { return }
                self.snapshot.postNavigationRecoveryActive = false
                self.publishRevision()
            }
            self.navigationRecoveryWorkItem = recovery
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, recoveryAfter), execute: recovery)
        }
        navigationSettleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.10, settleAfter), execute: settle)
    }

    func setSurfaceTransitionActive(_ active: Bool, source: String) {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "surface" : source
        if snapshot.surfaceTransitionActive == active {
            if active { snapshot.transitionSource = normalized }
            return
        }
        snapshot.surfaceTransitionActive = active
        snapshot.transitionSource = active ? normalized : "none"
        publishRevision()
    }

    func synchronizeExclusiveState(sceneActive: Bool, sourceOpeningActive: Bool, trailerActive: Bool, playbackActive: Bool) {
        var changed = false
        if snapshot.sceneActive != sceneActive { snapshot.sceneActive = sceneActive; changed = true }
        if snapshot.sourceOpeningActive != sourceOpeningActive { snapshot.sourceOpeningActive = sourceOpeningActive; changed = true }
        if snapshot.trailerActive != trailerActive { snapshot.trailerActive = trailerActive; changed = true }
        if snapshot.playbackActive != playbackActive { snapshot.playbackActive = playbackActive; changed = true }
        if changed { publishRevision() }
    }

    func permits(_ lane: Lane) -> Bool {
        guard snapshot.sceneActive else {
            return lane == .persistence
        }

        if snapshot.playbackActive {
            switch lane {
            case .playbackChrome, .alerts, .persistence: return true
            case .playbackArtwork: return !snapshot.navigationActive
            default: return false
            }
        }

        if snapshot.trailerActive || snapshot.sourceOpeningActive {
            switch lane {
            case .overlayChrome, .playbackChrome, .alerts, .persistence: return true
            default: return false
            }
        }

        if snapshot.surfaceTransitionActive {
            switch lane {
            case .navigationGeometry, .transitionGeometry, .criticalArtwork, .overlayChrome, .alerts:
                return true
            case .playbackArtwork, .interactiveMetadata, .liveSchedule, .backgroundPrefetch, .persistence, .ambientMotion, .recovery, .playbackChrome:
                return false
            }
        }

        if snapshot.navigationActive {
            switch lane {
            case .navigationGeometry, .transitionGeometry, .overlayChrome, .alerts:
                return true
            case .criticalArtwork, .playbackArtwork, .interactiveMetadata, .liveSchedule, .backgroundPrefetch, .persistence, .ambientMotion, .recovery, .playbackChrome:
                return false
            }
        }

        if snapshot.postNavigationRecoveryActive {
            switch lane {
            case .backgroundPrefetch, .ambientMotion, .recovery:
                return false
            default:
                return true
            }
        }

        return lane != .playbackChrome
    }

    /// Critical visible artwork may complete during a cross-surface transition and during
    /// the short post-navigation recovery tail, but never while geometry is actively moving.
    /// Noncritical publications wait through the complete transaction.
    func shouldDeferVisualPublication(critical: Bool, allowDuringPlayback: Bool = false) -> Bool {
        if !snapshot.sceneActive || snapshot.trailerActive || snapshot.sourceOpeningActive {
            return true
        }
        if snapshot.playbackActive {
            // vBRDC106: only explicit playback-UI artwork may paint while video owns the
            // full-screen session. Even that artwork yields to an active navigation burst.
            return !allowDuringPlayback || snapshot.navigationActive
        }
        if snapshot.navigationActive { return true }
        if critical { return false }
        return snapshot.postNavigationRecoveryActive || snapshot.surfaceTransitionActive
    }

    /// vBRDC124: image owners use the same revision signal as the process-wide frame lanes.
    /// This replaces Live TV's private 35 ms publication poll: once ImageIO has produced an
    /// authoritative bitmap, the task sleeps until visual publication is actually safe and
    /// wakes only when frame ownership changes. Playback Quick Guide artwork may publish
    /// during video, but still yields to active navigation so D-pad geometry wins the frame.
    func waitUntilVisualPublicationPermitted(critical: Bool, allowDuringPlayback: Bool = false) async -> Bool {
        while shouldDeferVisualPublication(critical: critical, allowDuringPlayback: allowDuringPlayback) {
            if Task.isCancelled { return false }
            let observedRevision = revisionWaiters.revision()
            if !shouldDeferVisualPublication(critical: critical, allowDuringPlayback: allowDuringPlayback) { return true }
            let changed = await revisionWaiters.waitForChange(after: observedRevision, timeout: nil)
            if !changed || Task.isCancelled { return false }
        }
        return true
    }

    /// Cancellable courtesy gate used by speculative/rebuild work. vBRDC119 makes the wait
    /// event-driven: callers wake only when ownership actually changes, not on a private
    /// 28ms polling cadence. `poll` is retained for source compatibility with older callers.
    func waitUntilPermitted(_ lane: Lane, maxWait: TimeInterval = 1.50, poll: TimeInterval = 0.028) async -> Bool {
        _ = poll
        if permits(lane) { return true }
        let deadline = Date().addingTimeInterval(max(0.05, maxWait))

        while !permits(lane) {
            if Task.isCancelled { return false }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return permits(lane) }

            let observedRevision = revisionWaiters.revision()
            // Close the race between sampling the revision and registering the waiter.
            if permits(lane) { return true }
            let changed = await revisionWaiters.waitForChange(after: observedRevision, timeout: remaining)
            if Task.isCancelled { return false }
            if !changed { return permits(lane) }
        }
        return true
    }

    /// Authoritative results (already-fetched catalog/provider/guide/sports state) are not
    /// allowed to disappear merely because navigation stayed active longer than a courtesy
    /// timeout. They sleep on the same event-driven revision signal until the lane opens,
    /// unless their owning task is genuinely cancelled/superseded.
    func waitUntilPermittedDurably(_ lane: Lane) async -> Bool {
        while !permits(lane) {
            if Task.isCancelled { return false }
            let observedRevision = revisionWaiters.revision()
            if permits(lane) { return true }
            let changed = await revisionWaiters.waitForChange(after: observedRevision, timeout: nil)
            if !changed || Task.isCancelled { return false }
        }
        return true
    }

    func resetTransientOwnership() {
        navigationGeneration &+= 1
        navigationSettleWorkItem?.cancel()
        navigationSettleWorkItem = nil
        navigationRecoveryWorkItem?.cancel()
        navigationRecoveryWorkItem = nil

        let hadTransient = snapshot.navigationActive
            || snapshot.postNavigationRecoveryActive
            || snapshot.surfaceTransitionActive
            || snapshot.sourceOpeningActive
            || snapshot.trailerActive
        snapshot.navigationActive = false
        snapshot.postNavigationRecoveryActive = false
        snapshot.surfaceTransitionActive = false
        snapshot.sourceOpeningActive = false
        snapshot.trailerActive = false
        snapshot.navigationSource = "none"
        snapshot.transitionSource = "none"
        if hadTransient { publishRevision() }
    }

    var diagnosticSummary: String {
        "scene=\(snapshot.sceneActive ? "active" : "inactive") nav=\(snapshot.navigationActive ? snapshot.navigationSource : "idle") navRecovery=\(snapshot.postNavigationRecoveryActive) transition=\(snapshot.surfaceTransitionActive ? snapshot.transitionSource : "idle") sourceOpening=\(snapshot.sourceOpeningActive) trailer=\(snapshot.trailerActive) playback=\(snapshot.playbackActive)"
    }

    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func publishRevision() {
        revision &+= 1
        revisionWaiters.publish(revision)
        #if DEBUG
        print("[UNITY Frame] revision=\(revision) \(diagnosticSummary)")
        #endif
    }
}
