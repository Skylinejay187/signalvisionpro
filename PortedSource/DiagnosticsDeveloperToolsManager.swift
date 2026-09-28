import Foundation
import SwiftUI

/// v795 Production Hardening: Diagnostics + Developer Tools.
///
/// This manager is intentionally passive and read-only. It centralizes lightweight
/// diagnostic snapshots for playback, network/API, guide/cache, Source Intelligence,
/// and membership/entitlement state without changing normal app behavior, UI flow,
/// player engines, source selection, or backend contracts.
@MainActor
final class DiagnosticsDeveloperToolsManager: ObservableObject {
    static let shared = DiagnosticsDeveloperToolsManager()

    enum Area: String, CaseIterable, Identifiable {
        case playback = "Playback"
        case networkAPI = "Network / API"
        case guideCache = "Guide / Cache"
        case sourceIntelligence = "Source Intelligence"
        case membership = "Membership / Entitlement"
        case appState = "App State"

        var id: String { rawValue }
    }

    struct Snapshot: Identifiable, Equatable {
        let id = UUID()
        let area: Area
        let title: String
        let status: String
        let details: [String]
        let createdAt: Date

        init(area: Area, title: String, status: String, details: [String], createdAt: Date = Date()) {
            self.area = area
            self.title = title
            self.status = status
            self.details = details
            self.createdAt = createdAt
        }
    }

    @Published private(set) var snapshots: [Snapshot] = []
    @Published private(set) var lastDeveloperNote: String?

    private init() {}

    func record(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.area == snapshot.area && $0.title == snapshot.title }
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > 60 {
            snapshots = Array(snapshots.prefix(60))
        }
    }

    func clear() {
        snapshots.removeAll()
        lastDeveloperNote = "Diagnostics cleared."
    }

    func note(_ message: String) {
        lastDeveloperNote = message
    }

    func playbackSnapshot(engine: String, isLive: Bool, isPlaying: Bool, urlDescription: String?, errorText: String?) -> Snapshot {
        Snapshot(
            area: .playback,
            title: isLive ? "Live Playback" : "VOD Playback",
            status: errorText?.isEmpty == false ? "Needs attention" : (isPlaying ? "Playing" : "Idle"),
            details: [
                "Engine: \(engine)",
                "Mode: \(isLive ? "Live TV" : "VOD")",
                "Playing: \(isPlaying ? "Yes" : "No")",
                "URL: \(ReleaseCandidateSecurityManager.redactedURLDescription(urlDescription))",
                "Error: \(ReleaseCandidateSecurityManager.redactedText(errorText))"
            ]
        )
    }

    func networkSnapshot(baseURL: String, lastStatus: String?, isLoading: Bool) -> Snapshot {
        Snapshot(
            area: .networkAPI,
            title: "Backend API",
            status: isLoading ? "Loading" : "Ready",
            details: [
                "Base URL: \(baseURL.isEmpty ? "Not configured" : ReleaseCandidateSecurityManager.redactedURLDescription(baseURL))",
                "Loading: \(isLoading ? "Yes" : "No")",
                "Last Status: \(ReleaseCandidateSecurityManager.redactedText(lastStatus))"
            ]
        )
    }

    func guideCacheSnapshot(channelCount: Int, programCount: Int, lastRefreshDescription: String?) -> Snapshot {
        Snapshot(
            area: .guideCache,
            title: "Live TV Guide Cache",
            status: channelCount > 0 ? "Loaded" : "Empty",
            details: [
                "Channels: \(channelCount)",
                "Programs: \(programCount)",
                "Last Refresh: \(lastRefreshDescription?.isEmpty == false ? lastRefreshDescription! : "Unknown")"
            ]
        )
    }

    func sourceIntelligenceSnapshot(maxLinks: Int, currentLinks: Int, isScanning: Bool, providerCount: Int) -> Snapshot {
        Snapshot(
            area: .sourceIntelligence,
            title: "Source Intelligence",
            status: isScanning ? "Scanning" : "Ready",
            details: [
                "Maximum Links Setting: \(maxLinks)",
                "Current Links: \(currentLinks)",
                "Providers: \(providerCount)",
                "Scanning: \(isScanning ? "Yes" : "No")"
            ]
        )
    }

    func membershipSnapshot(plan: String, status: String, deviceCountDescription: String?, trialDescription: String?) -> Snapshot {
        Snapshot(
            area: .membership,
            title: "Membership Entitlement",
            status: status.isEmpty ? "Unknown" : status,
            details: [
                "Plan: \(plan.isEmpty ? "Unknown" : plan)",
                "Status: \(status.isEmpty ? "Unknown" : status)",
                "Devices: \(deviceCountDescription?.isEmpty == false ? deviceCountDescription! : "Unknown")",
                "Trial: \(trialDescription?.isEmpty == false ? trialDescription! : "Unknown")"
            ]
        )
    }

    func appStateSnapshot(activeTab: String, focusedArea: String?, overlayDescription: String?) -> Snapshot {
        Snapshot(
            area: .appState,
            title: "App State",
            status: "Read Only",
            details: [
                "Active Tab: \(activeTab)",
                "Focused Area: \(focusedArea?.isEmpty == false ? focusedArea! : "Unknown")",
                "Overlay: \(overlayDescription?.isEmpty == false ? overlayDescription! : "None")"
            ]
        )
    }

    func summaryLines() -> [String] {
        if snapshots.isEmpty { return ["No diagnostics captured yet."] }
        return snapshots.map { snapshot in
            "\(snapshot.area.rawValue): \(snapshot.title) — \(snapshot.status)"
        }
    }
}

struct DiagnosticsDeveloperToolsPanel: View {
    @ObservedObject var manager: DiagnosticsDeveloperToolsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Read-only developer snapshots for production QA.")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }

            if let note = manager.lastDeveloperNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            ForEach(Array(manager.snapshots.prefix(8))) { snapshot in
                DiagnosticsSnapshotCard(snapshot: snapshot)
            }

            if manager.snapshots.isEmpty {
                Text("No diagnostics captured yet.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}


// Break a deeply nested builder into an independent row: same styling and data,
// fewer generic constraints for the visionOS Swift compiler to solve at once.
private struct DiagnosticsSnapshotCard: View {
    let snapshot: DiagnosticsDeveloperToolsManager.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(snapshot.area.rawValue) • \(snapshot.title)")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(snapshot.status)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.cyan.opacity(0.9))
            ForEach(Array(snapshot.details.prefix(5)), id: \.self) { line in
                Text(line)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
