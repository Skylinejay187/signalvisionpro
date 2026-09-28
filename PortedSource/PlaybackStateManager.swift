import Foundation
import AVFoundation

/// v786 architecture migration: centralizes lightweight playback state decisions
/// without taking ownership of the existing player surfaces, focus engine, resume
/// cache, or Source Intelligence handoff. Keep this manager pure and side-effect
/// free so the current player behavior remains unchanged.
struct PlaybackStateManager {
    static let shared = PlaybackStateManager()

    enum Surface: String {
        case avPlayer = "AVPlayer"
        case ksPlayer = "KSPlayer"
        case vlc = "VLC"
    }

    struct EngineContext {
        let isLive: Bool
        let forceKSPlayer: Bool
        let forceVLC: Bool
    }

    struct OverlayContext {
        let isLive: Bool
        let status: String
        let isLoading: Bool
        let errorText: String?
    }

    struct ResumeContext {
        let seconds: Double
        let duration: Double
        let isLive: Bool
    }

    func activeEngineName(for context: EngineContext) -> String {
        if context.isLive && context.forceKSPlayer { return "KSPlayer Live TV" }
        if context.isLive && context.forceVLC { return "VLC Live TV" }
        if context.isLive && !context.forceKSPlayer && !context.forceVLC { return "AVPlayer Live TV" }
        if context.forceKSPlayer { return Surface.ksPlayer.rawValue }
        if context.forceVLC { return Surface.vlc.rawValue }
        return Surface.avPlayer.rawValue
    }

    func loadingTitle(for context: OverlayContext) -> String {
        if context.errorText != nil { return "Playback Issue" }
        if context.isLive { return "Loading Stream..." }
        return "Preparing Playback..."
    }

    func statusLabel(for context: OverlayContext) -> String {
        let trimmed = context.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return context.isLive ? "Live" : "Cache Warming"
    }

    func shouldOfferResume(_ context: ResumeContext) -> Bool {
        guard !context.isLive else { return false }
        guard context.seconds >= 8 else { return false }
        guard context.duration <= 0 || context.seconds < context.duration * 0.95 else { return false }
        return true
    }

    func clampedSeekTarget(current: Double, delta: Double, duration: Double) -> Double {
        let target = current + delta
        guard duration > 0 else { return max(0, target) }
        return min(max(0, target), duration)
    }

    func watchedPercent(current: Double, duration: Double) -> Int {
        guard duration > 0 else { return 0 }
        return max(0, min(100, Int((current / duration) * 100.0)))
    }
}

/// v985 no-IPS diagnostic marker.
///
/// tvOS can terminate a high-memory media session without generating a normal app IPS.
/// Persist only lightweight, redacted playback facts so the next launch can report that
/// the previous player session did not close normally. Full signed debrid URLs are never
/// stored.
enum PlaybackSessionTerminationJournal {
    private static let activeKey = "vodPlaybackSessionActive.v985"
    private static let snapshotKey = "vodPlaybackSessionSnapshot.v985"

    static func reportAndResetPreviousAbnormalSession() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: activeKey) else { return }
        let snapshot = defaults.dictionary(forKey: snapshotKey) ?? [:]
        print("[PlaybackMemory][v985] Previous VOD session ended without closePlayer; possible tvOS jetsam/watchdog/media-process termination. snapshot=\(snapshot)")
        defaults.set(false, forKey: activeKey)
    }

    static func begin(item: MediaItem, selectedURL: URL, label: String, fallbackCount: Int) {
        let defaults = UserDefaults.standard
        let snapshot: [String: Any] = [
            "title": item.title,
            "type": item.type,
            "host": selectedURL.host ?? "unknown",
            "fileExtension": selectedURL.pathExtension,
            "pathLength": selectedURL.path.count,
            "label": String(label.prefix(240)),
            "fallbackCount": fallbackCount,
            "startedAt": Date().timeIntervalSince1970
        ]
        defaults.set(snapshot, forKey: snapshotKey)
        defaults.set(true, forKey: activeKey)
    }

    static func endNormally() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: activeKey)
        defaults.removeObject(forKey: snapshotKey)
    }
}

