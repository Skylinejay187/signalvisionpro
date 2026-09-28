import Foundation

/// Coordinates lightweight preview players with full-screen playback.
/// Preview surfaces register a release closure here so movies, trailers, and Live TV
/// can claim the decoder/render path only after auxiliary players have been dismantled.
final class AuxiliaryVideoPlaybackCoordinator {
    static let shared = AuxiliaryVideoPlaybackCoordinator()

    private let lock = NSLock()
    private var releaseHandlers: [UUID: () -> Void] = [:]
    private var transientSurfaceIDs: Set<UUID> = []
    private var exclusivePlaybackIDs: Set<UUID> = []
    private var lastActivityAt: Date = .distantPast
    private var auxiliaryPlaybackSuppressedUntil: Date = .distantPast

    private init() {}

    @discardableResult
    func registerReleaseHandler(_ handler: @escaping () -> Void) -> UUID {
        let identifier = UUID()
        lock.lock()
        releaseHandlers[identifier] = handler
        lastActivityAt = Date()
        lock.unlock()
        return identifier
    }

    func unregisterReleaseHandler(_ identifier: UUID?) {
        guard let identifier else { return }
        lock.lock()
        let removed = releaseHandlers.removeValue(forKey: identifier) != nil
        if removed { lastActivityAt = Date() }
        lock.unlock()
    }

    @discardableResult
    func beginTransientSurface() -> UUID {
        let identifier = UUID()
        lock.lock()
        transientSurfaceIDs.insert(identifier)
        lastActivityAt = Date()
        lock.unlock()
        return identifier
    }

    func endTransientSurface(_ identifier: UUID?) {
        guard let identifier else { return }
        lock.lock()
        let removed = transientSurfaceIDs.remove(identifier) != nil
        if removed { lastActivityAt = Date() }
        lock.unlock()
    }

    /// Full trailer / full playback surfaces use an explicit suppression token so a
    /// focused-card or guide preview cannot recreate itself while the primary player is active.
    @discardableResult
    func beginExclusivePlayback(reason: String) -> UUID {
        _ = releaseAll(reason: reason)
        let identifier = UUID()
        lock.lock()
        exclusivePlaybackIDs.insert(identifier)
        let now = Date()
        lastActivityAt = now
        auxiliaryPlaybackSuppressedUntil = now.addingTimeInterval(1.25)
        lock.unlock()
        return identifier
    }

    func endExclusivePlayback(_ identifier: UUID?) {
        guard let identifier else { return }
        lock.lock()
        let removed = exclusivePlaybackIDs.remove(identifier) != nil
        if removed {
            let now = Date()
            lastActivityAt = now
            auxiliaryPlaybackSuppressedUntil = now.addingTimeInterval(0.35)
        }
        lock.unlock()
    }

    /// Releases every registered auxiliary player on the main thread. The returned value
    /// is true when a player is active or was active recently enough to require a short
    /// decoder handoff before full-screen playback is mounted.
    @discardableResult
    func releaseAll(reason: String) -> Bool {
        let work: () -> Bool = { [self] in
            lock.lock()
            let handlers = Array(releaseHandlers.values)
            let hadActiveSurface = !handlers.isEmpty || !transientSurfaceIDs.isEmpty
            let wasRecentlyActive = Date().timeIntervalSince(lastActivityAt) < 1.25
            releaseHandlers.removeAll()
            transientSurfaceIDs.removeAll()
            if hadActiveSurface || wasRecentlyActive {
                let now = Date()
                lastActivityAt = now
                auxiliaryPlaybackSuppressedUntil = now.addingTimeInterval(1.25)
            }
            lock.unlock()

            handlers.forEach { $0() }
            if hadActiveSurface || wasRecentlyActive {
                print("[AuxiliaryVideo] released preview surfaces before \(reason)")
            }
            return hadActiveSurface || wasRecentlyActive
        }

        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }


    func isAuxiliaryPlaybackSuppressed() -> Bool {
        lock.lock()
        let suppressed = !exclusivePlaybackIDs.isEmpty || Date() < auxiliaryPlaybackSuppressedUntil
        lock.unlock()
        return suppressed
    }

    func requiresDecoderHandoffCooldown(window: TimeInterval = 1.25) -> Bool {
        lock.lock()
        let needed = !releaseHandlers.isEmpty
            || !transientSurfaceIDs.isEmpty
            || !exclusivePlaybackIDs.isEmpty
            || Date().timeIntervalSince(lastActivityAt) < window
        lock.unlock()
        return needed
    }
}
