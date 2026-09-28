import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct LiveTVProcessMemorySnapshot: Equatable {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let capturedAt: Date

    var preferredBytes: UInt64 {
        physicalFootprintBytes > 0 ? physicalFootprintBytes : residentBytes
    }

    var preferredMegabytes: Double {
        Double(preferredBytes) / 1_048_576.0
    }
}

@MainActor
final class LiveTVMemoryAuditManager {
    static let shared = LiveTVMemoryAuditManager()

    private var cycle: UInt64 = 0
    private var baseline: LiveTVProcessMemorySnapshot?
    private var channelID: Int?
    private var channelName: String = ""
    private var settledSampleTask: Task<Void, Never>?

    private init() {}

    // Reuse the existing one-shot task_vm_info sampler for the opt-in FPS HUD.
    // No allocation/polling occurs while the HUD is disabled.
    nonisolated static func currentFootprintMegabytes() -> Double? {
        captureProcessMemory()?.preferredMegabytes
    }

    func beginPlaybackCycle(channelID: Int, channelName: String) {
        settledSampleTask?.cancel()
        settledSampleTask = nil
        cycle &+= 1
        self.channelID = channelID
        self.channelName = channelName
        baseline = Self.captureProcessMemory()
        log(stage: "grid-exit", snapshot: baseline)
    }

    func markPlayerPresented() {
        log(stage: "player-presented", snapshot: Self.captureProcessMemory())
    }

    func markPlayerTeardown() {
        log(stage: "player-teardown", snapshot: Self.captureProcessMemory())
    }

    func markGridRestored(channelID: Int, renderedWindowStart: Int, guideVisible: Bool) {
        log(
            stage: "grid-restored channel=\(channelID) window=\(renderedWindowStart) guide=\(guideVisible)",
            snapshot: Self.captureProcessMemory()
        )

        let expectedCycle = cycle
        settledSampleTask?.cancel()
        settledSampleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled, expectedCycle == cycle else { return }
            log(stage: "grid-settled", snapshot: Self.captureProcessMemory())
            baseline = nil
            self.channelID = nil
            channelName = ""
            settledSampleTask = nil
        }
    }

    private func log(stage: String, snapshot: LiveTVProcessMemorySnapshot?) {
        guard let snapshot else {
            print("[LiveTVMemory][v975] cycle=\(cycle) stage=\(stage) unavailable")
            return
        }
        let deltaMB: Double
        if let baseline {
            deltaMB = Double(Int64(snapshot.preferredBytes) - Int64(baseline.preferredBytes)) / 1_048_576.0
        } else {
            deltaMB = 0
        }
        let warning = deltaMB > 160 ? " WARNING-retained-memory" : ""
        print(
            String(
                format: "[LiveTVMemory][v975] cycle=%llu channel=%@ id=%@ stage=%@ memory=%.1fMB delta=%+.1fMB%@",
                cycle,
                channelName,
                channelID.map(String.init) ?? "none",
                stage,
                snapshot.preferredMegabytes,
                deltaMB,
                warning
            )
        )
    }

    nonisolated private static func captureProcessMemory() -> LiveTVProcessMemorySnapshot? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return LiveTVProcessMemorySnapshot(
            residentBytes: UInt64(info.resident_size),
            physicalFootprintBytes: UInt64(info.phys_footprint),
            capturedAt: Date()
        )
        #else
        return nil
        #endif
    }
}
