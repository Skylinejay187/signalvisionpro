import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// v1133 release-stability instrumentation. This is event-driven only: no polling timer.
/// It records VOD entry/exit and memory-pressure milestones so physical Apple TV testing
/// can verify that process memory settles instead of climbing after every playback cycle.
@MainActor
final class ReleaseStabilityMemoryAuditManager {
    static let shared = ReleaseStabilityMemoryAuditManager()

    private var cycle: UInt64 = 0
    private var baselineBytes: UInt64?
    private var title: String = ""
    private var settledTask: Task<Void, Never>?

    private init() {}

    func beginVODCycle(title: String) {
        settledTask?.cancel()
        settledTask = nil
        cycle &+= 1
        self.title = title
        baselineBytes = Self.capturePhysicalFootprintBytes()
        log(stage: "vod-entry")
    }

    func markVODClosed() {
        log(stage: "vod-closed")
        let expectedCycle = cycle
        settledTask?.cancel()
        settledTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, expectedCycle == cycle else { return }
            log(stage: "catalog-settled")
            baselineBytes = nil
            title = ""
            settledTask = nil
        }
    }

    func markMemoryPressure() {
        log(stage: "memory-pressure")
    }

    private func log(stage: String) {
        guard let bytes = Self.capturePhysicalFootprintBytes() else {
            print("[ReleaseStability][v1133] cycle=\(cycle) stage=\(stage) memory=unavailable")
            return
        }
        let mb = Double(bytes) / 1_048_576.0
        let delta = baselineBytes.map { Double(Int64(bytes) - Int64($0)) / 1_048_576.0 } ?? 0
        let imageWork = PremiumRemoteImageLoader.releaseStabilityActiveWorkCount
        let sourceTrackCache = SourceMediaTrackProbeCache.releaseStabilityCachedSummaryCount
        let registryTasks = VODExclusiveWorkRegistry.activeTaskCount
        print(String(
            format: "[ReleaseStability][v1133] cycle=%llu stage=%@ title=%@ memory=%.1fMB delta=%+.1fMB imageWork=%d sourceTrackCache=%d optionalTasks=%d",
            cycle, stage, title, mb, delta, imageWork, sourceTrackCache, registryTasks
        ))
    }

    nonisolated private static func capturePhysicalFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let footprint = UInt64(info.phys_footprint)
        return footprint > 0 ? footprint : UInt64(info.resident_size)
        #else
        return nil
        #endif
    }
}
