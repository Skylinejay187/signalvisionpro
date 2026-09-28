import Foundation

/// Phase 11 codec/container classifier used only to choose conservative KSPlayer
/// decode/presentation options. It never rewrites the playback URL and never disables
/// hardware decoding; unsupported hardware formats remain owned by KSPlayer/FFmpeg's
/// existing fallback behavior.
struct PlaybackCodecCompatibilityProfile: Equatable {
    enum VideoFamily: String {
        case h264 = "H.264/AVC"
        case hevc = "HEVC/H.265"
        case av1 = "AV1"
        case vp9 = "VP9"
        case mpeg2 = "MPEG-2"
        case vc1 = "VC-1"
        case legacy = "Legacy"
        case unknown = "Unknown"
    }

    enum ContainerFamily: String {
        case hls = "HLS"
        case mp4 = "MP4/MOV"
        case matroska = "Matroska/MKV"
        case webm = "WebM"
        case mpegts = "MPEG-TS"
        case avi = "AVI"
        case unknown = "Unknown"
    }

    let videoFamily: VideoFamily
    let containerFamily: ContainerFamily
    let isHighBitDepth: Bool
    let isTwelveBit: Bool
    let isHDR: Bool
    let isDolbyVision: Bool
    let isDolbyVisionProfile7: Bool
    let isInterlacedRisk: Bool
    let shouldAutoDeinterlace: Bool
    let prefersAsyncHardwareCompatibilityPath: Bool
    let needsExtendedProbeWindow: Bool
    let diagnosticLabel: String

    static func infer(url: URL, routeHint: String) -> PlaybackCodecCompatibilityProfile {
        let value = (url.absoluteString + " " + routeHint).lowercased()

        let videoFamily: VideoFamily = {
            if containsAny(value, ["av1", "av01"]) { return .av1 }
            if containsAny(value, ["hevc", "h265", "h.265", "hev1", "hvc1", "dvhe", "dvh1"]) { return .hevc }
            if containsAny(value, ["h264", "h.264", "avc1", " avc ", "x264"]) { return .h264 }
            if containsAny(value, ["vp9", "vp09"]) { return .vp9 }
            if containsAny(value, ["mpeg2", "mpeg-2", "mpeg2video", " m2v "]) { return .mpeg2 }
            if containsAny(value, ["vc-1", "vc1", "wmv3", "wvc1"]) { return .vc1 }
            if containsAny(value, ["xvid", "divx", "mpeg4", "msmpeg"]) { return .legacy }
            return .unknown
        }()

        let containerFamily: ContainerFamily = {
            if containsAny(value, [".m3u8", " hls ", "mpegurl"]) { return .hls }
            if containsAny(value, [".mkv", "%2emkv", "matroska"]) { return .matroska }
            if containsAny(value, [".webm", "%2ewebm"]) { return .webm }
            if containsAny(value, [".ts", "%2ets", "mpeg-ts", "mpegts", "transport stream"]) { return .mpegts }
            if containsAny(value, [".avi", "%2eavi"]) { return .avi }
            if containsAny(value, [".mp4", "%2emp4", ".m4v", "%2em4v", ".mov", "%2emov"]) { return .mp4 }
            return .unknown
        }()

        let isTwelveBit = containsAny(value, ["12-bit", "12bit", "main12", "main 12", "yuv420p12", "p012", "p016"])
        let isHighBitDepth = isTwelveBit || containsAny(value, ["10-bit", "10bit", "main10", "main 10", "yuv420p10", "p010", "hi10p", "high 10"])
        let isDolbyVision = containsAny(value, ["dolby vision", "dolbyvision", "dvhe", "dvh1", " dolby-vision "])
        let isDolbyVisionProfile7 = isDolbyVision && containsAny(value, ["profile 7", "profile7", "dvhe.07", "dvhe.7", "p7", "dual layer", "dual-layer"])
        let isHDR = isDolbyVision || containsAny(value, ["hdr10", "hdr10+", " hlg", "bt2020", "bt.2020", "smpte2084", "smpte 2084", "pq "])
        let isInterlacedRisk = containsAny(value, ["interlaced", "1080i", "576i", "480i", "59.94i", "29.97i", "50i", "25i", "top field", "bottom field", " tff", " bff"])

        // The v993 decoded-frame path remains the default because it gives the best cadence.
        // Only high-risk HEVC variants use KSPNUVIO's asynchronous VideoToolbox callback lane.
        // This is deliberately narrow: ordinary HEVC Main10/HDR stays on the proven path.
        let prefersAsyncHardwareCompatibilityPath =
            videoFamily == .hevc && (isDolbyVisionProfile7 || isTwelveBit)

        // KSPlayer exposes autoDeInterlace and performs detection internally. Limit it to
        // sources that actually advertise interlace/legacy MPEG-2 characteristics.
        let shouldAutoDeinterlace = isInterlacedRisk || videoFamily == .mpeg2

        let needsExtendedProbeWindow =
            containerFamily == .webm || containerFamily == .mpegts || containerFamily == .avi ||
            videoFamily == .av1 || videoFamily == .vp9 || videoFamily == .vc1 || videoFamily == .legacy

        var bits: [String] = [videoFamily.rawValue, containerFamily.rawValue]
        if isHighBitDepth { bits.append(isTwelveBit ? "12-bit" : "10-bit") }
        if isDolbyVisionProfile7 { bits.append("Dolby Vision P7 compatibility") }
        else if isDolbyVision { bits.append("Dolby Vision") }
        else if isHDR { bits.append("HDR") }
        if shouldAutoDeinterlace { bits.append("deinterlace") }
        if prefersAsyncHardwareCompatibilityPath { bits.append("async VT compatibility") }
        if needsExtendedProbeWindow { bits.append("extended probe") }

        return PlaybackCodecCompatibilityProfile(
            videoFamily: videoFamily,
            containerFamily: containerFamily,
            isHighBitDepth: isHighBitDepth,
            isTwelveBit: isTwelveBit,
            isHDR: isHDR,
            isDolbyVision: isDolbyVision,
            isDolbyVisionProfile7: isDolbyVisionProfile7,
            isInterlacedRisk: isInterlacedRisk,
            shouldAutoDeinterlace: shouldAutoDeinterlace,
            prefersAsyncHardwareCompatibilityPath: prefersAsyncHardwareCompatibilityPath,
            needsExtendedProbeWindow: needsExtendedProbeWindow,
            diagnosticLabel: bits.joined(separator: " • ")
        )
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}


/// vBRDC256 Phase 5: conservative cross-engine compatibility policy.
/// Aether remains primary, including Live TV (required for later native timeshift), while
/// known difficult formats get a shorter recovery window before the existing same-source
/// KSPlayer compatibility fallback is allowed to take over. No URL rewriting occurs here.
struct AetherPlaybackCompatibilityPolicy: Equatable {
    let diagnosticLabel: String
    let startupGraceSeconds: Double
    let isHighRisk: Bool

    static func infer(url: URL, routeHint: String, isLive: Bool) -> AetherPlaybackCompatibilityPolicy {
        let profile = PlaybackCodecCompatibilityProfile.infer(url: url, routeHint: routeHint)
        let highRisk = profile.isDolbyVisionProfile7
            || profile.isTwelveBit
            || profile.videoFamily == .vc1
            || profile.videoFamily == .legacy
            || profile.containerFamily == .avi
            || profile.containerFamily == .webm

        // vBRDC259: Live TV now has an Aether-internal recovery ladder (automatic URL ->
        // header-safe HLS ingest when applicable -> per-session software decode). The app-level
        // KSPlayer watchdog is therefore only the final circuit breaker and must not pre-empt
        // those Aether routes. Healthy channels still start immediately; this is only a ceiling.
        let grace: Double
        if isLive {
            grace = highRisk ? 32.0 : 34.0
        } else {
            grace = highRisk ? 14.0 : 20.0
        }
        return AetherPlaybackCompatibilityPolicy(
            diagnosticLabel: "Aether • \(profile.diagnosticLabel) • startup grace \(Int(grace))s",
            startupGraceSeconds: grace,
            isHighRisk: highRisk
        )
    }
}
