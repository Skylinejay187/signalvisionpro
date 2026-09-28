import Foundation
import SwiftUI
import UIKit
import AVFoundation
import QuartzCore

#if canImport(KSPlayer)
import KSPlayer
#endif

// Phase 12 final extraction: KSPlayer, FFmpeg option construction, display matching,
// render-surface ownership, track handling, and the subtitle renderer bridge live under PlaybackKit.

#if os(tvOS)
@available(tvOS 11.2, *)
enum DebridTVOSDisplayMatchCoordinator {
    private static var lastAppliedSignature: String = ""
    private static var pendingLiveWorkItem: DispatchWorkItem? = nil

    private static func keyWindow() -> UIWindow? {
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
    }

    static func isSystemDisplayMatchingEnabled() -> Bool {
        guard let window = keyWindow() else { return false }
        return window.avDisplayManager.isDisplayCriteriaMatchingEnabled
    }

    private static func apply(_ criteria: AVDisplayCriteria?, signature: String, source: String) {
        guard let window = keyWindow() else { return }
        let manager = window.avDisplayManager
        DispatchQueue.main.async {
            guard lastAppliedSignature != signature || criteria != nil else { return }
            manager.preferredDisplayCriteria = criteria
            lastAppliedSignature = signature
            if criteria != nil {
                print("[DebridChannels][DisplayMatch] applied \(source) \(signature)")
            } else {
                print("[DebridChannels][DisplayMatch] reset")
            }
        }
    }

    private static func inferredFrameRate(from value: String) -> Double? {
        let lower = value.lowercased()
        if lower.contains("23.976") || lower.contains("23_976") || lower.contains("24000/1001") { return 24000.0 / 1001.0 }
        if lower.contains("24fps") || lower.contains(" 24 ") || lower.contains(".24.") { return 24.0 }
        if lower.contains("25fps") || lower.contains(" 25 ") || lower.contains(".25.") { return 25.0 }
        if lower.contains("29.97") || lower.contains("30000/1001") { return 30000.0 / 1001.0 }
        if lower.contains("30fps") || lower.contains(" 30 ") || lower.contains(".30.") { return 30.0 }
        if lower.contains("50fps") || lower.contains(" 50 ") || lower.contains(".50.") { return 50.0 }
        if lower.contains("59.94") || lower.contains("60000/1001") { return 60000.0 / 1001.0 }
        if lower.contains("60fps") || lower.contains(" 60 ") || lower.contains(".60.") { return 60.0 }
        return nil
    }


    private static func normalizedLiveFrameRate(_ fps: Double) -> Double {
        if abs(fps - 25.0) < 0.25 { return 50.0 }
        if abs(fps - 30.0) < 0.35 { return 60.0 }
        if abs(fps - (30000.0 / 1001.0)) < 0.35 { return 60000.0 / 1001.0 }
        return fps
    }

    static func cancelPendingLiveDisplayMatch() {
        pendingLiveWorkItem?.cancel()
        pendingLiveWorkItem = nil
    }

    static func applyForLiveChannel(url: URL, hint: String) {
        cancelPendingLiveDisplayMatch()
        let combined = (url.absoluteString + " " + hint)
        let signature = "live|" + combined.lowercased()
        let workItem = DispatchWorkItem {
            let headers: [String: String] = [
                "User-Agent": "DebridChannels-tvOS/613 LiveDisplayMatch",
                "Accept": "application/vnd.apple.mpegurl,application/x-mpegURL,video/*,application/octet-stream,*/*;q=0.8",
                "Accept-Encoding": "identity",
                "Connection": "keep-alive"
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

            // First try the system-vended criteria. This is safest for HLS and channels that
            // already expose correct range/frame metadata to AVFoundation.
            let preferredCriteria = asset.preferredDisplayCriteria
            apply(preferredCriteria, signature: signature + "|preferred", source: "live-preferred")
        }
        pendingLiveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    static func applyForFullScreenVOD(url: URL, hint: String, httpHeaders: [String: String] = [:]) {
        let combined = (url.absoluteString + " " + hint)
        let signature = combined.lowercased()
        guard !signature.contains("/trailers/") && !signature.contains("trailer") else { return }

        var headers: [String: String] = [
            "User-Agent": "DebridChannels-tvOS/613 DisplayMatch",
            "Accept": "application/vnd.apple.mpegurl,application/x-mpegURL,video/*,application/octet-stream,*/*;q=0.8",
            "Accept-Encoding": "identity",
            "Connection": "keep-alive"
        ]
        for (name, value) in httpHeaders {
            if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                headers.removeValue(forKey: existing)
            }
            headers[name] = value
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        // Apple's preferred path: use the AVAsset-vended criteria and assign it to the key
        // UIWindow's AVDisplayManager before KSPlayer starts drawing. This respects the user's
        // tvOS Match Frame Rate / Match Dynamic Range settings instead of forcing display modes.
        let preferredCriteria = asset.preferredDisplayCriteria
        apply(preferredCriteria, signature: signature, source: "asset-preferred")

        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            guard status == .loaded else { return }

            let loadedCriteria = asset.preferredDisplayCriteria
            apply(loadedCriteria, signature: signature + "|loaded", source: "asset-loaded")
            return
        }
    }

    static func reset() {
        cancelPendingLiveDisplayMatch()
        apply(nil, signature: "", source: "reset")
        lastAppliedSignature = ""
    }
}
#endif

#if canImport(KSPlayer)

// vBRDC168: bitrate + Apple TV memory-aware VOD cache planner.
//
// KSPNUVIO's `maxBufferDuration` is a time ceiling, but memory cost is driven by
// compressed bitrate. A fixed 300-second window can therefore be cheap for a small
// WEB encode and enormous for a UHD remux. This planner converts an explicit/estimated
// bitrate into a byte-budgeted time window, then scales that budget to the device's
// physical-memory tier. Weak uncached/low-seeder sources receive extra reserve when RAM
// allows so intermittent swarm/CDN delivery can be absorbed without making every 4K
// title use a huge fixed cache.
private struct AdaptiveVODCacheProfile {
    enum MemoryTier: String {
        case compact
        case standard
        case high
    }

    let memoryTier: MemoryTier
    let physicalMemoryGB: Double
    let estimatedBitrateMbps: Double
    let preferredBufferDuration: TimeInterval
    let maxBufferDuration: TimeInterval
    let packetBudgetMiB: Double
    let weakSource: Bool
    let lowSeederSource: Bool
    let seederCount: Int?
    let bitrateSource: String

    var diagnostic: String {
        let seeds = seederCount.map(String.init) ?? "unknown"
        return "tier=\(memoryTier.rawValue) ram=\(String(format: "%.2f", physicalMemoryGB))GB bitrate=\(String(format: "%.1f", estimatedBitrateMbps))Mbps(\(bitrateSource)) weak=\(weakSource) lowSeeder=\(lowSeederSource) seeders=\(seeds) packetBudget=\(Int(packetBudgetMiB))MiB buffer=\(Int(preferredBufferDuration))/\(Int(maxBufferDuration))s"
    }
}

private enum AdaptiveVODCachePlanner {
    static func profile(routeHint: String, url: URL, sourceSizeGB: Double?, knownDurationSeconds: Double? = nil) -> AdaptiveVODCacheProfile {
        let haystack = (routeHint + " " + url.absoluteString).lowercased()
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let tier: AdaptiveVODCacheProfile.MemoryTier
        if physicalGB < 2.5 {
            tier = .compact
        } else if physicalGB < 3.5 {
            tier = .standard
        } else {
            tier = .high
        }

        let seeders = inferredSeederCount(from: haystack)
        let uncached = haystack.contains("cache-health=uncached") ||
            (haystack.contains("uncached") && !haystack.contains("cached only")) ||
            haystack.contains("not cached") || haystack.contains("download required")
        // Cached debrid files no longer depend on the original swarm, so low original
        // seeder metadata only increases reserve when the route is uncached/streaming.
        let lowSeeder = uncached && (seeders.map { $0 <= 25 } ?? false)
        // Uncached sources receive a modest cushion; truly low-seeder sources receive
        // the larger reserve. Unknown swarm health is treated like ordinary uncached
        // delivery rather than assuming the worst.
        let weakSource = uncached

        let bitrate: Double
        let bitrateSource: String
        if let explicit = explicitBitrateMbps(from: haystack) {
            bitrate = explicit
            bitrateSource = "explicit"
        } else if let sourceSizeGB {
            // Once KSPlayer exposes the real title duration, recompute average bitrate
            // from size/duration and tighten or deepen the cache without a network probe.
            // Before that point, episode-looking routes use a 45-minute baseline and
            // movie/unknown routes use 105 minutes. Quality/container floors keep short
            // high-bitrate files from being underestimated.
            if let knownDurationSeconds, knownDurationSeconds.isFinite,
               knownDurationSeconds >= 300, knownDurationSeconds <= 28_800 {
                bitrate = max(sourceSizeGB * 8_192.0 / knownDurationSeconds, qualityBitrateFloor(in: haystack))
                bitrateSource = "size+duration+quality"
            } else {
                let looksEpisodic = haystack.range(of: #"s\d{1,2}e\d{1,3}"#, options: .regularExpression) != nil ||
                    haystack.contains("episode")
                let assumedSeconds = looksEpisodic ? 2_700.0 : 6_300.0
                bitrate = max(sourceSizeGB * 8_192.0 / assumedSeconds, qualityBitrateFloor(in: haystack))
                bitrateSource = "size+quality"
            }
        } else {
            bitrate = qualityBitrateFloor(in: haystack)
            bitrateSource = "quality"
        }
        let safeBitrate = min(max(bitrate, 2.0), 140.0)

        let baseBudgetMiB: Double
        let uncachedBudgetMiB: Double
        let lowSeederBudgetMiB: Double
        let hardMaxSeconds: Double
        switch tier {
        case .compact:
            baseBudgetMiB = 96
            uncachedBudgetMiB = 112
            lowSeederBudgetMiB = 128
            hardMaxSeconds = lowSeeder ? 150 : (weakSource ? 135 : 120)
        case .standard:
            baseBudgetMiB = 180
            uncachedBudgetMiB = 210
            lowSeederBudgetMiB = 240
            hardMaxSeconds = lowSeeder ? 300 : (weakSource ? 270 : 240)
        case .high:
            baseBudgetMiB = 320
            uncachedBudgetMiB = 370
            lowSeederBudgetMiB = 420
            hardMaxSeconds = lowSeeder ? 420 : (weakSource ? 390 : 360)
        }
        let packetBudgetMiB = lowSeeder ? lowSeederBudgetMiB : (weakSource ? uncachedBudgetMiB : baseBudgetMiB)
        // MiB -> megabits divided by megabits/sec = seconds.
        let byteBudgetSeconds = packetBudgetMiB * 8.388608 / safeBitrate
        let minimumMax: Double
        switch tier {
        case .compact: minimumMax = 12
        case .standard: minimumMax = 18
        case .high: minimumMax = 24
        }
        let maxBuffer = min(max(byteBudgetSeconds, minimumMax), hardMaxSeconds)

        let preferred: Double
        if lowSeeder {
            // `isSecondOpen` still permits instant first frame. This value primarily
            // becomes the rebuffer/recovery cushion once playback is underway.
            preferred = tier == .compact ? 7 : 9
        } else if weakSource {
            preferred = tier == .compact ? 6 : 7
        } else if safeBitrate >= 60 {
            preferred = 4
        } else {
            preferred = 5
        }

        return AdaptiveVODCacheProfile(
            memoryTier: tier,
            physicalMemoryGB: physicalGB,
            estimatedBitrateMbps: safeBitrate,
            preferredBufferDuration: min(preferred, max(3, maxBuffer - 4)),
            maxBufferDuration: maxBuffer,
            packetBudgetMiB: packetBudgetMiB,
            weakSource: weakSource,
            lowSeederSource: lowSeeder,
            seederCount: seeders,
            bitrateSource: bitrateSource
        )
    }

    private static func qualityBitrateFloor(in haystack: String) -> Double {
        let isRemux = haystack.contains("remux") || haystack.contains("bdremux")
        let is4K = haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd")
        let losslessAudio = haystack.contains("truehd") || haystack.contains("dts-hd") || haystack.contains("dtshd")
        if isRemux && is4K { return 65 }
        if isRemux { return 38 }
        if is4K && losslessAudio { return 30 }
        if is4K { return 18 }
        if haystack.contains("1440") { return 14 }
        if haystack.contains("1080") || losslessAudio { return 10 }
        if haystack.contains("720") { return 6 }
        if haystack.contains("576") || haystack.contains("480") { return 4 }
        return 8
    }

    private static func explicitBitrateMbps(from value: String) -> Double? {
        let patterns: [(String, Double)] = [
            (#"(\d+(?:[\.,]\d+)?)\s*(?:mbps|mbit/s|mbit|mb/s)"#, 1.0),
            (#"(\d+(?:[\.,]\d+)?)\s*(?:kbps|kbit/s|kbit|kb/s)"#, 0.001)
        ]
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: value) else { continue }
            let raw = value[numberRange].replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(raw), parsed > 0 { return parsed * multiplier }
        }
        return nil
    }

    private static func inferredSeederCount(from value: String) -> Int? {
        let patterns = [
            #"(?:seeders?|seeds?|peers?)\s*[:=+\-]?\s*(\d{1,6})"#,
            #"(?:👤|👥)\s*(\d{1,6})"#,
            #"(?:^|\s)s\s*[:=]\s*(\d{1,6})(?:\s|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, options: [], range: range),
                  match.numberOfRanges > 1,
                  let countRange = Range(match.range(at: 1), in: value),
                  let count = Int(value[countRange]) else { continue }
            return count
        }
        return nil
    }
}

// v998: PlaybackKit-owned subtitle bridge. The app uses KSPlayerLayer directly instead
// of IOSVideoPlayerView, so KSPlayer's built-in SRTControl/labels are not mounted for
// this custom VOD surface. Keep the decoder/player untouched and own only the timed
// subtitle model plus a transparent renderer above video and below the SwiftUI VOD UI.
private final class PlaybackExternalSubtitleInfo: SubtitleInfo {
    let subtitleID: String
    let name: String
    var delay: TimeInterval = 0
    var isEnabled: Bool = false

    let url: URL
    private let subtitle = KSSubtitle()

    init(url: URL) {
        self.url = url
        subtitleID = "debrid-external-" + url.absoluteString
        let decoded = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        name = decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "External Subtitle" : decoded
    }

    func load() async throws {
        try await subtitle.parse(url: url, userAgent: "DebridChannels-tvOS/527 SubtitleBridge")
    }

    func search(for time: TimeInterval) -> [SubtitlePart] {
        subtitle.search(for: time)
    }
}

private final class PlaybackSubtitleOverlayView: UIView {
    private let textLabel = UILabel()
    private let imageView = UIImageView()

    override var canBecomeFocused: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        layer.zPosition = 50

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        textLabel.numberOfLines = 0
        textLabel.textAlignment = .center
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.backgroundColor = .clear
        textLabel.isHidden = true
        textLabel.adjustsFontSizeToFitWidth = false
        textLabel.allowsDefaultTighteningForTruncation = false
        textLabel.contentScaleFactor = traitCollection.displayScale
        textLabel.layer.contentsScale = traitCollection.displayScale
        textLabel.layer.shouldRasterize = false
        textLabel.layer.allowsEdgeAntialiasing = true
        textLabel.layer.shadowColor = UIColor.black.cgColor
        textLabel.layer.shadowOpacity = 0.96
        textLabel.layer.shadowRadius = 2.0
        textLabel.layer.shadowOffset = CGSize(width: 0, height: 2)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 92),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -92),
            textLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -82),
            textLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86),

            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -72),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.88),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        textLabel.attributedText = nil
        textLabel.isHidden = true
        imageView.image = nil
        imageView.isHidden = true
    }

    func render(parts: [SubtitlePart]) {
        guard !parts.isEmpty else {
            clear()
            return
        }

        let images = parts.compactMap(\.image)
        imageView.image = images.first
        imageView.isHidden = images.isEmpty

        let textParts = parts.compactMap(\.text).filter { $0.length > 0 }
        guard !textParts.isEmpty else {
            textLabel.attributedText = nil
            textLabel.isHidden = true
            return
        }

        // Render from the cue strings instead of carrying source ASS/SSA decoration
        // into UILabel. Some streams include their own stroke/shadow/underline attributes;
        // combining those with a thick negative NSStrokeWidth cut into glyph interiors
        // (most visibly e/a/o, commas, and apostrophes). A clean fill plus a layer shadow
        // keeps the v998 bridge intact while preserving sharp CoreText rasterization.
        let cleanLines = textParts
            .map { $0.string.replacingOccurrences(of: "\r", with: "") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanLines.isEmpty else {
            textLabel.attributedText = nil
            textLabel.isHidden = true
            return
        }

        let combined = NSMutableAttributedString(string: cleanLines.joined(separator: "\n"))
        let fullRange = NSRange(location: 0, length: combined.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        combined.setAttributes([
            .font: UIFont.systemFont(ofSize: 58, weight: .medium),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
            .ligature: 1,
            .kern: 0,
        ], range: fullRange)

        textLabel.attributedText = combined
        textLabel.isHidden = false
    }
}

// v990 main-VOD cadence refinement, built directly from v987.
//
// v987 successfully avoided KSPNUVIO's aggressive drop/flush cascade, but its six-frame
// lateness allowance could reach 250 ms for 23.976/24 fps cinema. Presenting every frame
// while that far behind can look like tiny slow-motion steps during pans, zooms, and motion.
//
// This refinement keeps the v987 safety rules (no GOP drop, queue flush, or cadence seek),
// but uses a tighter phase window and a short late-frame streak diagnostic. It also lets
// a frame present slightly before the exact half-frame boundary
// to avoid unnecessary one-refresh repeats on matched 23.976/24 Hz output.
private final class DebridFlixorVODOptions: KSOptions {
    private var consecutiveLateDecisions = 0
    private var lateStreakDiagnosticCount = 0
    private var lastLateStreakDiagnosticHostTime: CFTimeInterval = 0

    override func videoFrameMaxCount(
        fps: Float,
        naturalSize: CGSize,
        isLive: Bool
    ) -> UInt8 {
        guard !isLive else {
            return super.videoFrameMaxCount(
                fps: fps,
                naturalSize: naturalSize,
                isLive: true
            )
        }

        // v1012: restore the last preferred static VOD queue profile.
        // Live TV remains fully upstream/adaptive through the guard above.
        let maxDimension = max(naturalSize.width, naturalSize.height)
        let frameCount: UInt8

        if maxDimension >= 3840 {
            // vBRDC135: a 24-frame 4K decoded queue can pin hundreds of MB of
            // VideoToolbox pixel buffers/textures. Keep enough decoded headroom for
            // cadence stability without carrying nearly a full second of 4K surfaces.
            frameCount = fps >= 45 ? 18 : 16
        } else if maxDimension >= 1920 {
            frameCount = 24
        } else {
            frameCount = 16
        }

        print(
            "[PlaybackKit] VOD decoded-frame queue=\(frameCount) " +
            "fps=\(fps) " +
            "size=\(Int(naturalSize.width))x\(Int(naturalSize.height))"
        )

        return frameCount
    }

    override func videoClockSync(
        main: KSClock,
        nextVideoTime: TimeInterval,
        fps: Double,
        frameCount: Int
    ) -> (Double, ClockProcessType) {
        let safeFPS = max(fps, 1.0)
        let frameDuration = 1.0 / safeFPS
        let desiredTime = main.time.seconds + CACurrentMediaTime() - main.lastMediaTime - videoDelay
        let difference = nextVideoTime - desiredTime

        // KSPNUVIO normally holds until half a frame early. A 0.35-frame window is still
        // safely inside the presentation interval, but avoids repeating the previous frame
        // for a whole display refresh when the next frame is only slightly early.
        let earlyHoldWindow = 0.35 * frameDuration
        if difference >= earlyHoldWindow {
            consecutiveLateDecisions = 0
            return (difference, .remain)
        }

        // v987 allowed six frames of lateness (250 ms at 24 fps). Tighten that to 2.5
        // frames, with a 70 ms floor for high-frame-rate material. This preserves tolerance
        // for a brief decode spike without visibly walking through a deep late queue.
        let softLateWindow = max(2.5 * frameDuration, 0.070)
        if difference >= -softLateWindow {
            consecutiveLateDecisions = 0
            return (difference, .next)
        }

        consecutiveLateDecisions += 1
        let now = CACurrentMediaTime()
        let minimumDiagnosticInterval = max(3.0 * frameDuration, 0.100)
        let diagnosticCooldownElapsed =
            lastLateStreakDiagnosticHostTime == 0 ||
            now - lastLateStreakDiagnosticHostTime >= minimumDiagnosticInterval

        // vBRDC063 physical tvOS Match Frame Rate correction. v1031 intentionally stopped
        // dropping late VOD frames because isolated drops were visible in high-motion scenes.
        // That is still the normal policy. There is one exception now: when audio is already
        // the master clock and video is *sustainably* far behind it, continuing to present every
        // queued frame preserves the lateness indefinitely and becomes visible lip-sync drift.
        // This can be exposed by SwiftUI overlay composition on a matched 23.976/24 Hz output.
        // Recover only from a true A/V-sync emergency; never seek/flush/recreate the player.
        let severeAVLagThreshold = max(4.5 * frameDuration, 0.180)
        let shouldRecoverSevereAVLag =
            difference <= -severeAVLagThreshold &&
            frameCount > 3 &&
            consecutiveLateDecisions >= 3

        if shouldRecoverSevereAVLag {
            if diagnosticCooldownElapsed {
                lastLateStreakDiagnosticHostTime = now
                lateStreakDiagnosticCount += 1
                if lateStreakDiagnosticCount == 1 || lateStreakDiagnosticCount % 20 == 0 {
                    print("[PlaybackKit][vBRDC063] severe VOD A/V lag recovery diff=\(String(format: "%.4f", difference)) fps=\(String(format: "%.3f", safeFPS)) queued=\(frameCount)")
                }
            }
            // Drop one *additional* decoded video frame while returning the current eligible
            // frame. Repeated display-link ticks can therefore close a large video deficit in
            // small frame-sized steps without touching audio, seeking, flushing, or buffering.
            return (difference, .dropNextFrame)
        }

        let shouldReportLateStreak =
            frameCount > 6 &&
            consecutiveLateDecisions >= 3 &&
            diagnosticCooldownElapsed

        if shouldReportLateStreak {
            lastLateStreakDiagnosticHostTime = now
            consecutiveLateDecisions = 0
            lateStreakDiagnosticCount += 1
            if lateStreakDiagnosticCount == 1 || lateStreakDiagnosticCount % 20 == 0 {
                print("[PlaybackKit][v1031] late VOD cadence streak=\(lateStreakDiagnosticCount) dropSuppressed=true diff=\(String(format: "%.4f", difference)) fps=\(String(format: "%.3f", safeFPS)) queued=\(frameCount)")
            }
        }

        return (difference, .next)
    }
}

struct KSPlayerVideoSurface: UIViewRepresentable {
    let url: URL
    let shouldPlay: Bool
    // vBRDC085: an explicit play assertion command can be delivered even when
    // `shouldPlay` is already true and therefore would not otherwise update the engine.
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
    // v1054: immutable owner supplied by the VOD launch. Trailers/Live TV leave this nil.
    var playbackSessionID: UUID? = nil
    var routeHint: String = ""
    // vBRDC089: provider-specific playback context (Referer/Origin/Cookie/Auth/UA).
    // This is session-owned and never logged.
    var httpHeaders: [String: String] = [:]
    var enableDisplayMatch: Bool = false
    var displayMatchIsLive: Bool = false
    var selectedAudioTrackIndex: Int? = nil
    var selectedSubtitleTrackIndex: Int? = nil
    var selectedExternalSubtitleURL: URL? = nil
    var subtitleDelayMS: Int = 0
    var trackSelectionSerial: Int = 0
    // Phase 15: positive dB gain is applied only through KSPlayer's existing FFmpeg
    // audio-filter chain. This never changes system volume, AVAudioSession, Live TV, or trailers.
    var audioGainDB: Double = 0
    var onPlaybackTimeUpdate: ((Double, Double) -> Void)? = nil
    // vBRDC062: publish the engine's real playable/buffered endpoint separately from
    // the playback clock so the VOD scrubber can show a secondary "ghost" buffer rail.
    // KSPNUVIO already tracks this as MediaPlayerProtocol.playableTime; no second
    // downloader, polling network request, or fake byte-cache is introduced.
    var onBufferUpdate: ((Double, Double) -> Void)? = nil
    var onTracksDiscovered: (([RealMediaTrackOption], [RealMediaTrackOption]) -> Void)? = nil
    // Phase 4: failure callback is source-generation scoped by the SwiftUI caller.
    // The coordinator invokes it only while this exact KSPlayerLayer is still active.
    var onPlaybackFailure: ((String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onExternalAudioReady: (() -> Void)? = nil
    var onExternalAudioFailure: ((String) -> Void)? = nil
    var onChaptersDiscovered: (([PlaybackChapterMarker]) -> Void)? = nil
    var onAudioFingerprintSample: ((PlaybackAudioFingerprintSample) -> Void)? = nil

    final class KSContainerView: UIView {
        private var cachedBounds: CGRect = .null
        private var cachedFrame: CGRect = .null
        private var cachedSafeAreaInsets: UIEdgeInsets = .zero
        private weak var frozenRenderView: UIView?
        private var didFreezePlayerHierarchy = false
        private let subtitleOverlay = PlaybackSubtitleOverlayView()

        override var canBecomeFocused: Bool { false }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
        }


        func installRenderViewOnce(_ renderView: UIView) {
            guard frozenRenderView == nil else { return }
            frozenRenderView = renderView
            addSubview(renderView)
            freezePlayerHierarchyOnce(in: renderView)
            if subtitleOverlay.superview == nil {
                addSubview(subtitleOverlay)
                subtitleOverlay.frame = bounds
                subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            bringSubviewToFront(subtitleOverlay)
            applyGeometryIfChanged(force: true)
        }

        func updateRenderContentModeIfChanged(_ contentMode: UIView.ContentMode) {
            guard let renderView = frozenRenderView, renderView.contentMode != contentMode else { return }
            renderView.contentMode = contentMode
            let gravity: CALayerContentsGravity
            switch contentMode {
            case .scaleAspectFill: gravity = .resizeAspectFill
            case .scaleToFill: gravity = .resize
            default: gravity = .resizeAspect
            }
            if renderView.layer.contentsGravity != gravity { renderView.layer.contentsGravity = gravity }
        }

        func resetRenderHostForURLChange() {
            frozenRenderView = nil
            didFreezePlayerHierarchy = false
            cachedBounds = .null
            cachedFrame = .null
            cachedSafeAreaInsets = .zero
            subtitleOverlay.clear()
        }

        func renderSubtitles(_ parts: [SubtitlePart]) {
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.renderSubtitles(parts) }
                return
            }
            subtitleOverlay.render(parts: parts)
            if subtitleOverlay.superview === self { bringSubviewToFront(subtitleOverlay) }
        }

        func clearSubtitles() {
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.clearSubtitles() }
                return
            }
            subtitleOverlay.clear()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyGeometryIfChanged()
        }

        private func applyGeometryIfChanged(force: Bool = false) {
            let geometryChanged = force || bounds != cachedBounds || frame != cachedFrame || safeAreaInsets != cachedSafeAreaInsets
            guard geometryChanged else { return }

            cachedBounds = bounds
            cachedFrame = frame
            cachedSafeAreaInsets = safeAreaInsets
            clipsToBounds = true

            guard let renderView = frozenRenderView else { return }
            if subtitleOverlay.frame != bounds { subtitleOverlay.frame = bounds }
            if renderView.transform != .identity { renderView.transform = .identity }
            if renderView.frame != bounds { renderView.frame = bounds }
            if renderView.autoresizingMask != [.flexibleWidth, .flexibleHeight] {
                renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
        }

        private func freezePlayerHierarchyOnce(in root: UIView) {
            guard !didFreezePlayerHierarchy else { return }
            didFreezePlayerHierarchy = true
            stripKSPlayerChromeOnce(in: root)
        }

        private func stripKSPlayerChromeOnce(in root: UIView) {
            for child in root.subviews {
                let className = String(describing: type(of: child)).lowercased()
                let isSubtitleRenderer = className.contains("subtitle") || className.contains("caption") || className.contains("textview")
                let isChrome = !isSubtitleRenderer && (child is UIControl || child is UIStackView || child is UIButton || className.contains("toolbar") || className.contains("control") || className.contains("button") || className.contains("slider") || className.contains("mask"))
                if isChrome {
                    child.isHidden = true
                    child.alpha = 0
                    child.isUserInteractionEnabled = false
                } else {
                    child.isUserInteractionEnabled = false
                    stripKSPlayerChromeOnce(in: child)
                }
            }
        }
    }

    final class PlaybackSurfaceAnchorView: UIView {
        let surface = KSContainerView()

        override var canBecomeFocused: Bool { false }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isUserInteractionEnabled = false
            clipsToBounds = true
            addSubview(surface)
            surface.frame = bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let host = subviews.first(where: { $0 is PlaybackPersistentRenderHostView }) {
                if host.frame != bounds { host.frame = bounds }
            } else if surface.superview === self, surface.frame != bounds {
                surface.frame = bounds
            }
        }
    }

    fileprivate struct UpdateSnapshot: Equatable {
        let url: URL
        let shouldPlay: Bool
        let playAssertionSerial: Int
        let seekSerial: Int
        let seekSeconds: Double
        let seekIsAbsolute: Bool
        let reloadToken: Int
        let startTimeSeconds: Double
        let externalAudioURL: URL?
        let externalAudioOffsetMS: Int
        let externalAudioTrackIndex: Int?
        let externalAudioHTTPHeaders: [String: String]
        let muteAudio: Bool
        let contentModeRawValue: Int
        let isLiveStream: Bool
        let playbackSessionID: UUID?
        let routeHint: String
        let enableDisplayMatch: Bool
        let displayMatchIsLive: Bool
        let selectedAudioTrackIndex: Int?
        let selectedSubtitleTrackIndex: Int?
        let selectedExternalSubtitleURL: URL?
        let subtitleDelayMS: Int
        let trackSelectionSerial: Int
        let audioGainDB: Double
    }

    private var updateSnapshot: UpdateSnapshot {
        UpdateSnapshot(
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
            contentModeRawValue: contentMode.rawValue,
            isLiveStream: isLiveStream,
            playbackSessionID: playbackSessionID,
            routeHint: routeHint,
            enableDisplayMatch: enableDisplayMatch,
            displayMatchIsLive: displayMatchIsLive,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            selectedExternalSubtitleURL: selectedExternalSubtitleURL,
            subtitleDelayMS: subtitleDelayMS,
            trackSelectionSerial: trackSelectionSerial,
            audioGainDB: audioGainDB
        )
    }

    // vBRDC160: true on-device Alternate Audio. The primary KSPlayer layer keeps the
    // original video URL; this second hidden KSPlayer layer opens the alternate full copy,
    // disables video decode, selects only the requested audio stream, and follows the
    // primary clock. No backend HLS bridge/remux is involved in playback.
    // vBRDC160: use KSMEPlayer directly for the hidden audio decoder instead of a
    // second KSPlayerLayer. KSPlayerLayer owns global Now Playing / remote-command state;
    // creating a second one would let Alternate Audio interfere with the primary player's
    // Bluetooth/remote controls. A direct KSMEPlayer gives us the FFmpeg demux/audio engine
    // without any second UI, PiP, Now Playing, or remote-control owner.
    final class LocalExternalAudioOptions: KSOptions {
        private let preferredAudioTrackIndex: Int?

        init(preferredAudioTrackIndex: Int?) {
            self.preferredAudioTrackIndex = preferredAudioTrackIndex
            super.init()
        }

        func chosenAudioIndex(in tracks: [MediaPlayerTrack]) -> Int? {
            guard !tracks.isEmpty else { return nil }
            if let preferredAudioTrackIndex {
                // AlternateAudioDiscovery reports ffprobe's absolute AVStream index.
                // KSPNUVIO exposes that same value as MediaPlayerTrack.trackID.
                if let exact = tracks.firstIndex(where: { Int($0.trackID) == preferredAudioTrackIndex }) {
                    return exact
                }
                // Compatibility with older discovery payloads that stored an audio-array
                // position rather than the container's absolute stream index.
                if tracks.indices.contains(preferredAudioTrackIndex) {
                    return preferredAudioTrackIndex
                }
            }
            if let english = tracks.firstIndex(where: {
                let language = ($0.languageCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let name = $0.name.lowercased()
                let taggedEnglish = language == "en" || language == "eng" || language.hasPrefix("en-") || language.hasPrefix("eng-") || language.hasPrefix("en_")
                return taggedEnglish || name.contains("english") || name == "eng" || name.hasPrefix("eng ")
            }) {
                return english
            }
            if let bestUntagged = tracks.firstIndex(where: {
                let value = [($0.languageCode ?? ""), $0.name].joined(separator: " ").lowercased()
                let commentary = value.contains("commentary") || value.contains("comment")
                let descriptive = value.contains("description") || value.contains("descriptive") || value.contains("visual impaired")
                return !commentary && !descriptive
            }) {
                return bestUntagged
            }
            return tracks.indices.first
        }

        override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
            chosenAudioIndex(in: tracks)
        }
    }

    @MainActor
    final class LocalExternalAudioController: NSObject, MediaPlayerDelegate {
        private(set) var player: KSMEPlayer?
        private var playerOptions: KSOptions?
        private(set) var currentSeconds: Double = 0
        private(set) var isReady = false
        private(set) var didPublishReady = false
        private var didFail = false
        private var seekInFlight = false
        private var didSelectTrack = false
        private var didAlignStart = false
        private var lastCorrectionHostTime: CFTimeInterval = 0
        private var targetMainSeconds: Double
        private var shouldPlay: Bool
        private var offsetMS: Int
        private var preferredTrackIndex: Int?
        private var audioGainDB: Double
        private let sourceURL: URL
        private let httpHeaders: [String: String]
        private let onReady: () -> Void
        private let onFailure: (String) -> Void

        init(sourceURL: URL, trackIndex: Int?, offsetMS: Int, httpHeaders: [String: String], mainSeconds: Double, shouldPlay: Bool, audioGainDB: Double, onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.sourceURL = sourceURL
            self.preferredTrackIndex = trackIndex
            self.offsetMS = offsetMS
            self.httpHeaders = httpHeaders
            self.targetMainSeconds = max(0, mainSeconds)
            self.shouldPlay = shouldPlay
            self.audioGainDB = audioGainDB
            self.onReady = onReady
            self.onFailure = onFailure
            super.init()
        }

        private var desiredAudioSeconds: Double {
            // Preserve bridge-era sync semantics: +250 ms means the alternate audio is
            // delayed by 250 ms, so its source clock should be 250 ms behind video.
            max(0, targetMainSeconds - Double(offsetMS) / 1000.0)
        }

        func start() {
            guard player == nil else { return }
            didFail = false
            didPublishReady = false
            isReady = false
            seekInFlight = false
            didSelectTrack = false
            didAlignStart = false
            currentSeconds = 0

            let options = LocalExternalAudioOptions(preferredAudioTrackIndex: preferredTrackIndex)
            options.videoDisable = true
            options.autoSelectEmbedSubtitle = false
            options.registerRemoteControll = false
            options.isSecondOpen = true
            options.isAccurateSeek = true
            options.isSeekedAutoPlay = true
            options.startPlayTime = desiredAudioSeconds
            options.preferredForwardBufferDuration = 2.0
            options.maxBufferDuration = 30.0
            options.userAgent = httpHeaders.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value ?? "DebridChannels-tvOS/160 AlternateAudio"
            if !httpHeaders.isEmpty { options.appendHeader(httpHeaders) }
            if audioGainDB > 0 { options.audioFilters = ["volume=\(Int(audioGainDB))dB"] }

            playerOptions = options
            let newPlayer = KSMEPlayer(url: sourceURL, options: options)
            newPlayer.delegate = self
            // Keep the secondary silent while it opens/seeks. The ready handoff mutes
            // primary audio first and only then exposes this decoder's audio output.
            newPlayer.playbackVolume = 0.0
            newPlayer.isMuted = false
            player = newPlayer
            newPlayer.prepareToPlay()
            // vBRDC171: KSMEPlayer's audio-only path can remain prepared-but-idle on
            // certain remote containers when no play assertion follows prepareToPlay().
            // Prime it muted so demux/audio output actually opens; primary audio is not
            // muted until publishReadyIfPossible confirms alignment and a playable track.
            newPlayer.play()
        }

        func update(mainSeconds: Double, offsetMS: Int, shouldPlay: Bool, audioGainDB: Double, forceSync: Bool = false) {
            targetMainSeconds = max(0, mainSeconds)
            let offsetChanged = self.offsetMS != offsetMS
            self.offsetMS = offsetMS
            let playChanged = self.shouldPlay != shouldPlay
            self.shouldPlay = shouldPlay
            let gainChanged = abs(self.audioGainDB - audioGainDB) > 0.01
            self.audioGainDB = audioGainDB
            if gainChanged {
                // KSME retains this exact KSOptions reference. Its MEFilter reads
                // audioFilters while decoding and rebuilds the audio filter graph without
                // replacing/reopening the secondary source.
                playerOptions?.audioFilters = audioGainDB > 0 ? ["volume=\(Int(audioGainDB))dB"] : []
            }
            if playChanged, isReady {
                if shouldPlay { player?.play() } else { player?.pause() }
            }
            if offsetChanged || forceSync { sync(force: true) }
        }

        func syncToMainClock(_ mainSeconds: Double, force: Bool = false) {
            guard mainSeconds.isFinite else { return }
            targetMainSeconds = max(0, mainSeconds)
            if let player, player.currentPlaybackTime.isFinite {
                currentSeconds = max(0, player.currentPlaybackTime)
            }
            sync(force: force)
        }

        private func sync(force: Bool) {
            guard isReady, !seekInFlight, let player else { return }
            if player.currentPlaybackTime.isFinite {
                currentSeconds = max(0, player.currentPlaybackTime)
            }
            let desired = desiredAudioSeconds
            let drift = currentSeconds - desired
            let now = CACurrentMediaTime()
            guard force || (abs(drift) > 0.40 && now - lastCorrectionHostTime >= 0.90) else { return }
            lastCorrectionHostTime = now
            seekInFlight = true
            player.seek(time: desired) { [weak self, weak player] finished in
                Task { @MainActor in
                    guard let self, let player, self.player === player else { return }
                    self.seekInFlight = false
                    if finished {
                        self.currentSeconds = desired
                    }
                    // KSOptions.startPlayTime was set before demux open. If a container
                    // temporarily reports seekable=false, starting here still begins from
                    // that target and normal drift correction verifies it on subsequent ticks.
                    self.didAlignStart = true
                    if self.shouldPlay { player.play() } else { player.pause() }
                    self.publishReadyIfPossible()
                }
            }
        }

        private func publishReadyIfPossible() {
            guard isReady,
                  didSelectTrack,
                  didAlignStart,
                  player?.loadState == .playable,
                  !didPublishReady,
                  !didFail else { return }
            didPublishReady = true
            // The callback synchronously mutes the primary player on MainActor. Unmute
            // the already-aligned secondary only after that handoff to prevent overlap.
            onReady()
            player?.playbackVolume = 1.0
            player?.isMuted = false
        }

        private func fail(_ message: String) {
            guard !didFail else { return }
            didFail = true
            if let player {
                player.pause()
                player.shutdown()
            }
            isReady = false
            seekInFlight = false
            onFailure(message)
        }

        // Return the shutdown decoder to the coordinator rather than destroying it while
        // the primary movie is still active. KSMEPlayer's deinit resets the shared audio
        // session's preferred channel count; retaining the inert decoder until primary
        // teardown prevents Restore Original Audio from unexpectedly collapsing the main
        // movie's multichannel/spatial route to stereo.
        func stopAndDetach() -> KSMEPlayer? {
            let old = player
            player = nil
            playerOptions = nil
            isReady = false
            seekInFlight = false
            didSelectTrack = false
            didAlignStart = false
            if let old {
                old.delegate = nil
                old.pause()
                old.shutdown()
            }
            return old
        }

        func readyToPlay(player candidate: some MediaPlayerProtocol) {
            guard let candidate = candidate as? KSMEPlayer, player === candidate else { return }
            let tracks = candidate.tracks(mediaType: .audio)
            guard !tracks.isEmpty else {
                fail("Selected alternate copy exposes no playable audio tracks")
                return
            }

            // KSME normally applies wantedAudio before decoder creation. Some containers
            // publish their track list only after readyToPlay, leaving every track disabled.
            // Select the same preferred/English/untagged fallback here as a second line of
            // defense instead of declaring the Apply action successful while output is silent.
            if !tracks.contains(where: { $0.isEnabled }) {
                guard let selector = playerOptions as? LocalExternalAudioOptions,
                      let selectedIndex = selector.chosenAudioIndex(in: tracks),
                      tracks.indices.contains(selectedIndex) else {
                    fail("No usable alternate audio track could be selected")
                    return
                }
                for (index, track) in tracks.enumerated() {
                    track.isEnabled = index == selectedIndex
                }
                // KSMEPlayer's audio track list is backed by the pinned fork's public
                // `FFmpegAssetTrack` concrete type. Swift 5 mode in Xcode 16.4 cannot pass
                // an `[any MediaPlayerTrack]` element to KSPlayer's opaque
                // `select(track: some MediaPlayerTrack)` parameter, even through a generic
                // helper. Cast back to the concrete KSME track before selecting so the
                // compiler and KSPlayer both see the real track type.
                guard let concreteTrack = tracks[selectedIndex] as? FFmpegAssetTrack else {
                    fail("Alternate audio track is not an FFmpeg track")
                    return
                }
                candidate.select(track: concreteTrack)
            }

            didSelectTrack = candidate.tracks(mediaType: .audio).contains(where: { $0.isEnabled })
            guard didSelectTrack else {
                fail("Alternate audio track selection did not become active")
                return
            }

            isReady = true
            let desired = desiredAudioSeconds
            if desired <= 0.20 {
                // startPlayTime already targets zero; do not make readiness depend on a
                // seek callback that some non-seekable/slow HTTP containers never deliver.
                didAlignStart = true
                seekInFlight = false
                if shouldPlay { candidate.play() } else { candidate.pause() }
                publishReadyIfPossible()
            } else {
                sync(force: true)
                let ownedPlayer = candidate
                Task { @MainActor [weak self, weak ownedPlayer] in
                    try? await Task.sleep(nanoseconds: 1_250_000_000)
                    guard let self, let ownedPlayer,
                          self.player === ownedPlayer,
                          self.isReady,
                          !self.didFail,
                          !self.didAlignStart else { return }
                    // KSOptions.startPlayTime was already set before open. If KSME's initial
                    // seek callback stalls, accept that start target and let the normal
                    // 400 ms drift watchdog issue a corrective seek on subsequent clock ticks.
                    self.seekInFlight = false
                    self.didAlignStart = true
                    if self.shouldPlay { ownedPlayer.play() } else { ownedPlayer.pause() }
                    self.publishReadyIfPossible()
                }
            }
        }

        func changeLoadState(player candidate: some MediaPlayerProtocol) {
            guard let candidate = candidate as? KSMEPlayer, player === candidate else { return }
            if candidate.currentPlaybackTime.isFinite {
                currentSeconds = max(0, candidate.currentPlaybackTime)
            }
            publishReadyIfPossible()
        }

        func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}
        func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

        func finish(player candidate: some MediaPlayerProtocol, error: Error?) {
            guard let candidate = candidate as? KSMEPlayer, player === candidate else { return }
            if let error { fail(error.localizedDescription) }
            else { fail("Alternate audio source ended before the primary video") }
        }
    }

    final class Coordinator: NSObject, KSPlayerLayerDelegate, PlaybackRenderSurfaceLifecycleOwner {
        var playerLayer: KSPlayerLayer?
        var currentURL: URL?
        // v1087: URL equality alone is not a playback identity. Reopening the same
        // resolved link must still create a clean clock/render generation for the new
        // VOD presentation instead of inheriting the departing session's coordinator.
        var currentPlaybackSessionID: UUID?
        var lastSeekSerial: Int = 0
        var lastReloadToken: Int = -1
        var currentStartTimeSeconds: Double = 0
        var currentExternalAudioURL: URL?
        var currentExternalAudioOffsetMS: Int = 0
        var currentExternalAudioTrackIndex: Int? = nil
        var currentExternalAudioHTTPHeaders: [String: String] = [:]
        var externalAudioController: LocalExternalAudioController? = nil
        // vBRDC160: keep shutdown secondary KSME players alive until the primary surface
        // tears down so their deinit cannot reset the shared multichannel audio route mid-movie.
        var retiredExternalAudioPlayers: [KSMEPlayer] = []
        var onExternalAudioReady: (() -> Void)? = nil
        var onExternalAudioFailure: ((String) -> Void)? = nil
        var currentMuteAudio: Bool = false
        var currentContentMode: UIView.ContentMode = .scaleAspectFit
        var currentShouldPlay: Bool? = nil
        var lastPlayAssertionSerial: Int = 0
        var currentDisplayMatchEnabled: Bool = false
        var currentDisplayMatchIsLive: Bool = false
        var currentPlaybackSeconds: Double = 0
        var currentDurationSeconds: Double = 0
        // v1056: trailer startup work is generation-scoped and stops as soon as the
        // real trailer clock advances. This prevents delayed startup nudges from
        // re-entering an already-playing audio pipeline or reviving an old trailer.
        var currentIsTrailerPlayback: Bool = false
        var currentIsLiveStream: Bool = false
        var currentAdaptiveCacheRouteHint: String = ""
        var currentAdaptiveCacheSourceSizeGB: Double? = nil
        var didRefineAdaptiveCacheFromDuration = false
        var didReceiveAdaptiveCacheMemoryPressure = false
        private var memoryWarningObserver: NSObjectProtocol?
        var trailerStartupGeneration: UInt64 = 0
        var trailerPlaybackHasAdvanced: Bool = false
        var didApplyEnglishAudioSelection: Bool = false
        var englishAudioSelectionScheduled: Bool = false
        var lastTrackSelectionSerial: Int = -1
        var selectedAudioTrackIndex: Int? = nil
        var selectedSubtitleTrackIndex: Int? = nil
        var selectedExternalSubtitleURL: URL? = nil
        var subtitleDelayMS: Int = 0
        var pendingExplicitTrackSelection: Bool = false
        // v1141 Phase 15 correction: retain the exact KSOptions object owned by the
        // active KSPNUVIO player. Its audio filter graph reads this object while decoding,
        // allowing VOD gain to change without recreating the player or seeking the stream.
        var activeOptions: KSOptions? = nil
        var currentAudioGainDB: Double = 0

        weak var subtitleSurface: KSContainerView?
        let subtitleModel = SubtitleModel()
        private var externalSubtitleInfo: PlaybackExternalSubtitleInfo?
        private var externalSubtitleLoadingURL: URL?
        var externalSubtitleLoadGeneration = 0
        var didAttachEmbeddedSubtitleDataSource = false
        var suppressClockUntil: CFTimeInterval = .greatestFiniteMagnitude
        var playbackStateReadyForClock = false
        // v920: once KSPlayer has reached its first ready state, transient state changes
        // must not permanently stop the real VOD clock. Only initial startup and an
        // explicit seek/track flush freeze time publication.
        var hasReachedInitialReadyForClock = false
        var explicitClockFreeze = true
        var clockReadyAfter: CFTimeInterval = .greatestFiniteMagnitude
        enum ClockFreezeReason: String {
            case startup
            case trackSelection
            case none
        }
        var clockFreezeReason: ClockFreezeReason = .startup
        var clockGateGeneration: UInt64 = 0
        var lastRawPlaybackSeconds: Double = -1
        var firstAdvancingClockHostTime: CFTimeInterval = 0
        var advancingClockSampleCount: Int = 0
        var appliedAudioTrackIndex: Int? = nil
        var appliedSubtitleTrackIndex: Int? = nil
        var appliedExternalSubtitleURL: URL? = nil
        var onPlaybackTimeUpdate: ((Double, Double) -> Void)? = nil
        var onBufferUpdate: ((Double, Double) -> Void)? = nil
        var onTracksDiscovered: (([RealMediaTrackOption], [RealMediaTrackOption]) -> Void)? = nil
        var onPlaybackFailure: ((String) -> Void)? = nil
        var onPlaybackEnded: (() -> Void)? = nil
        var onChaptersDiscovered: (([PlaybackChapterMarker]) -> Void)? = nil
        var onAudioFingerprintSample: ((PlaybackAudioFingerprintSample) -> Void)? = nil
        var lastPublishedChapterSignature: String = ""
        // Phase 11: prevent SwiftUI invalidations from repeatedly entering the active
        // KSPlayer configuration path when no playback command changed.
        fileprivate var lastAppliedUpdateSnapshot: UpdateSnapshot?
        // Phase 7: session-scoped lease for weak render-host registration.
        var renderSurfaceRegistrationEnabled = false
        let renderSurfaceID = UUID()
        var renderSurfaceRegistration: PlaybackRenderSurfaceRegistration?
        // v929 Phase B: KSPlayer may report time at render cadence. Keep the engine clock
        // current on every callback, but coalesce SwiftUI publication so the VOD screen is
        // not invalidated dozens of times per second while video frames are being presented.
        private var lastTimePublicationHostTime: CFTimeInterval = 0
        private var lastPublishedPlaybackSeconds: Double = -1
        private let minimumTimePublicationInterval: CFTimeInterval = 1.00
        // vBRDC062: buffer visualization is intentionally more responsive than the
        // one-second overlay clock, but still coalesced so it cannot invalidate SwiftUI
        // at render cadence while the FFmpeg reader is filling ahead in the background.
        private var lastBufferPublicationHostTime: CFTimeInterval = 0
        private var lastPublishedPlayableSeconds: Double = -1
        // vBRDC076 Playback Priority: buffer/cache-ahead is display telemetry only.
        // It must never compete with KSPNUVIO's CADisplayLink or VideoToolbox presentation.
        // A hard one-second gate is used even when playableTime jumps by several seconds;
        // the old `meaningfulAdvance || intervalElapsed` path could burst multiple MainActor/
        // SwiftUI publications while a fast debrid reader filled its packet queue.
        private let minimumBufferPublicationInterval: CFTimeInterval = 1.00

        // v957: VOD startup parity test. Normal startup now uses only a play assertion,
        // matching the smooth trailer path. A same-position seek is retained solely as a
        // delayed emergency fallback when the active VOD has neither presented a frame nor
        // advanced its real KSPlayer clock after the initial ready state.
        var firstFrameReleaseEligible = false
        var didEvaluateFirstFrameRelease = false
        var didPerformFirstFrameRelease = false
        var firstFrameRecoveryGeneration = 0
        // vBRDC084: an automatic-resume seek can land on the correct decoder clock yet
        // remain internally paused after KSPNUVIO's seek flush. This generation owns a
        // bounded post-seek play-liveness recovery and is invalidated by Pause/teardown.
        var postSeekAutoplayGeneration: UInt64 = 0

        private func layerTreeHasPresentedVideo(_ layer: CALayer) -> Bool {
            if layer.presentation() != nil, layer.contents != nil { return true }
            return layer.sublayers?.contains(where: { layerTreeHasPresentedVideo($0) }) ?? false
        }

        private func renderHostHasPresentedVideo(_ layer: KSPlayerLayer) -> Bool {
            guard let view = layer.player.view, view.window != nil, !view.isHidden, view.alpha > 0.001 else { return false }
            return layerTreeHasPresentedVideo(view.layer)
        }

        private func evaluateFirstFrameReleaseIfNeeded(_ layer: KSPlayerLayer) {
            guard firstFrameReleaseEligible,
                  !didEvaluateFirstFrameRelease,
                  playerLayer === layer else { return }
            didEvaluateFirstFrameRelease = true

            let resumePlayback = currentShouldPlay ?? true
            let baselinePlaybackSeconds = currentPlaybackSeconds
            firstFrameRecoveryGeneration += 1
            let recoveryGeneration = firstFrameRecoveryGeneration

            // v957 normal path: do not seek during startup. Re-assert the requested play
            // state on the existing layer, matching the smooth trailer behavior without
            // creating a second player or touching the decoder configuration.
            if resumePlayback {
                layer.play()
            } else {
                layer.pause()
            }

            // One delayed, non-polling safety check preserves the old manual-forward rescue.
            // The same-position seek runs only when playback was requested, no rendered frame
            // exists, and the real KSPlayer clock has not advanced meaningfully since ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self, weak layer] in
                guard let self, let layer, self.playerLayer === layer,
                      self.firstFrameReleaseEligible,
                      self.firstFrameRecoveryGeneration == recoveryGeneration,
                      !self.didPerformFirstFrameRelease,
                      self.currentShouldPlay ?? true else { return }

                if self.renderHostHasPresentedVideo(layer) {
                    print("[KSPlayer][v957] VOD first frame presented after play assertion; emergency seek not required")
                    return
                }

                let clockAdvanced = self.currentPlaybackSeconds >= baselinePlaybackSeconds + 0.25
                guard !clockAdvanced else {
                    print("[KSPlayer][v957] VOD clock advanced after play assertion; emergency seek not required")
                    return
                }

                self.didPerformFirstFrameRelease = true
                let releaseTime = max(0, max(self.currentStartTimeSeconds, self.currentPlaybackSeconds))
                layer.seek(time: releaseTime, autoPlay: true) { [weak self, weak layer] finished in
                    guard let self, let layer, self.playerLayer === layer else { return }

                    // This is an emergency startup recovery only. Re-arm the existing clock
                    // gate so a stream that needed the rescue cannot remain frozen at 0:00.
                    self.releaseClockGate(after: 0.12, reason: "emergency first-frame seek completion")
                    print("[KSPlayer][v957] emergency first-frame seek finished=\(finished) at \(releaseTime)s")
                }
            }
        }

        override init() {
            super.init()
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyEmergencyVODMemoryClamp()
            }
        }

        deinit {
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
            }
        }

        private func applyEmergencyVODMemoryClamp() {
            guard !currentIsLiveStream, !currentIsTrailerPlayback, let options = activeOptions else { return }
            didReceiveAdaptiveCacheMemoryPressure = true
            // A real tvOS memory warning outranks the startup planner. Shrink the active
            // compressed-packet ceiling immediately, but keep enough headroom above the
            // rebuffer threshold so KSPlayer cannot deadlock waiting for an unreachable
            // 100%-full buffer. A new playback session recalculates the full adaptive plan.
            let preferred = max(3, options.preferredForwardBufferDuration)
            let emergencyMax = max(preferred + 6, min(options.maxBufferDuration, 30))
            if emergencyMax < options.maxBufferDuration {
                options.maxBufferDuration = emergencyMax
                print("[PlaybackKit][vBRDC168] memory warning: active VOD max buffer clamped to \(Int(emergencyMax))s (preferred \(Int(preferred))s)")
            }
        }

        private func refineAdaptiveVODCacheIfPossible(totalTime: TimeInterval) {
            guard !didRefineAdaptiveCacheFromDuration,
                  !didReceiveAdaptiveCacheMemoryPressure,
                  !currentIsLiveStream,
                  !currentIsTrailerPlayback else { return }
            guard totalTime.isFinite, totalTime > 0 else { return }
            guard totalTime >= 300, totalTime <= 28_800 else {
                didRefineAdaptiveCacheFromDuration = true
                return
            }
            guard let sourceSizeGB = currentAdaptiveCacheSourceSizeGB,
                  let url = currentURL,
                  let options = activeOptions else {
                didRefineAdaptiveCacheFromDuration = true
                return
            }

            didRefineAdaptiveCacheFromDuration = true
            let refined = AdaptiveVODCachePlanner.profile(
                routeHint: currentAdaptiveCacheRouteHint,
                url: url,
                sourceSizeGB: sourceSizeGB,
                knownDurationSeconds: totalTime
            )
            options.preferredForwardBufferDuration = refined.preferredBufferDuration
            options.maxBufferDuration = refined.maxBufferDuration
            print("[PlaybackKit][vBRDC168] duration-refined adaptive cache {\(refined.diagnostic)} duration=\(Int(totalTime))s")
        }

        func playbackKitStopAndReleaseSurface() {
            clockGateGeneration &+= 1
            postSeekAutoplayGeneration &+= 1
            resetSubtitleBridge()
            if let retired = externalAudioController?.stopAndDetach() {
                retiredExternalAudioPlayers.append(retired)
            }
            externalAudioController = nil
            playerLayer?.pause()
            playerLayer?.stop()
            // KSPlayerLayer in the pinned KSPlayer package does not expose a backing `view`.
            // The session-owned persistent host releases the mounted UIView hierarchy separately.
            playerLayer = nil
            // The primary engine is stopped now, so releasing retired audio-only decoders
            // can no longer alter an active movie's AVAudioSession channel preference.
            retiredExternalAudioPlayers.removeAll()
            activeOptions = nil
            currentAudioGainDB = 0
            currentAdaptiveCacheRouteHint = ""
            currentAdaptiveCacheSourceSizeGB = nil
            didRefineAdaptiveCacheFromDuration = false
            didReceiveAdaptiveCacheMemoryPressure = false
            currentURL = nil
            currentPlaybackSessionID = nil
            #if os(tvOS)
            if currentDisplayMatchEnabled, #available(tvOS 11.2, *) {
                DebridTVOSDisplayMatchCoordinator.reset()
            }
            #endif
        }

        private func finiteDuration(_ value: TimeInterval) -> Double? {
            guard value.isFinite, value > 0 else { return nil }
            return value
        }

        func resetClockGateForNewSource(startTime: Double) {
            clockGateGeneration &+= 1
            clockFreezeReason = .startup
            currentPlaybackSeconds = max(0, startTime)
            currentDurationSeconds = 0
            playbackStateReadyForClock = false
            hasReachedInitialReadyForClock = false
            explicitClockFreeze = true
            suppressClockUntil = .greatestFiniteMagnitude
            clockReadyAfter = .greatestFiniteMagnitude
            lastRawPlaybackSeconds = -1
            firstAdvancingClockHostTime = 0
            advancingClockSampleCount = 0
            lastTimePublicationHostTime = 0
            lastPublishedPlaybackSeconds = -1
            lastBufferPublicationHostTime = 0
            lastPublishedPlayableSeconds = -1
        }

        private func armClockFreeze(_ reason: ClockFreezeReason, resetRawEvidence: Bool) -> UInt64 {
            clockGateGeneration &+= 1
            clockFreezeReason = reason
            playbackStateReadyForClock = false
            explicitClockFreeze = true
            suppressClockUntil = .greatestFiniteMagnitude
            clockReadyAfter = .greatestFiniteMagnitude
            if resetRawEvidence {
                lastRawPlaybackSeconds = -1
                firstAdvancingClockHostTime = 0
                advancingClockSampleCount = 0
            }
            return clockGateGeneration
        }

        private func releaseClockGate(after delay: CFTimeInterval, reason: String) {
            hasReachedInitialReadyForClock = true
            playbackStateReadyForClock = true
            explicitClockFreeze = false
            clockFreezeReason = .none
            clockReadyAfter = CACurrentMediaTime() + max(0, delay)
            suppressClockUntil = clockReadyAfter
            print("[PlaybackClock][v1087] released gate reason=\(reason) delay=\(delay)")
        }

        private func recordRawClockEvidence(layer: KSPlayerLayer, currentTime: TimeInterval) {
            guard currentTime.isFinite, currentTime >= 0 else { return }
            let now = CACurrentMediaTime()
            if lastRawPlaybackSeconds >= 0 {
                let delta = currentTime - lastRawPlaybackSeconds
                if delta > 0.015 {
                    if advancingClockSampleCount == 0 { firstAdvancingClockHostTime = now }
                    advancingClockSampleCount += 1
                } else if delta < -0.35 {
                    advancingClockSampleCount = 0
                    firstAdvancingClockHostTime = 0
                }
            }
            lastRawPlaybackSeconds = currentTime

            guard explicitClockFreeze else { return }
            let advancedFromStart = currentTime >= max(0, currentStartTimeSeconds) + 0.20
            let sustainedAdvance = advancingClockSampleCount >= 2
                && firstAdvancingClockHostTime > 0
                && now - firstAdvancingClockHostTime >= 0.08
            guard advancedFromStart, sustainedAdvance else { return }

            // KSPNUVIO can omit a second readyToPlay callback after an in-place reload,
            // source replacement, or decoder flush even though decoded playback has resumed.
            // Prefer visible-render evidence, but after several monotonic player-clock samples
            // allow the real engine clock to recover rather than freezing the overlay forever.
            let renderedVideo = renderHostHasPresentedVideo(layer)
            let strongClockEvidence = advancingClockSampleCount >= 4
            guard renderedVideo || strongClockEvidence else { return }
            releaseClockGate(after: 0.08, reason: renderedVideo ? "rendered frame + advancing player clock" : "sustained advancing player clock fallback")
        }

        private func publishPlaybackTime(force: Bool = false) {
            let now = CACurrentMediaTime()
            let meaningfulJump = lastPublishedPlaybackSeconds < 0 || abs(currentPlaybackSeconds - lastPublishedPlaybackSeconds) >= 2.0
            guard force || meaningfulJump || now - lastTimePublicationHostTime >= minimumTimePublicationInterval else { return }
            lastTimePublicationHostTime = now
            lastPublishedPlaybackSeconds = currentPlaybackSeconds
            onPlaybackTimeUpdate?(currentPlaybackSeconds, currentDurationSeconds)
        }

        private func publishBufferState(_ layer: KSPlayerLayer, force: Bool = false) {
            guard playerLayer === layer else { return }
            let rawPlayable = layer.player.playableTime
            guard rawPlayable.isFinite, rawPlayable >= 0 else { return }
            let total = currentDurationSeconds > 0 ? currentDurationSeconds : max(0, layer.player.duration)
            let playable = total > 0 ? min(max(rawPlayable, currentPlaybackSeconds), total) : max(rawPlayable, currentPlaybackSeconds)
            let now = CACurrentMediaTime()
            let meaningfulAdvance = lastPublishedPlayableSeconds < 0 || abs(playable - lastPublishedPlayableSeconds) >= 1.50
            let intervalElapsed = now - lastBufferPublicationHostTime >= minimumBufferPublicationInterval
            guard force || (intervalElapsed && meaningfulAdvance) else { return }
            lastBufferPublicationHostTime = now
            lastPublishedPlayableSeconds = playable
            onBufferUpdate?(playable, total)
        }

        func resetSubtitleBridge() {
            externalSubtitleLoadGeneration &+= 1
            externalSubtitleInfo = nil
            externalSubtitleLoadingURL = nil
            didAttachEmbeddedSubtitleDataSource = false
            subtitleModel.selectedSubtitleInfo = nil
            subtitleSurface?.clearSubtitles()
        }

        private func attachEmbeddedSubtitleDataSourceIfAvailable(_ layer: KSPlayerLayer) {
            guard !didAttachEmbeddedSubtitleDataSource,
                  let dataSource = layer.player.subtitleDataSouce else { return }
            subtitleModel.addSubtitle(dataSouce: dataSource)
            didAttachEmbeddedSubtitleDataSource = true
            print("[PlaybackKit][v998] attached KSPlayer embedded subtitle data source")
        }

        private func disableEmbeddedSubtitleTracks(_ layer: KSPlayerLayer) {
            for track in layer.player.tracks(mediaType: .subtitle) {
                track.isEnabled = false
            }
        }

        private func disableSubtitles(_ layer: KSPlayerLayer) {
            externalSubtitleLoadGeneration &+= 1
            externalSubtitleInfo = nil
            externalSubtitleLoadingURL = nil
            disableEmbeddedSubtitleTracks(layer)
            subtitleModel.selectedSubtitleInfo = nil
            subtitleSurface?.clearSubtitles()
            print("[PlaybackKit][v998] subtitles disabled and visible cue cleared")
        }

        private func selectExternalSubtitle(_ url: URL, on layer: KSPlayerLayer) {
            if externalSubtitleInfo?.url == url,
               (externalSubtitleLoadingURL == url ||
                subtitleModel.selectedSubtitleInfo?.subtitleID == externalSubtitleInfo?.subtitleID) {
                return
            }

            disableEmbeddedSubtitleTracks(layer)
            subtitleModel.selectedSubtitleInfo = nil
            subtitleSurface?.clearSubtitles()
            externalSubtitleLoadGeneration &+= 1
            let generation = externalSubtitleLoadGeneration
            let info = PlaybackExternalSubtitleInfo(url: url)
            externalSubtitleInfo = info
            externalSubtitleLoadingURL = url

            Task { @MainActor [weak self, weak layer] in
                do {
                    try await info.load()
                    guard let self, let layer,
                          self.playerLayer === layer,
                          self.externalSubtitleLoadGeneration == generation,
                          self.selectedExternalSubtitleURL == url else { return }
                    self.externalSubtitleLoadingURL = nil
                    self.subtitleModel.addSubtitle(info: info)
                    self.subtitleModel.selectedSubtitleInfo = info
                    self.subtitleSurface?.clearSubtitles()
                    print("[PlaybackKit][v998] external subtitle loaded: \(info.name)")
                } catch {
                    guard let self, self.externalSubtitleLoadGeneration == generation else { return }
                    self.externalSubtitleInfo = nil
                    self.externalSubtitleLoadingURL = nil
                    self.subtitleModel.selectedSubtitleInfo = nil
                    self.subtitleSurface?.clearSubtitles()
                    print("[PlaybackKit][v998] external subtitle load failed: \(error.localizedDescription)")
                }
            }
        }

        private func selectEmbeddedSubtitle(index: Int, on layer: KSPlayerLayer) -> Bool {
            let tracks = layer.player.tracks(mediaType: .subtitle)
            guard tracks.indices.contains(index) else { return false }

            externalSubtitleLoadGeneration &+= 1
            externalSubtitleInfo = nil
            externalSubtitleLoadingURL = nil
            attachEmbeddedSubtitleDataSourceIfAvailable(layer)

            let track = tracks[index]
            if let subtitleInfo = track as? any SubtitleInfo,
               track.isEnabled,
               subtitleModel.selectedSubtitleInfo?.subtitleID == subtitleInfo.subtitleID {
                return true
            }
            disableEmbeddedSubtitleTracks(layer)
            track.isEnabled = true
            selectOpenedKSPlayerTrack(track, on: layer)
            if let subtitleInfo = track as? any SubtitleInfo {
                subtitleModel.addSubtitle(info: subtitleInfo)
                subtitleModel.selectedSubtitleInfo = subtitleInfo
                subtitleSurface?.clearSubtitles()
                print("[PlaybackKit][v998] selected embedded subtitle index \(index): \(track.name)")
                return true
            }

            // Keep the player track selected even if a future KSPlayer revision stops
            // exposing SubtitleInfo, but do not claim that rendering is connected.
            subtitleModel.selectedSubtitleInfo = nil
            subtitleSurface?.clearSubtitles()
            print("[PlaybackKit][v998] selected subtitle track lacks SubtitleInfo bridge: \(track.name)")
            return false
        }

        private func refreshSubtitleBridge(_ layer: KSPlayerLayer) {
            guard playerLayer === layer else { return }
            attachEmbeddedSubtitleDataSourceIfAvailable(layer)
            if let externalURL = selectedExternalSubtitleURL {
                selectExternalSubtitle(externalURL, on: layer)
            } else if let subtitleIndex = selectedSubtitleTrackIndex {
                _ = selectEmbeddedSubtitle(index: subtitleIndex, on: layer)
            } else {
                disableSubtitles(layer)
            }
        }

        private func scheduleSubtitleBridgeRefresh(_ layer: KSPlayerLayer) {
            let generation = firstFrameRecoveryGeneration
            for delay in [0.15, 0.75, 1.40] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak layer] in
                    guard let self, let layer,
                          self.playerLayer === layer,
                          self.firstFrameRecoveryGeneration == generation else { return }
                    self.refreshSubtitleBridge(layer)
                }
            }
        }

        private func renderSubtitleCue(at currentTime: TimeInterval) {
            guard selectedSubtitleTrackIndex != nil || selectedExternalSubtitleURL != nil else {
                subtitleSurface?.clearSubtitles()
                return
            }
            let shiftedTime = max(0, currentTime - TimeInterval(subtitleDelayMS) / 1000.0)
            if subtitleModel.subtitle(currentTime: shiftedTime) {
                subtitleSurface?.renderSubtitles(subtitleModel.parts)
            }
        }

        private func publishChaptersIfNeeded(_ layer: KSPlayerLayer) {
            guard playerLayer === layer else { return }
            let mapped = layer.player.chapters.compactMap { chapter -> PlaybackChapterMarker? in
                guard chapter.start.isFinite, chapter.end.isFinite, chapter.end > chapter.start else { return nil }
                return PlaybackChapterMarker(
                    startSeconds: max(0, chapter.start),
                    endSeconds: chapter.end,
                    title: chapter.title
                )
            }
            guard !mapped.isEmpty else { return }
            let signature = mapped.map { "\(Int($0.startSeconds * 1000))|\(Int($0.endSeconds * 1000))|\($0.title)" }.joined(separator: ";")
            guard signature != lastPublishedChapterSignature else { return }
            lastPublishedChapterSignature = signature
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playerLayer === layer else { return }
                self.onChaptersDiscovered?(mapped)
            }
        }

        func player(layer: KSPlayerLayer, state: KSPlayerState) {
            // KSPlayer can deliver a final queued state callback after stop(). Ignore it
            // once a replacement layer owns this coordinator; otherwise link A can release
            // link B's clock gate or reapply link A's tracks.
            guard playerLayer === layer else { return }
            if let duration = finiteDuration(layer.player.duration) {
                currentDurationSeconds = max(currentDurationSeconds, duration)
            }
            let stateCanReleaseClock = state == .readyToPlay || state == .bufferFinished
            if stateCanReleaseClock {
                // vBRDC043: chapters are read directly from the active KSPNUVIO player.
                // This is local metadata only and replaces the backend ffprobe intro probe.
                publishChaptersIfNeeded(layer)
                // readyToPlay can arrive before the first decoded video frame is visible.
                // Hold briefly on initial startup/explicit flush, then release the real clock.
                let delay: CFTimeInterval = hasReachedInitialReadyForClock ? 0.12 : 0.45
                releaseClockGate(after: delay, reason: state == .readyToPlay ? "KSPlayer readyToPlay" : "KSPlayer bufferFinished")
            }
            publishPlaybackTime(force: true)
            // v764 safety: only attempt track selection on the explicit ready state, never on
            // generic "play"/buffer states that can fire before KSPlayer exposes stable tracks.
            if state == .readyToPlay {
                evaluateFirstFrameReleaseIfNeeded(layer)
                publishDiscoveredTracks(layer)
                scheduleEnglishAudioTrackSelection(layer)
                if pendingExplicitTrackSelection {
                    applySelectedTracksIfNeeded(layer, force: true, flushAfterSelection: true)
                } else {
                    applySelectedTracksIfNeeded(layer, force: true)
                }
                scheduleSubtitleBridgeRefresh(layer)
            }
        }

        func scheduleEnglishAudioTrackSelection(_ layer: KSPlayerLayer) {
            // Trailer files are already backend-muxed. Re-selecting their default audio
            // track after playback starts can flush or detach the only audio stream.
            guard !currentIsTrailerPlayback,
                  !didApplyEnglishAudioSelection,
                  !englishAudioSelectionScheduled else { return }
            englishAudioSelectionScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self, weak layer] in
                guard let self else { return }
                self.englishAudioSelectionScheduled = false
                guard let layer, self.playerLayer === layer else { return }
                if self.applyEnglishAudioTrackIfAvailable(layer) {
                    self.didApplyEnglishAudioSelection = true
                }
            }
        }

        @discardableResult
        func applyEnglishAudioTrackIfAvailable(_ layer: KSPlayerLayer) -> Bool {
            let audioTracks = layer.player.tracks(mediaType: .audio)
            guard !audioTracks.isEmpty else { return false }
            let englishCodes: Set<String> = ["en", "eng", "en-us", "en-gb", "english"]
            guard let english = audioTracks.first(where: { track in
                let lang = (track.languageCode ?? track.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return englishCodes.contains(lang) || lang.hasPrefix("en") || lang.contains("eng") || name.contains("english") || name.contains(" eng") || name == "eng" || name.contains("en-us") || name.contains("en-gb")
            }) else { return false }
            guard let index = audioTracks.firstIndex(where: {
                $0.name == english.name && ($0.languageCode ?? $0.language ?? "") == (english.languageCode ?? english.language ?? "")
            }) else {
                layer.player.select(track: english)
                print("[KSPlayer] selected English audio track: \(english.name)")
                return true
            }
            if appliedAudioTrackIndex == index {
                return true
            }
            layer.player.select(track: english)
            appliedAudioTrackIndex = index
            print("[KSPlayer] selected English audio track: \(english.name)")
            return true
        }

        func publishDiscoveredTracks(_ layer: KSPlayerLayer) {
            let audio = layer.player.tracks(mediaType: .audio).enumerated().map { index, track in
                makeRealTrackOption(track: track, index: index, kind: "Audio")
            }
            let subtitles = layer.player.tracks(mediaType: .subtitle).enumerated().map { index, track in
                makeRealTrackOption(track: track, index: index, kind: "Subtitle")
            }
            if !audio.isEmpty || !subtitles.isEmpty {
                DispatchQueue.main.async { [weak self, weak layer] in
                    guard let self, let layer, self.playerLayer === layer else { return }
                    self.onTracksDiscovered?(audio, subtitles)
                }
            }
        }

        func makeRealTrackOption(track: Any, index: Int, kind: String) -> RealMediaTrackOption {
            let mirror = Mirror(reflecting: track)
            func value(_ names: [String]) -> String? {
                for child in mirror.children {
                    guard let label = child.label, names.contains(label) else { continue }
                    if let v = child.value as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
                    if let v = child.value as? String?, let text = v, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                }
                return nil
            }
            let name = value(["name", "title"]) ?? "\(kind) \(index + 1)"
            let language = value(["languageCode", "language", "locale"]) ?? name
            return RealMediaTrackOption(
                id: "ks-\(kind.lowercased())-\(index)-\(language)-\(name)",
                optionIndex: index,
                label: name,
                languageName: MediaTrackLanguageNormalizer.displayName(code: language, fallback: name),
                codecOrFormat: value(["codec", "codecName", "format"]),
                isDefault: name.lowercased().contains("default"),
                isForced: name.lowercased().contains("forced"),
                isSDH: name.lowercased().contains("sdh")
            )
        }

        func selectOpenedKSPlayerTrack<Track: MediaPlayerTrack>(_ track: Track, on layer: KSPlayerLayer) {
            layer.player.select(track: track)
        }

        @discardableResult
        func applySelectedTracksIfNeeded(_ layer: KSPlayerLayer, force: Bool = false, flushAfterSelection: Bool = false) -> Bool {
            var changedAudioTrack = false
            var changedSubtitleTrack = false

            if let audioIndex = selectedAudioTrackIndex {
                let tracks = layer.player.tracks(mediaType: .audio)
                if tracks.indices.contains(audioIndex), appliedAudioTrackIndex != audioIndex {
                    let track = tracks[audioIndex]
                    selectOpenedKSPlayerTrack(track, on: layer)
                    appliedAudioTrackIndex = audioIndex
                    didApplyEnglishAudioSelection = true
                    changedAudioTrack = true
                    print("[KSPlayer] selected audio track index \(audioIndex): \(track.name)")
                }
            }

            if let externalURL = selectedExternalSubtitleURL {
                if appliedExternalSubtitleURL != externalURL {
                    selectExternalSubtitle(externalURL, on: layer)
                    appliedExternalSubtitleURL = externalURL
                    appliedSubtitleTrackIndex = nil
                    changedSubtitleTrack = true
                }
            } else if let subtitleIndex = selectedSubtitleTrackIndex {
                if appliedSubtitleTrackIndex != subtitleIndex {
                    changedSubtitleTrack = selectEmbeddedSubtitle(index: subtitleIndex, on: layer)
                    if changedSubtitleTrack {
                        appliedSubtitleTrackIndex = subtitleIndex
                        appliedExternalSubtitleURL = nil
                    }
                }
            } else if force {
                disableSubtitles(layer)
                appliedSubtitleTrackIndex = nil
                appliedExternalSubtitleURL = nil
            }

            // Audio decoder changes can retain buffered audio packets, so preserve the
            // existing one-shot same-position flush for explicit audio selection only.
            // Subtitle selection is connected directly to SubtitleModel and must never
            // seek/restart the video or clear the newly selected subtitle queue.
            if flushAfterSelection && changedAudioTrack {
                pendingExplicitTrackSelection = false
                let resumePlayback = currentShouldPlay ?? true
                let flushTime = max(0, currentPlaybackSeconds)
                let freezeGeneration = armClockFreeze(.trackSelection, resetRawEvidence: true)
                layer.seek(time: flushTime, autoPlay: false) { [weak self, weak layer] finished in
                    guard let self, let layer, self.playerLayer === layer,
                          self.clockGateGeneration == freezeGeneration else { return }
                    if resumePlayback { layer.play() } else { layer.pause() }
                    self.releaseClockGate(after: 0.12, reason: "explicit audio-track seek completion")
                    self.publishPlaybackTime(force: true)
                    print("[KSPlayer] active-player audio flush finished=\(finished) at \(flushTime)s resume=\(resumePlayback)")
                }
                // Some FFmpeg-backed sources complete the seek internally but omit the
                // completion callback. Never let that leave the timeline frozen forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.80) { [weak self, weak layer] in
                    guard let self, let layer, self.playerLayer === layer,
                          self.clockGateGeneration == freezeGeneration,
                          self.explicitClockFreeze,
                          self.clockFreezeReason == .trackSelection else { return }
                    if resumePlayback { layer.play() } else { layer.pause() }
                    self.releaseClockGate(after: 0.08, reason: "audio-track flush timeout recovery")
                    self.publishPlaybackTime(force: true)
                }
            } else if flushAfterSelection {
                pendingExplicitTrackSelection = false
            }

            return changedAudioTrack || changedSubtitleTrack
        }

        func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
            // A stopped FFmpeg layer may drain one or more queued time callbacks. Never
            // publish those samples into the replacement source's session clock.
            guard playerLayer === layer else { return }
            refineAdaptiveVODCacheIfPossible(totalTime: totalTime)
            if let duration = finiteDuration(totalTime) {
                currentDurationSeconds = max(currentDurationSeconds, duration)
            }
            if currentIsTrailerPlayback, currentTime > 0.25 {
                trailerPlaybackHasAdvanced = true
            }
            // Some containers expose chapters only after demuxing has advanced beyond the
            // initial ready callback. Retry locally until a non-empty chapter set publishes.
            if lastPublishedChapterSignature.isEmpty { publishChaptersIfNeeded(layer) }
            // Subtitle timing follows the engine's exact current-time callback, not the
            // one-second SwiftUI overlay publication cadence.
            renderSubtitleCue(at: currentTime)
            // FFPlayer can advance its demux clock during initial buffering and immediately
            // after seek/track decoder flushes, before video output resumes. Keep duration
            // metadata flowing, but freeze the user-visible current/remaining time in that gap.
            // Do not require KSPlayer to remain in .readyToPlay forever. Some streams
            // transition through buffering/playing-style states after startup and never send
            // another ready callback, which previously froze the progress bar at 0:00.
            recordRawClockEvidence(layer: layer, currentTime: currentTime)
            guard hasReachedInitialReadyForClock,
                  !explicitClockFreeze,
                  CACurrentMediaTime() >= suppressClockUntil,
                  CACurrentMediaTime() >= clockReadyAfter else {
                publishPlaybackTime()
                return
            }
            if currentTime.isFinite {
                currentPlaybackSeconds = max(0, currentTime)
                externalAudioController?.syncToMainClock(currentPlaybackSeconds)
            }
            publishPlaybackTime()
            publishBufferState(layer)
        }

        func player(layer: KSPlayerLayer, finish error: Error?) {
            guard playerLayer === layer else { return }
            if let error {
                let message = error.localizedDescription
                print("[KSPlayer] playback finished with error: \(message)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playerLayer === layer else { return }
                    self.onPlaybackFailure?(message)
                }
            } else {
                // vBRDC043: natural episode completion is an app-side authoritative Up Next trigger.
                // KSPlayer can stop publishing clock changes at exactly duration, so do not
                // require a Siri Remote movement to make SwiftUI re-evaluate the overlay.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playerLayer === layer else { return }
                    self.onPlaybackEnded?()
                }
            }
        }

        func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
            guard playerLayer === layer else { return }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlaybackSurfaceAnchorView {
        let anchor = PlaybackSurfaceAnchorView()
        let view = anchor.surface
        context.coordinator.renderSurfaceRegistrationEnabled = !isLiveStream && playbackSessionID != nil
        context.coordinator.subtitleSurface = view
        context.coordinator.onPlaybackTimeUpdate = onPlaybackTimeUpdate
        context.coordinator.onBufferUpdate = onBufferUpdate
        context.coordinator.onTracksDiscovered = onTracksDiscovered
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onExternalAudioReady = onExternalAudioReady
        context.coordinator.onExternalAudioFailure = onExternalAudioFailure
        context.coordinator.onChaptersDiscovered = onChaptersDiscovered
        context.coordinator.onAudioFingerprintSample = onAudioFingerprintSample
        context.coordinator.lastAppliedUpdateSnapshot = updateSnapshot
        configure(view: view, coordinator: context.coordinator)
        if context.coordinator.renderSurfaceRegistrationEnabled,
           let playbackSessionID {
            // Registration is explicitly tied to the VOD launch UUID. A surface from link A
            // can never be adopted by link B, even when makeUIView precedes onAppear.
            context.coordinator.renderSurfaceRegistration = PlaybackController.shared.registerRenderSurfaceCandidate(
                view,
                surfaceID: context.coordinator.renderSurfaceID,
                sessionID: playbackSessionID,
                lifecycleOwner: context.coordinator
            )
        }
        return anchor
    }

    func updateUIView(_ anchor: PlaybackSurfaceAnchorView, context: Context) {
        // Callback closures may be recreated by SwiftUI even when their behavior is the same.
        // Refresh them without touching KSPlayer, then compare only stable playback inputs.
        context.coordinator.onPlaybackTimeUpdate = onPlaybackTimeUpdate
        context.coordinator.onBufferUpdate = onBufferUpdate
        context.coordinator.onTracksDiscovered = onTracksDiscovered
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onExternalAudioReady = onExternalAudioReady
        context.coordinator.onExternalAudioFailure = onExternalAudioFailure
        context.coordinator.onChaptersDiscovered = onChaptersDiscovered
        context.coordinator.onAudioFingerprintSample = onAudioFingerprintSample
        context.coordinator.subtitleSurface = anchor.surface
        let snapshot = updateSnapshot
        guard context.coordinator.lastAppliedUpdateSnapshot != snapshot else { return }
        context.coordinator.lastAppliedUpdateSnapshot = snapshot
        configure(view: anchor.surface, coordinator: context.coordinator)
    }

    private var sanitizedPlaybackHTTPHeaders: [String: String] {
        guard !isLiveStream, !httpHeaders.isEmpty else { return [:] }
        let blocked = Set(["host", "content-length", "transfer-encoding", "range", "content-range"])
        var result: [String: String] = [:]
        for (rawName, rawValue) in httpHeaders.prefix(64) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard !name.isEmpty, name.count <= 128, !blocked.contains(lower),
                  !value.isEmpty, value.utf8.count <= 8192,
                  !name.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f || $0.value == 58 }),
                  !value.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else { continue }
            result[name] = value
        }
        return result
    }

    private func mergedPlaybackHeaders(defaultUserAgent: String) -> [String: String] {
        var result: [String: String] = [
            "User-Agent": defaultUserAgent,
            "Accept": "*/*",
            "Connection": "keep-alive"
        ]
        for (name, value) in sanitizedPlaybackHTTPHeaders {
            if let existing = result.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                result.removeValue(forKey: existing)
            }
            result[name] = value
        }
        return result
    }

    private var normalizedVODAudioGainDB: Double {
        guard !isLiveStream else { return 0 }
        return [0.0, 3.0, 6.0, 9.0, 12.0].min(by: {
            abs($0 - audioGainDB) < abs($1 - audioGainDB)
        }) ?? 0
    }

    // vBRDC069: Source Intelligence already carries the selected source size in the
    // playback route label. Parse that local metadata before creating KSPNUVIO so large
    // debrid files do not receive the same five-minute in-memory packet reserve as small
    // WEB files. This performs no network request and does not inspect the media body.
    private func inferredVODSourceSizeGB(from value: String) -> Double? {
        let pattern = #"(\d+(?:[\.,]\d+)?)\s*(gb|gib|mb|mib)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: range)
        let values = matches.compactMap { match -> Double? in
            guard match.numberOfRanges >= 3,
                  let numberRange = Range(match.range(at: 1), in: value),
                  let unitRange = Range(match.range(at: 2), in: value) else { return nil }
            let raw = value[numberRange].replacingOccurrences(of: ",", with: ".")
            guard let amount = Double(raw) else { return nil }
            let unit = value[unitRange].lowercased()
            return unit.hasPrefix("m") ? amount / 1024.0 : amount
        }
        return values.max()
    }

    private func makeOptions(url: URL, muteAudio: Bool = false, startTimeSeconds: Double = 0) -> KSOptions {
        let lowerURL = url.absoluteString.lowercased()
        let lowerRouteHint = routeHint.lowercased()
        let timingRiskHaystack = lowerURL + " " + lowerRouteHint
        let isTrailerPlayback = isTrailerURL(url) || lowerRouteHint.contains("trailer")
        let isVODStylePlayback = !isLiveStream && !isTrailerPlayback
        // Phase 11: classify only from already-owned source metadata. No network request,
        // player recreation, or main-thread probe is introduced during playback startup.
        let codecCompatibility = PlaybackCodecCompatibilityProfile.infer(url: url, routeHint: routeHint)
        // v985: the selected Source Intelligence label carries quality/size/container
        // facts into PlaybackKit. Use those facts only to choose a safer memory profile;
        // the 25/50 visible result limit and source ranking remain unchanged.
        let inferredSourceSizeGB = isVODStylePlayback ? inferredVODSourceSizeGB(from: routeHint) : nil
        let isHighMemoryVOD = isVODStylePlayback && (
            timingRiskHaystack.contains("2160") ||
            timingRiskHaystack.contains("4k") ||
            timingRiskHaystack.contains("uhd") ||
            timingRiskHaystack.contains("remux") ||
            timingRiskHaystack.contains("truehd") ||
            timingRiskHaystack.contains("dts-hd") ||
            timingRiskHaystack.contains("dtshd")
        )
        // A large 1080p Blu-ray/WEB source can be just as dangerous to a time-based
        // packet cache as a source explicitly labelled REMUX. Treat 8 GB+ as a bounded
        // memory lane even when quality/container tags alone look ordinary.
        let isLargeFileVOD = isVODStylePlayback && (inferredSourceSizeGB.map { $0 >= 8.0 } ?? false)
        let usesMemoryConstrainedVODProfile = isHighMemoryVOD || isLargeFileVOD
        let options: KSOptions = isVODStylePlayback ? DebridFlixorVODOptions() : KSOptions()
        // Flixor creates the VOD session with autoplay disabled, then issues one
        // explicit play after the stable native view is mounted. Other routes retain
        // their current autoplay behavior.
        KSOptions.isAutoPlay = !isVODStylePlayback
        // vBRDC135: full-screen VOD follows the physical display cadence rather than
        // asking KSPNUVIO to quantize CADisplayLink to a rounded source FPS. When tvOS
        // Match Content is active the display itself can run at the movie cadence; when it
        // is not, the renderer receives the output refresh cadence and videoClockSync owns
        // timestamp-based frame hold/advance. This does not invent frames; it removes an
        // extra source-FPS scheduling lane that can make 23.976/24/29.97 material look
        // uneven on a 50/60 Hz output. Live TV/trailers retain their donor scheduling.
        #if os(tvOS)
        KSOptions.preferredFrame = !isVODStylePlayback
        #else
        KSOptions.preferredFrame = true
        #endif
        let hasCBSMetadataSignal =
            timingRiskHaystack.contains("cbs") ||
            timingRiskHaystack.contains("paramount") ||
            timingRiskHaystack.contains("wcbs") ||
            timingRiskHaystack.contains("kcbs") ||
            timingRiskHaystack.contains("wbbm") ||
            timingRiskHaystack.contains("wkyc")
        let hasLiveRemuxTimingSignal =
            timingRiskHaystack.contains("/devices/") ||
            timingRiskHaystack.contains("channels.m3u") ||
            timingRiskHaystack.contains("/hls/") ||
            timingRiskHaystack.contains("/dvr/") ||
            timingRiskHaystack.contains("format=ts") ||
            timingRiskHaystack.contains(".m3u8") ||
            timingRiskHaystack.contains(".mpg") ||
            timingRiskHaystack.contains("tve") ||
            timingRiskHaystack.contains("channels dvr") ||
            timingRiskHaystack.contains("verizon") ||
            timingRiskHaystack.contains("live tv direct stream") ||
            timingRiskHaystack.contains("ks live tv route")
        let isLikelyCBSLiveTimingRisk =
            !isTrailerPlayback &&
            hasCBSMetadataSignal &&
            hasLiveRemuxTimingSignal
        let hasKnownNonNativeContainer = lowerURL.contains(".mkv") || lowerURL.contains("%2emkv") || lowerURL.contains("matroska") || lowerURL.contains(".avi") || lowerURL.contains("%2eavi") || lowerURL.contains(".webm") || lowerURL.contains("%2ewebm") || lowerURL.contains(".vob") || lowerURL.contains("%2evob")
        let hasHighRiskAudioContainerHint = lowerURL.contains("truehd") || lowerURL.contains("dts-hd") || lowerURL.contains("dtshd") || lowerURL.contains(" mlp") || lowerURL.contains("atmos truehd")
        let shouldTryNativeFirstForTvOSMatch = !isTrailerPlayback && !hasKnownNonNativeContainer && !hasHighRiskAudioContainerHint
        // v833: Match Frame Rate / Dynamic Range crash guard.
        // Preserve the v831 KSPlayer buffer/cache-ahead tuning, but do not force the
        // KSAVPlayer-first path during normal VOD playback. On some tvOS/projector/display
        // combinations the AVFoundation handoff can crash when Match Content is enabled.
        // KSMEPlayer remains the primary KSPlayer route. v961 gives main VOD the
        // same KSAVPlayer fallback order used by Flixor; trailers and Live TV keep
        // the previous KSMEPlayer-only fallback behavior.
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = isVODStylePlayback ? KSAVPlayer.self : KSMEPlayer.self
        options.isSecondOpen = true
        options.isAccurateSeek = true
        options.isSeekedAutoPlay = true
        options.startPlayTime = max(0, startTimeSeconds)
        // vBRDC327: explicit cadence invariant. KSPNUVIO/KSPlayer exposes startPlayRate;
        // always create Signal playback at physical 1.0x so a reused/static option cannot
        // make high-motion scenes appear fast or time-compressed.
        options.startPlayRate = 1.0
        if isTrailerPlayback {
            // v1059 built-in trailer audio integrity: do not let KSPlayer declare the
            // session open from the first partially parsed stream. Wait for the finalized
            // mux to expose stable video + audio tracks before playback becomes authoritative.
            options.isSecondOpen = false
            options.isAccurateSeek = false
            options.syncDecodeAudio = false
        }
        // v840: restore v832 trailer playback profile only.
        // v839 remains the base for everything else. Trailers go back to the
        // smaller v832 KSPlayer buffer/probe lane that avoided trailer stutter,
        // while movies/episodes keep the current VOD buffer/cache profile.
        // v961: main VOD matches Flixor's high-bitrate buffer profile exactly.
        // Trailers and Live TV retain their existing, proven buffer windows.
        // vBRDC061 physical-playback correction: restore the pre-vBRDC049 main-VOD
        // cache-ahead ceiling after device testing showed the 30-second cap was no longer
        // building the deep forward buffer expected for debrid playback. Keep the proven
        // startup thresholds (5 seconds ordinary VOD / 3 seconds high-memory VOD) and all
        // vBRDC049 decoder/ring-leak safeguards, but return only the VOD max packet-buffer
        // ceiling to the former five-minute / 300-second profile. Trailer and Live TV
        // buffering remain byte-for-byte behaviorally unchanged.
        // vBRDC069: the 300-second vBRDC061 ceiling is retained only for explicitly
        // small VOD files. KSPNUVIO's maxBufferDuration is time-based, so a five-minute
        // reserve scales directly with bitrate and can hold hundreds of MB (or multiple
        // GB for remuxes) in compressed packet queues. That can trigger tvOS jetsam with
        // no ordinary app exception .ips. Use an adaptive ceiling from already-owned
        // source metadata while keeping instant-open and the real scrubber buffer ghost.
        let adaptiveVODCacheProfile = isVODStylePlayback
            ? AdaptiveVODCachePlanner.profile(routeHint: routeHint, url: url, sourceSizeGB: inferredSourceSizeGB)
            : nil
        options.preferredForwardBufferDuration = isLikelyCBSLiveTimingRisk
            ? 8
            : (adaptiveVODCacheProfile?.preferredBufferDuration ?? (!isLiveStream ? 45 : 6))
        options.maxBufferDuration = isLikelyCBSLiveTimingRisk
            ? 12
            : (adaptiveVODCacheProfile?.maxBufferDuration ?? (!isLiveStream ? 90 : 12))
        let playbackConfiguration = isLiveStream ? PlaybackConfiguration.live : PlaybackConfiguration.vod
        options.hardwareDecode = playbackConfiguration.hardwareDecode
        // Phase 11 keeps hardware decoding forced. KSPlayer's built-in auto-deinterlace
        // is enabled only for sources that advertise interlace/MPEG-2 risk.
        options.autoDeInterlace = isVODStylePlayback && codecCompatibility.shouldAutoDeinterlace
        // v943 trailer cadence restoration: apply the same v840 cadence hybrid to
        // trailers as movies/episodes. Live TV remains on its existing path.
        options.asynchronousDecompression = playbackConfiguration.asynchronousDecompression
        options.decoderOptions["threads"] = playbackConfiguration.decoderThreadCount
        if let decoderThreadType = playbackConfiguration.decoderThreadType {
            options.decoderOptions["thread_type"] = decoderThreadType
        } else {
            options.decoderOptions["thread_type"] = nil
        }

        // v990 refined main-VOD cadence profile, retaining the v987 decode/buffer base. Keep the v985 memory-pressure
        // protections and v986 decoded-frame timestamp ordering, then disable the
        // instant "second open" path so playback reaches ready state with the full
        // preferred VOD buffer instead of only a couple of decoded frames.
        if isVODStylePlayback {
            options.hardwareDecode = true
            // KSPNUVIO default. Decode/presentation timestamps are taken from decoded
            // frames instead of the asynchronous compressed-packet path. The existing
            // one-shot first-frame play assertion/emergency same-position seek remains
            // active, so disabling asynchronous decompression does not restore the old
            // manual Skip Forward/Back startup requirement.
            // v993: restore the smoother decoded-frame FFmpeg path from v990/v987. The
            // pinned local KSPNUVIO package now clamps malformed/oversized HDR metadata and
            // bounds SEI reads, fixing the HEVC SIGTRAP at its source without forcing the
            // asynchronous VideoToolbox callback path that produces slow-scene stepping.
            // Phase 11 preserves the smooth decoded-frame path for ordinary H.264/HEVC.
            // Only DV Profile 7 / 12-bit HEVC enters the narrow asynchronous VideoToolbox
            // compatibility lane, avoiding a broad cadence regression for normal titles.
            options.asynchronousDecompression = codecCompatibility.prefersAsyncHardwareCompatibilityPath
            options.syncDecodeVideo = false
            options.syncDecodeAudio = false
            options.videoAdaptable = true
            // vBRDC062: restore KSPNUVIO's instant-open path for main VOD. The first
            // decodable frames may start playback immediately; the FFmpeg reader keeps
            // filling the existing 5-second preferred / 300-second maximum forward buffer
            // in the background. This separates startup latency from buffer depth instead
            // of making the viewer wait for the reserve to be built before first frame.
            options.isSecondOpen = true
            options.isAccurateSeek = false
            options.isSeekImageSubtitle = true
            if codecCompatibility.needsExtendedProbeWindow {
                // vBRDC049: keep enough headroom for late WebM/TS/legacy headers without the
                // former 80 MB probe. Large probe/analyze allocations happen during the same
                // startup period in which VideoToolbox creates its pixel-buffer pool, so use
                // the already-proven high-memory limits for every VOD session.
                options.probesize = 24_000_000
                options.maxAnalyzeDuration = 5_000_000
            } else {
                options.probesize = 12_000_000
                options.maxAnalyzeDuration = 3_000_000
            }
            options.destinationDynamicRange = nil
            options.decoderOptions["threads"] = "auto"
            options.decoderOptions["thread_type"] = nil
            options.decoderOptions["skip_loop_filter"] = nil
        } else if !isLiveStream {
            options.decoderOptions["skip_loop_filter"] = "none"
        }
        options.videoAdaptable = true

        let effectiveThreads = options.decoderOptions["threads"] as? String ?? "engine-default"
        let effectiveThreadType = options.decoderOptions["thread_type"] as? String ?? "engine-default"
        if isVODStylePlayback || PlaybackDiagnostics.isEnabled {
            let cacheDiagnostic = adaptiveVODCacheProfile?.diagnostic ?? "n/a"
            print("[PlaybackKit][vBRDC168] route=\(isVODStylePlayback ? "main-vod" : (isTrailerPlayback ? "trailer" : "live")) compatibility=\(codecCompatibility.diagnosticLabel) highMemoryVOD=\(isHighMemoryVOD) largeFileVOD=\(isLargeFileVOD) sourceSizeGB=\(inferredSourceSizeGB.map { String(format: "%.2f", $0) } ?? "unknown") adaptiveCache={\(cacheDiagnostic)} decoderMemoryProfile=\(usesMemoryConstrainedVODProfile) hardware=\(options.hardwareDecode) async=\(options.asynchronousDecompression) deinterlace=\(options.autoDeInterlace) syncVideo=\(options.syncDecodeVideo) syncAudio=\(options.syncDecodeAudio) adaptable=\(options.videoAdaptable) secondOpen=\(options.isSecondOpen) accurateSeek=\(options.isAccurateSeek) probe=\(options.probesize ?? -1) analyze=\(options.maxAnalyzeDuration ?? -1) buffer=\(options.preferredForwardBufferDuration)/\(options.maxBufferDuration) threads=\(effectiveThreads) type=\(effectiveThreadType) autoplay=\(KSOptions.isAutoPlay) fallback=\(String(describing: KSOptions.secondPlayerType))")
        }
        // v915/v840 stability: do not auto-select an embedded subtitle stream during
        // player startup. Explicit user track selection remains available after ready.
        options.autoSelectEmbedSubtitle = false
        options.registerRemoteControll = false
        let defaultUserAgent = isTrailerPlayback ? "DebridChannels-tvOS/1059 BuiltInTrailerKSPlayer" : "DebridChannels-tvOS/158 KSPlayer"
        let playbackHeaders = isVODStylePlayback
            ? mergedPlaybackHeaders(defaultUserAgent: defaultUserAgent)
            : ["User-Agent": defaultUserAgent, "Accept": "*/*", "Connection": "keep-alive"]
        let effectiveUserAgent = playbackHeaders.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value ?? defaultUserAgent
        options.userAgent = effectiveUserAgent
        options.avOptions = ["AVURLAssetHTTPHeaderFieldsKey": playbackHeaders]
        var formatOptions: [String: String] = [
            "reconnect": "1",
            "reconnect_streamed": "1",
            "reconnect_delay_max": "5",
            "fflags": isTrailerPlayback ? "+genpts" : (isLikelyCBSLiveTimingRisk ? "+genpts" : (isVODStylePlayback ? "+genpts" : "nobuffer")),
            "flags": isTrailerPlayback ? "" : (isLikelyCBSLiveTimingRisk || isVODStylePlayback ? "" : "low_delay"),
            "cache": isLikelyCBSLiveTimingRisk ? "1500" : (isTrailerPlayback ? "1500" : (isVODStylePlayback ? "1500" : "1500")),
            "rw_timeout": "15000000",
            "user_agent": effectiveUserAgent,
            "preferred_language": "eng,en,English",
            "preferred_audio_language": "eng,en,English",
            "audio_language": "eng,en,English",
            "alang": "eng,en,English",
            "slang": "eng,en,English",
            "subtitles": "1",
            "sn": "1",
            "analyzeduration": isTrailerPlayback ? "1000000" : (isLikelyCBSLiveTimingRisk ? "3000000" : (isVODStylePlayback ? "3000000" : "100000")),
            "probesize": isTrailerPlayback ? "262144" : (isLikelyCBSLiveTimingRisk ? "1048576" : (isVODStylePlayback ? "1048576" : "16384")),
            "thread_queue_size": usesMemoryConstrainedVODProfile ? "2048" : "8192",
            "max_delay": isTrailerPlayback ? "100000" : (isLikelyCBSLiveTimingRisk ? "700000" : (isVODStylePlayback ? "100000" : "100000")),
            "sync": isLikelyCBSLiveTimingRisk ? "ext" : "audio",
            "fpsprobesize": isTrailerPlayback ? "240" : (isVODStylePlayback ? "240" : "120")
        ]
        // vBRDC062: permanent main-VOD/CDN resilience. Keep the proven Live TV and
        // trailer dictionaries untouched, while allowing a playing VOD to reconnect after
        // transient TCP/TLS failures, 408 timeouts, 429 throttles, or retryable 5xx CDN
        // responses. Already-buffered media can continue rendering during the reconnect.
        // Authorization failures (401/403) intentionally remain terminal.
        if isVODStylePlayback {
            formatOptions["reconnect_on_network_error"] = "1"
            formatOptions["reconnect_on_http_error"] = "408,429,500,502,503,504"
            formatOptions["reconnect_delay_max"] = "2"
        }

        // v957: trailer and main VOD parity. Do not pass an empty FFmpeg `flags`
        // entry for either non-live path; Live TV retains its existing behavior.
        if isTrailerPlayback || isVODStylePlayback {
            formatOptions.removeValue(forKey: "flags")
        }
        // v940: VOD-only safe demux tuning. Live TV retains v938 exactly.
        if !isLiveStream {
            formatOptions["reorder_queue_size"] = usesMemoryConstrainedVODProfile ? "512" : "1024"
            formatOptions["buffer_size"] = String((usesMemoryConstrainedVODProfile ? 4 : 8) * 1024 * 1024)
            formatOptions["analyzeduration"] = usesMemoryConstrainedVODProfile ? "5000000" : "10000000"
            formatOptions["probesize"] = usesMemoryConstrainedVODProfile ? "8000000" : "15000000"
        }
        if muteAudio {
            formatOptions["an"] = "1"
            formatOptions["audio_disable"] = "1"
            formatOptions["volume"] = "0"
        }

        if isVODStylePlayback {
            // Flixor does not replace KSOptions' default FFmpeg dictionary with a
            // large raw option set. Keep KSPlayer defaults (scan_all_pmts,
            // reconnect, reconnect_streamed, user_agent) and append only the
            // request headers Debrid links require.
            // vBRDC089: append the exact provider request context to FFmpeg as well as
            // AVURLAsset. This is the missing Nuvio/Stremio behaviorHints.proxyHeaders
            // handoff that protected plugin and FebBox CDNs rely on.
            options.appendHeader(playbackHeaders)
            if muteAudio {
                options.formatContextOptions["an"] = "1"
                options.formatContextOptions["audio_disable"] = "1"
                options.formatContextOptions["volume"] = "0"
            }
        } else {
            options.formatContextOptions = formatOptions
        }

        // Phase 15 Volume Amplification. The pinned Tapframe KSPNUVIO KSOptions exposes
        // `audioFilters: [String]`; FFmpeg's volume filter accepts dB directly. Limit
        // values to the app's approved VOD presets and never attach a filter elsewhere.
        let approvedGainDB = normalizedVODAudioGainDB
        if isVODStylePlayback, !muteAudio, approvedGainDB > 0 {
            options.audioFilters = ["volume=\(Int(approvedGainDB))dB"]
        } else {
            options.audioFilters = []
        }
        return options
    }

    private func performBestEffortSeek(coordinator: Coordinator, layer: KSPlayerLayer, seconds: Double, isAbsolute: Bool, resumePlayback: Bool, currentSeconds: Double, durationHint: Double) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                performBestEffortSeek(coordinator: coordinator, layer: layer, seconds: seconds, isAbsolute: isAbsolute, resumePlayback: resumePlayback, currentSeconds: currentSeconds, durationHint: durationHint)
            }
            return
        }

        let reportedDuration = max(layer.player.duration, durationHint)
        let hasFiniteDuration = reportedDuration.isFinite && reportedDuration > 1
        let duration = hasFiniteDuration ? reportedDuration : Double.greatestFiniteMagnitude

        // VODPlayerScreen sends Back/Forward/Timeline scrubs as absolute, clamped seconds.
        // v827: do not reject seeks just because duration metadata is late; KSPlayer/FFmpeg
        // can often seek against the stream before a stable total duration is reported.
        let current = hasFiniteDuration ? max(0, min(currentSeconds, duration)) : max(0, currentSeconds)
        let unclampedTarget = isAbsolute ? seconds : current + seconds
        let target = min(max(unclampedTarget, 0), duration)

        print("KSPlayer Seek Requested: current=\(current) target=\(target) duration=\(hasFiniteDuration ? reportedDuration : -1)")
        layer.player.pause()
        layer.seek(time: target, autoPlay: resumePlayback) { [weak coordinator, weak layer] finished in
            DispatchQueue.main.async {
                guard let coordinator, let layer, coordinator.playerLayer === layer else { return }
                print(finished ? "KSPlayer Seek Completed" : "KSPlayer Seek Failed")
                guard resumePlayback else { return }

                // vBRDC084: KSPNUVIO intentionally pauses before seek and some sources
                // can finish the decoder flush *after* the old vBRDC077 0.18s assertion.
                // Start a bounded liveness recovery that watches the real engine clock. It
                // reasserts Play only while playback is still requested and stops as soon
                // as the clock advances between samples. A real Siri Remote Pause bumps
                // the generation above, so user intent always wins.
                layer.play()
                coordinator.postSeekAutoplayGeneration &+= 1
                let autoplayGeneration = coordinator.postSeekAutoplayGeneration
                schedulePostSeekAutoplayRecovery(
                    coordinator: coordinator,
                    layer: layer,
                    generation: autoplayGeneration,
                    attempt: 0,
                    previousClock: coordinator.currentPlaybackSeconds
                )
            }
        }
    }

    private func schedulePostSeekAutoplayRecovery(
        coordinator: Coordinator,
        layer: KSPlayerLayer,
        generation: UInt64,
        attempt: Int,
        previousClock: Double
    ) {
        // Four bounded checks cover the common delayed-flush window without turning this
        // into a permanent playback poller or spamming play() during normal playback.
        let delays: [TimeInterval] = [0.32, 0.52, 0.82, 1.18]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak coordinator, weak layer] in
            guard let coordinator, let layer,
                  coordinator.playerLayer === layer,
                  coordinator.postSeekAutoplayGeneration == generation,
                  coordinator.currentShouldPlay ?? true else { return }

            let currentClock = coordinator.currentPlaybackSeconds
            // Attempt 0 establishes a post-seek baseline. The clock can jump from the
            // startup position to the seek target while still paused, so that landing
            // jump must never be mistaken for actual resumed playback advancement.
            if attempt > 0, currentClock.isFinite, previousClock.isFinite, currentClock >= previousClock + 0.16 {
                print("[KSPlayer][vBRDC084] post-resume autoplay confirmed by advancing clock at \(currentClock)s")
                return
            }

            layer.play()
            print("[KSPlayer][vBRDC084] post-resume play reassertion attempt=\(attempt + 1) clock=\(currentClock)")
            schedulePostSeekAutoplayRecovery(
                coordinator: coordinator,
                layer: layer,
                generation: generation,
                attempt: attempt + 1,
                previousClock: currentClock
            )
        }
    }

    private func applyAudioMuteState(_ layer: KSPlayerLayer, muteAudio: Bool) {
        // vBRDC160: the pinned KSPNUVIO MediaPlayerProtocol exposes both properties publicly.
        // Avoid the old KVC guesswork so original audio is muted only after local alternate
        // audio is ready and can be restored instantly without recreating the video player.
        layer.player.isMuted = muteAudio
        layer.player.playbackVolume = muteAudio ? 0.0 : 1.0
    }

    // v902: deliberately no KVC/Mirror subtitle-object probing.  The v901 crash was
    // caused by undefined-key access while loading a link.  Subtitle layout is restricted
    // to real UIView descendants already owned by KSPlayer and is synchronized in
    // KSContainerView.layoutSubviews().

    private func stopLocalExternalAudio(coordinator: Coordinator, mainLayer: KSPlayerLayer?) {
        if let retired = coordinator.externalAudioController?.stopAndDetach() {
            coordinator.retiredExternalAudioPlayers.append(retired)
        }
        coordinator.externalAudioController = nil
        if let mainLayer {
            applyAudioMuteState(mainLayer, muteAudio: coordinator.currentMuteAudio)
        }
    }

    private func configureLocalExternalAudio(coordinator: Coordinator, mainLayer: KSPlayerLayer) {
        guard !isLiveStream, let sourceURL = externalAudioURL else {
            stopLocalExternalAudio(coordinator: coordinator, mainLayer: mainLayer)
            return
        }
        let controller = LocalExternalAudioController(
            sourceURL: sourceURL,
            trackIndex: externalAudioTrackIndex,
            offsetMS: externalAudioOffsetMS,
            httpHeaders: externalAudioHTTPHeaders,
            mainSeconds: coordinator.currentPlaybackSeconds,
            shouldPlay: shouldPlay,
            audioGainDB: normalizedVODAudioGainDB,
            onReady: { [weak coordinator, weak mainLayer] in
                guard let coordinator, let mainLayer, coordinator.playerLayer === mainLayer else { return }
                // Keep the primary video's decoder/render surface untouched. Only its output
                // audio is muted once the secondary audio-only decoder is actually ready.
                mainLayer.player.isMuted = true
                mainLayer.player.playbackVolume = 0
                coordinator.onExternalAudioReady?()
            },
            onFailure: { [weak coordinator, weak mainLayer] message in
                guard let coordinator else { return }
                if let retired = coordinator.externalAudioController?.stopAndDetach() {
                    coordinator.retiredExternalAudioPlayers.append(retired)
                }
                coordinator.externalAudioController = nil
                if let mainLayer, coordinator.playerLayer === mainLayer {
                    mainLayer.player.isMuted = coordinator.currentMuteAudio
                    mainLayer.player.playbackVolume = coordinator.currentMuteAudio ? 0 : 1
                }
                coordinator.onExternalAudioFailure?(message)
            }
        )
        if let retired = coordinator.externalAudioController?.stopAndDetach() {
            coordinator.retiredExternalAudioPlayers.append(retired)
        }
        coordinator.externalAudioController = controller
        controller.start()
    }

    private func configure(view: KSContainerView, coordinator: Coordinator) {
        coordinator.subtitleSurface = view
        if coordinator.currentURL == url,
           coordinator.currentPlaybackSessionID == playbackSessionID,
           coordinator.lastReloadToken == reloadToken,
           let layer = coordinator.playerLayer {
            let externalAudioSourceChanged =
                coordinator.currentExternalAudioURL != externalAudioURL ||
                coordinator.currentExternalAudioTrackIndex != externalAudioTrackIndex ||
                coordinator.currentExternalAudioHTTPHeaders != externalAudioHTTPHeaders
            let externalAudioOffsetChanged = coordinator.currentExternalAudioOffsetMS != externalAudioOffsetMS
            let externalAudioConfigurationChanged = externalAudioSourceChanged || externalAudioOffsetChanged
            let muteChanged = coordinator.currentMuteAudio != muteAudio
            let contentModeChanged = coordinator.currentContentMode != contentMode
            let approvedGainDB = normalizedVODAudioGainDB
            let audioGainChanged = abs(coordinator.currentAudioGainDB - approvedGainDB) > 0.01

            if externalAudioConfigurationChanged || muteChanged || contentModeChanged {
                coordinator.currentExternalAudioURL = externalAudioURL
                coordinator.currentExternalAudioOffsetMS = externalAudioOffsetMS
                coordinator.currentExternalAudioTrackIndex = externalAudioTrackIndex
                coordinator.currentExternalAudioHTTPHeaders = externalAudioHTTPHeaders
                coordinator.currentMuteAudio = muteAudio
                coordinator.currentContentMode = contentMode
                if externalAudioSourceChanged {
                    configureLocalExternalAudio(coordinator: coordinator, mainLayer: layer)
                } else if externalAudioOffsetChanged {
                    coordinator.externalAudioController?.update(
                        mainSeconds: coordinator.currentPlaybackSeconds,
                        offsetMS: externalAudioOffsetMS,
                        shouldPlay: shouldPlay,
                        audioGainDB: approvedGainDB,
                        forceSync: true
                    )
                }
            }
            if contentModeChanged {
                // Playback profile changes are the only non-geometry updates permitted to
                // touch the frozen render host. Identical assignments are suppressed.
                view.updateRenderContentModeIfChanged(contentMode)
            }
            if seekSerial != coordinator.lastSeekSerial {
                coordinator.lastSeekSerial = seekSerial
                let externalTarget = seekIsAbsolute ? seekSeconds : coordinator.currentPlaybackSeconds + seekSeconds
                coordinator.externalAudioController?.syncToMainClock(max(0, externalTarget), force: true)
                performBestEffortSeek(coordinator: coordinator, layer: layer, seconds: seekSeconds, isAbsolute: seekIsAbsolute, resumePlayback: shouldPlay, currentSeconds: coordinator.currentPlaybackSeconds, durationHint: coordinator.currentDurationSeconds)
            }
            if muteChanged {
                applyAudioMuteState(layer, muteAudio: muteAudio || (coordinator.externalAudioController?.didPublishReady == true))
            }
            if audioGainChanged {
                coordinator.currentAudioGainDB = approvedGainDB
                // KSPNUVIO's MEFilter rereads options.audioFilters for each decoded audio
                // frame and rebuilds only the audio filter graph when this value changes.
                // Replace the array atomically; do not touch playerLayer, URL, reload token,
                // seek serial, play state, display-match state, or render host.
                if !isLiveStream, !coordinator.currentIsTrailerPlayback, !muteAudio, approvedGainDB > 0 {
                    coordinator.activeOptions?.audioFilters = ["volume=\(Int(approvedGainDB))dB"]
                } else {
                    coordinator.activeOptions?.audioFilters = []
                }
                coordinator.externalAudioController?.update(
                    mainSeconds: coordinator.currentPlaybackSeconds,
                    offsetMS: coordinator.currentExternalAudioOffsetMS,
                    shouldPlay: shouldPlay,
                    audioGainDB: approvedGainDB
                )
                print("[KSPlayer][v1141] live VOD audio gain updated to \(approvedGainDB)dB without player recreation")
            }
            if coordinator.lastTrackSelectionSerial != trackSelectionSerial {
                coordinator.lastTrackSelectionSerial = trackSelectionSerial
                // Copy the new UI choice onto the coordinator BEFORE touching the active player.
                // v895 previously applied the coordinator's stale indexes, so audio often changed
                // only after a later rewind/resume and subtitle selection could be lost entirely.
                coordinator.selectedAudioTrackIndex = selectedAudioTrackIndex
                coordinator.selectedSubtitleTrackIndex = selectedSubtitleTrackIndex
                coordinator.selectedExternalSubtitleURL = selectedExternalSubtitleURL
                coordinator.subtitleDelayMS = subtitleDelayMS
                coordinator.pendingExplicitTrackSelection = true
                _ = coordinator.applySelectedTracksIfNeeded(layer, force: true, flushAfterSelection: true)
            }
            // vBRDC085: confirmed automatic resume needs a fresh engine Play command
            // even when `shouldPlay` was already true. A monotonically changing serial
            // makes that command explicit without recreating KSPlayer or abusing seek state.
            if coordinator.lastPlayAssertionSerial != playAssertionSerial {
                coordinator.lastPlayAssertionSerial = playAssertionSerial
                if shouldPlay {
                    coordinator.currentShouldPlay = true
                    layer.play()
                    coordinator.externalAudioController?.update(mainSeconds: coordinator.currentPlaybackSeconds, offsetMS: coordinator.currentExternalAudioOffsetMS, shouldPlay: true, audioGainDB: approvedGainDB)
                    coordinator.postSeekAutoplayGeneration &+= 1
                    let generation = coordinator.postSeekAutoplayGeneration
                    schedulePostSeekAutoplayRecovery(
                        coordinator: coordinator,
                        layer: layer,
                        generation: generation,
                        attempt: 0,
                        previousClock: coordinator.currentPlaybackSeconds
                    )
                }
            }

            // v408: KSPlayer can crash on some tvOS/package builds if play()/pause() is
            // spammed on every SwiftUI state refresh. Only send the command when the
            // requested playback state actually changes. This stabilizes Pause -> Play
            // without changing URL, cache, seek, overlay, or Live TV behavior.
            if coordinator.currentShouldPlay != shouldPlay {
                coordinator.currentShouldPlay = shouldPlay
                if shouldPlay {
                    layer.play()
                } else {
                    coordinator.postSeekAutoplayGeneration &+= 1
                    layer.pause()
                }
                coordinator.externalAudioController?.update(mainSeconds: coordinator.currentPlaybackSeconds, offsetMS: coordinator.currentExternalAudioOffsetMS, shouldPlay: shouldPlay, audioGainDB: approvedGainDB)
            }
            // v1056: never schedule a new chain of trailer play/start commands from a
            // routine SwiftUI update. A single harmless play assertion is allowed only
            // before the real trailer clock has advanced.
            if shouldPlay, coordinator.currentIsTrailerPlayback, !coordinator.trailerPlaybackHasAdvanced {
                layer.play()
            }
            return
        }

        if let retired = coordinator.externalAudioController?.stopAndDetach() {
            coordinator.retiredExternalAudioPlayers.append(retired)
        }
        coordinator.externalAudioController = nil
        coordinator.playerLayer?.pause()
        coordinator.playerLayer?.stop()
        // URL/reload replacement is the sole path allowed to detach the old render host.
        view.resetRenderHostForURLChange()
        view.subviews.forEach { $0.removeFromSuperview() }
        coordinator.resetSubtitleBridge()
        coordinator.subtitleSurface = view
        coordinator.currentURL = url
        coordinator.currentPlaybackSessionID = playbackSessionID
        coordinator.lastReloadToken = reloadToken
        coordinator.currentStartTimeSeconds = startTimeSeconds
        coordinator.currentExternalAudioURL = externalAudioURL
        coordinator.currentExternalAudioOffsetMS = externalAudioOffsetMS
        coordinator.currentExternalAudioTrackIndex = externalAudioTrackIndex
        coordinator.currentExternalAudioHTTPHeaders = externalAudioHTTPHeaders
        coordinator.currentMuteAudio = muteAudio
        coordinator.currentContentMode = contentMode
        coordinator.currentShouldPlay = shouldPlay
        coordinator.lastPlayAssertionSerial = playAssertionSerial
        coordinator.lastSeekSerial = seekSerial
        coordinator.resetClockGateForNewSource(startTime: startTimeSeconds)
        coordinator.currentIsTrailerPlayback = isTrailerURL(url) || routeHint.lowercased().contains("trailer")
        coordinator.currentIsLiveStream = isLiveStream
        coordinator.currentAdaptiveCacheRouteHint = routeHint
        coordinator.currentAdaptiveCacheSourceSizeGB = (!isLiveStream && !coordinator.currentIsTrailerPlayback) ? inferredVODSourceSizeGB(from: routeHint) : nil
        coordinator.didRefineAdaptiveCacheFromDuration = coordinator.currentAdaptiveCacheSourceSizeGB == nil
        coordinator.didReceiveAdaptiveCacheMemoryPressure = false
        coordinator.trailerStartupGeneration &+= 1
        coordinator.trailerPlaybackHasAdvanced = false
        coordinator.didApplyEnglishAudioSelection = false
        coordinator.englishAudioSelectionScheduled = false
        coordinator.lastPublishedChapterSignature = ""
        coordinator.appliedAudioTrackIndex = nil
        coordinator.appliedSubtitleTrackIndex = nil
        coordinator.appliedExternalSubtitleURL = nil
        coordinator.lastTrackSelectionSerial = trackSelectionSerial
        coordinator.selectedAudioTrackIndex = selectedAudioTrackIndex
        coordinator.selectedSubtitleTrackIndex = selectedSubtitleTrackIndex
        coordinator.selectedExternalSubtitleURL = selectedExternalSubtitleURL
        coordinator.subtitleDelayMS = subtitleDelayMS
        coordinator.pendingExplicitTrackSelection = false
        coordinator.firstFrameReleaseEligible = !isLiveStream && !coordinator.currentIsTrailerPlayback
        coordinator.didEvaluateFirstFrameRelease = false
        coordinator.didPerformFirstFrameRelease = false
        coordinator.firstFrameRecoveryGeneration += 1
        coordinator.onTracksDiscovered = onTracksDiscovered
        coordinator.currentAudioGainDB = normalizedVODAudioGainDB

        let options = makeOptions(url: url, muteAudio: muteAudio, startTimeSeconds: startTimeSeconds)
        // vBRDC043: KSPNUVIO emits one tiny aggregate fingerprint per decoded audio
        // second only when this callback is installed. Movies, trailers and Live TV
        // leave the callback nil from the SwiftUI caller, so they pay no detector cost.
        if let fingerprintSink = coordinator.onAudioFingerprintSample {
            options.audioFingerprintSampleHandler = { sample in
                fingerprintSink(PlaybackAudioFingerprintSample(
                    seconds: sample.seconds,
                    hash: sample.hash,
                    energy: sample.energy,
                    zeroCrossingRate: sample.zeroCrossingRate
                ))
            }
        } else {
            options.audioFingerprintSampleHandler = nil
        }
        coordinator.activeOptions = options
        coordinator.currentDisplayMatchEnabled = enableDisplayMatch
        coordinator.currentDisplayMatchIsLive = displayMatchIsLive
        #if os(tvOS)
        if enableDisplayMatch, #available(tvOS 11.2, *) {
            if displayMatchIsLive {
                DebridTVOSDisplayMatchCoordinator.applyForLiveChannel(url: url, hint: routeHint)
            } else {
                DebridTVOSDisplayMatchCoordinator.applyForFullScreenVOD(url: url, hint: routeHint, httpHeaders: sanitizedPlaybackHTTPHeaders)
            }
        } else if #available(tvOS 11.2, *) {
            DebridTVOSDisplayMatchCoordinator.cancelPendingLiveDisplayMatch()
        }
        #endif
        // v1014: restore the proven v999 Live TV construction path exactly.
        // Live TV and trailers retain constructor autoplay; full-screen VOD remains
        // mounted first and then receives the existing explicit play command.
        let isMainVODPlayback = !isLiveStream && !coordinator.currentIsTrailerPlayback
        let layer = KSPlayerLayer(url: url, isAutoPlay: !isMainVODPlayback, options: options, delegate: coordinator)
        coordinator.playerLayer = layer
        if let playerView = layer.player.view {
            playerView.backgroundColor = .black
            playerView.isOpaque = true
            playerView.clearsContextBeforeDrawing = false
            playerView.contentMode = contentMode
            switch contentMode {
            case .scaleAspectFill: playerView.layer.contentsGravity = .resizeAspectFill
            case .scaleToFill: playerView.layer.contentsGravity = .resize
            default: playerView.layer.contentsGravity = .resizeAspect
            }
            // v929 Phase B: leave the KSPlayer/Metal render layer on Core Animation's
            // normal presentation path. Forcing drawsAsynchronously adds an extra CA
            // scheduling lane that can become visible during fast pans and scene cuts.
            playerView.layer.drawsAsynchronously = false
            playerView.layer.contentsScale = playerView.traitCollection.displayScale
            playerView.isUserInteractionEnabled = false
            playerView.transform = .identity
            playerView.frame = view.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            playerView.clipsToBounds = true
            // v924 Phase 1: attach the KSPlayer render host exactly once. Geometry and
            // hierarchy configuration are frozen inside KSContainerView after installation.
            view.installRenderViewOnce(playerView)
        }
        applyAudioMuteState(layer, muteAudio: muteAudio)
        if externalAudioURL != nil {
            configureLocalExternalAudio(coordinator: coordinator, mainLayer: layer)
        }
        coordinator.publishDiscoveredTracks(layer)
        if !coordinator.currentIsTrailerPlayback, !muteAudio, selectedAudioTrackIndex == nil {
            coordinator.didApplyEnglishAudioSelection = coordinator.applyEnglishAudioTrackIfAvailable(layer)
        }
        coordinator.applySelectedTracksIfNeeded(layer, force: true)
        if shouldPlay { forceStartTrailerLayerIfNeeded(layer, url: url, deepNudge: true) } else { layer.pause() }
        // v1056 trailer full-audio guard: startup rescue is tied to the exact layer and
        // generation, never re-selects audio, never reapplies volume, and stops forever
        // once the real trailer clock advances. Old delayed work therefore cannot revive
        // a dismissed trailer or interrupt a newer/current audio pipeline.
        if coordinator.currentIsTrailerPlayback {
            let startupGeneration = coordinator.trailerStartupGeneration
            for delay in [0.15, 0.55, 1.10, 2.00] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard coordinator.playerLayer === layer,
                          coordinator.currentURL == url,
                          coordinator.trailerStartupGeneration == startupGeneration,
                          !coordinator.trailerPlaybackHasAdvanced else { return }
                    if shouldPlay { forceStartTrailerLayerIfNeeded(layer, url: url, deepNudge: false) }
                }
            }
        }
    }

    private func isTrailerURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("/trailers/") || lower.contains("trailer") || lower.contains("remux-cache") || lower.contains("kinocheck")
    }

    private func forceStartTrailerLayerIfNeeded(_ layer: KSPlayerLayer, url: URL, deepNudge: Bool = false) {
        let isTrailerPlayback = isTrailerURL(url) || routeHint.lowercased().contains("trailer")
        // Main VOD playback keeps its existing conservative play/pause behavior.
        guard isTrailerPlayback else { layer.play(); return }
        layer.play()
        guard deepNudge, let object = layer.player as? NSObject else { return }
        // `start` can rebuild/reset an already-created FFmpeg audio path. Limit the
        // one-time trailer startup nudge to idempotent play/resume selectors only.
        for name in ["play", "resume"] {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector) { _ = object.perform(selector) }
        }
    }

    private func applyDefaultTracks(_ layer: KSPlayerLayer) {
        // Retained for compatibility with older call sites. The active path now applies
        // English audio once from Coordinator after KSPlayer exposes real tracks.
    }

    static func dismantleUIView(_ anchor: PlaybackSurfaceAnchorView, coordinator: Coordinator) {
        let uiView = anchor.surface
        if coordinator.renderSurfaceRegistrationEnabled,
           let registration = coordinator.renderSurfaceRegistration {
            // Phase 10: an active PlaybackSession owns the surface and coordinator teardown.
            // A SwiftUI invalidation must not stop KSPlayer or destroy its layer tree.
            if PlaybackController.shared.sessionOwnsRenderSurface(registration) {
                return
            }
            PlaybackController.shared.unregisterRenderSurfaceCandidate(uiView, registration: registration)
            coordinator.renderSurfaceRegistration = nil
        }
        coordinator.playbackKitStopAndReleaseSurface()
        uiView.subviews.forEach { $0.removeFromSuperview() }
    }
}
#endif
