import Foundation
import Combine

/// vBRDC081 — Code Name: UNITY
///
/// Process-wide surface lifecycle arbitration. Animation ownership was centralized in vBRDC080;
/// this companion coordinator does the same for navigation handoff. An outgoing heavy surface
/// is never allowed to keep publishing expensive work while the incoming focus tree is mounting.
///
/// Policy:
/// - Exit invalidation happens first.
/// - Incoming focus/interactivity gets the next frame budget.
/// - Nonessential watchdog/background work resumes only after the handoff settles.
/// - The coordinator never changes user preferences or playback state.
final class UnitySurfaceLifecycleCoordinator: ObservableObject {
    static let shared = UnitySurfaceLifecycleCoordinator()

    typealias Surface = UnityAppCore.Surface

    enum Phase: String, Equatable {
        case stable
        case handoff
    }

    @Published private(set) var revision: UInt64 = 0
    private(set) var phase: Phase = .stable
    private(set) var activeSurface: Surface = .liveTV
    private(set) var outgoingSurface: Surface? = nil
    private(set) var incomingSurface: Surface? = nil
    private(set) var generation: UInt64 = 0

    private let frameRuntime = UnityFrameRuntime.shared

    private init() {}

    var handoffActive: Bool { phase == .handoff }
    var permitsNonessentialBackgroundWork: Bool { frameRuntime.permits(.backgroundPrefetch) }

    func surface(for tab: AppTab) -> Surface {
        UnityAppCore.shared.surface(for: tab)
    }

    @discardableResult
    func beginTabHandoff(from oldTab: AppTab, to newTab: AppTab, reason: String) -> UInt64 {
        generation &+= 1
        outgoingSurface = surface(for: oldTab)
        incomingSurface = surface(for: newTab)
        phase = .handoff
        frameRuntime.setSurfaceTransitionActive(true, source: reason)
        bump(reason: reason)
        return generation
    }

    func finishTabHandoff(generation expectedGeneration: UInt64, reason: String) {
        guard expectedGeneration == generation else { return }
        if let incomingSurface { activeSurface = incomingSurface }
        outgoingSurface = nil
        incomingSurface = nil
        phase = .stable
        frameRuntime.setSurfaceTransitionActive(false, source: reason)
        bump(reason: reason)
    }

    func cancelHandoff(reason: String) {
        generation &+= 1
        if let incomingSurface { activeSurface = incomingSurface }
        outgoingSurface = nil
        incomingSurface = nil
        phase = .stable
        frameRuntime.setSurfaceTransitionActive(false, source: reason)
        bump(reason: reason)
    }

    private func bump(reason: String) {
        revision &+= 1
        print("[UNITY Lifecycle] revision=\(revision) phase=\(phase.rawValue) active=\(activeSurface.rawValue) outgoing=\(outgoingSurface?.rawValue ?? "none") incoming=\(incomingSurface?.rawValue ?? "none") reason=\(reason)")
    }
}
