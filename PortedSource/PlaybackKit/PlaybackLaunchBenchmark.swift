import Foundation

/// vBRDC229: lightweight startup instrumentation for the source-to-first-frame hot path.
/// No resolved URL, token, cookie, or provider secret is ever printed. The benchmark is
/// intentionally independent of SwiftUI so decoder callbacks can mark checkpoints without
/// invalidating playback chrome.
final class PlaybackLaunchBenchmark {
    static let shared = PlaybackLaunchBenchmark()

    private struct Run {
        let sessionID: UUID
        let title: String
        let startedAt: DispatchTime
        var lastAt: DispatchTime
        var stages: [(name: String, totalMS: Double, deltaMS: Double)]
    }

    private let lock = NSLock()
    private var runs: [UUID: Run] = [:]
    private let maximumRuns = 8

    private init() {}

    func begin(sessionID: UUID, title: String) {
        let now = DispatchTime.now()
        lock.lock()
        if runs.count >= maximumRuns, let oldest = runs.keys.first {
            runs.removeValue(forKey: oldest)
        }
        runs[sessionID] = Run(
            sessionID: sessionID,
            title: String(title.prefix(96)),
            startedAt: now,
            lastAt: now,
            stages: []
        )
        lock.unlock()
        print("[PlaybackStartup][vBRDC229] session=\(sessionID.uuidString.prefix(8)) t+0.0ms play requested • title=\(String(title.prefix(96)))")
    }

    func mark(sessionID: UUID?, _ stage: String) {
        guard let sessionID else { return }
        let now = DispatchTime.now()
        lock.lock()
        guard var run = runs[sessionID] else {
            lock.unlock()
            return
        }
        let total = Self.milliseconds(from: run.startedAt, to: now)
        let delta = Self.milliseconds(from: run.lastAt, to: now)
        // A stage is idempotent. This prevents high-frequency clock callbacks from
        // bloating diagnostics when they race the first-render callback.
        if run.stages.contains(where: { $0.name == stage }) {
            lock.unlock()
            return
        }
        run.stages.append((stage, total, delta))
        run.lastAt = now
        runs[sessionID] = run
        lock.unlock()
        print(String(format: "[PlaybackStartup][vBRDC229] session=%@ t+%.1fms (+%.1fms) %@", String(sessionID.uuidString.prefix(8)), total, delta, stage))
    }

    func finish(sessionID: UUID?, finalStage: String = "transition cover released") {
        guard let sessionID else { return }
        mark(sessionID: sessionID, finalStage)
        lock.lock()
        guard let run = runs.removeValue(forKey: sessionID) else {
            lock.unlock()
            return
        }
        lock.unlock()
        let total = Self.milliseconds(from: run.startedAt, to: DispatchTime.now())
        let breakdown = run.stages
            .map { String(format: "%@=%.1fms", $0.name, $0.totalMS) }
            .joined(separator: " | ")
        print(String(format: "[PlaybackStartup][vBRDC229] COMPLETE session=%@ total=%.1fms • %@", String(sessionID.uuidString.prefix(8)), total, breakdown))
    }

    func cancel(sessionID: UUID?) {
        guard let sessionID else { return }
        lock.lock()
        runs.removeValue(forKey: sessionID)
        lock.unlock()
    }

    private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        let startNS = start.uptimeNanoseconds
        let endNS = end.uptimeNanoseconds
        guard endNS >= startNS else { return 0 }
        return Double(endNS - startNS) / 1_000_000.0
    }
}
