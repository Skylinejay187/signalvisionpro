import Foundation

/// Process-wide gate for full-screen on-demand playback.
///
/// Player-essential work and the new-episode alert subsystem intentionally do not
/// register here. Everything else that launches view-owned asynchronous work can
/// register with `VODExclusiveWorkRegistry`, allowing VOD entry to cancel it in one
/// deterministic pass instead of relying only on SwiftUI view disappearance.
enum VODExclusivePlaybackGate {
    private static let lock = NSLock()
    private static var activeStorage = false
    private static var generationStorage: UInt64 = 0

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeStorage
    }

    static var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationStorage
    }

    @MainActor
    static func begin() {
        lock.lock()
        generationStorage &+= 1
        activeStorage = true
        lock.unlock()
        VODExclusiveWorkRegistry.cancelAll()
        print("[VODExclusive][v964] non-alert task registry active=\(VODExclusiveWorkRegistry.activeTaskCount)")
    }

    @MainActor
    static func end() {
        lock.lock()
        generationStorage &+= 1
        activeStorage = false
        lock.unlock()
    }
}

/// Central cancellation registry for app/UI work that is not required by KSPlayer
/// and is not part of the episode-alert exception.
@MainActor
enum VODExclusiveWorkRegistry {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    static func start(
        allowDuringExclusivePlayback: Bool = false,
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        guard allowDuringExclusivePlayback || !VODExclusivePlaybackGate.isActive else {
            return Task { @MainActor in }
        }
        let task = Task { @MainActor in
            defer { tasks[id] = nil }
            guard !Task.isCancelled,
                  allowDuringExclusivePlayback || !VODExclusivePlaybackGate.isActive else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }

    static func cancelAll() {
        let active = tasks.values
        tasks.removeAll()
        for task in active { task.cancel() }
    }

    static var activeTaskCount: Int { tasks.count }
}
