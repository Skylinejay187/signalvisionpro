import SwiftUI
import AVFoundation
import AVKit

#if canImport(TVVLCKit)
import TVVLCKit
#endif
#if canImport(KSPlayer)
import KSPlayer
#endif

enum DebridHardwareAccelerationSetting: String, CaseIterable {
    case auto = "auto"
    case forceOn = "forceOn"
    case forceOff = "forceOff"

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .auto
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto / Recommended"
        case .forceOn: return "Force On"
        case .forceOff: return "Force Off"
        }
    }

    var diagnosticsName: String {
        switch self {
        case .auto: return "Auto"
        case .forceOn: return "Force On"
        case .forceOff: return "Force Off"
        }
    }

    var prefersHardwareDecode: Bool { self != .forceOff }
    var forcesHardwareDecode: Bool { self == .forceOn }
}

// vBRDC189: one engine-neutral VOD picture geometry contract.  The old .zoom chip
// only toggled AVPlayer between Aspect Fit and Aspect Fill, and the chip later fell
// out of the production rail entirely.  These modes are now shared by AVPlayer,
// KSPlayer and VLC containers so VOD exposes the complete practical TV/cinema set
// without rebuilding or restarting the active playback session.
enum DebridVideoFitMode: String, CaseIterable, Hashable {
    case fit
    case fill
    case crop
    case stretch
    case zoom110
    case zoom125
    case zoom150
    case ratio16x9
    case ratio4x3
    case ratio21x9
    case ratio32x9
    case ratio17x9
    case ratio16x10
    case ratio3x2
    case ratio14x9
    case ratio5x4
    case ratio1x1
    case ratio9x16
    case ratio3x4
    case ratio166
    case ratio185
    case ratio200
    case ratio220
    case ratio235
    case ratio239
    case ratio240
    case ratio255
    case ratio276

    var displayName: String {
        switch self {
        case .fit: return "Source / Fit"
        case .fill: return "Fill Screen"
        case .crop: return "Crop / Zoom"
        case .stretch: return "Stretch"
        case .zoom110: return "Zoom 110%"
        case .zoom125: return "Zoom 125%"
        case .zoom150: return "Zoom 150%"
        case .ratio16x9: return "16:9 HDTV"
        case .ratio4x3: return "4:3 TV"
        case .ratio21x9: return "21:9 Ultrawide"
        case .ratio32x9: return "32:9 Super Ultrawide"
        case .ratio17x9: return "17:9 DCI"
        case .ratio16x10: return "16:10"
        case .ratio3x2: return "3:2"
        case .ratio14x9: return "14:9"
        case .ratio5x4: return "5:4"
        case .ratio1x1: return "1:1 Square"
        case .ratio9x16: return "9:16 Vertical"
        case .ratio3x4: return "3:4 Vertical"
        case .ratio166: return "1.66:1 European"
        case .ratio185: return "1.85:1 Flat"
        case .ratio200: return "2.00:1 Univisium"
        case .ratio220: return "2.20:1 70mm"
        case .ratio235: return "2.35:1 CinemaScope"
        case .ratio239: return "2.39:1 Scope"
        case .ratio240: return "2.40:1 Scope"
        case .ratio255: return "2.55:1 CinemaScope"
        case .ratio276: return "2.76:1 Ultra Panavision"
        }
    }

    var chipLabel: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .crop: return "Crop"
        case .stretch: return "Stretch"
        default: return displayName.components(separatedBy: " ").first ?? displayName
        }
    }

    var targetAspectRatio: CGFloat? {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio21x9: return 21.0 / 9.0
        case .ratio32x9: return 32.0 / 9.0
        case .ratio17x9: return 17.0 / 9.0
        case .ratio16x10: return 16.0 / 10.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio14x9: return 14.0 / 9.0
        case .ratio5x4: return 5.0 / 4.0
        case .ratio1x1: return 1.0
        case .ratio9x16: return 9.0 / 16.0
        case .ratio3x4: return 3.0 / 4.0
        case .ratio166: return 1.66
        case .ratio185: return 1.85
        case .ratio200: return 2.00
        case .ratio220: return 2.20
        case .ratio235: return 2.35
        case .ratio239: return 2.39
        case .ratio240: return 2.40
        case .ratio255: return 2.55
        case .ratio276: return 2.76
        default: return nil
        }
    }

    var zoomScale: CGFloat {
        switch self {
        case .crop: return 1.10
        case .zoom110: return 1.10
        case .zoom125: return 1.25
        case .zoom150: return 1.50
        default: return 1.0
        }
    }

    var avVideoGravity: AVLayerVideoGravity {
        if targetAspectRatio != nil || self == .stretch { return .resize }
        switch self {
        case .fill, .crop: return .resizeAspectFill
        default: return .resizeAspect
        }
    }

    var uiContentMode: UIView.ContentMode {
        if targetAspectRatio != nil || self == .stretch { return .scaleToFill }
        switch self {
        case .fill, .crop: return .scaleAspectFill
        default: return .scaleAspectFit
        }
    }

    func fittedCanvasSize(in bounds: CGSize) -> CGSize {
        guard let ratio = targetAspectRatio, ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let boundsRatio = bounds.width / bounds.height
        if ratio >= boundsRatio {
            return CGSize(width: bounds.width, height: bounds.width / ratio)
        }
        return CGSize(width: bounds.height * ratio, height: bounds.height)
    }
}

struct DebridVideoFitContainer<Content: View>: View {
    let mode: DebridVideoFitMode
    let content: Content

    init(mode: DebridVideoFitMode, @ViewBuilder content: () -> Content) {
        self.mode = mode
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let canvas = mode.fittedCanvasSize(in: proxy.size)
            ZStack {
                Color.black
                content
                    .frame(width: canvas.width, height: canvas.height)
                    .scaleEffect(mode.zoomScale, anchor: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .clipped()
        }
        .background(Color.black)
    }
}

// Phase 12: KSPlayer/tvOS display matching moved to PlaybackKit/PlaybackKitKSPlayerSurface.swift.



struct NativePlaybackProfile {
    let normalizedHint: String
    let isHLS: Bool
    let isAppleContainer: Bool
    let isMatroskaOrUnsupportedContainer: Bool
    let isLikelyDolbyVision: Bool
    let isNativeDolbyVisionPreferred: Bool
    let isLikelyHDR: Bool
    let isLikelyUnsupportedAudioOnlyRisk: Bool
    let requiresVLCForContainer: Bool

    var diagnostic: String {
        var flags: [String] = []
        if isHLS { flags.append("HLS") }
        if isAppleContainer { flags.append("Apple container") }
        if isLikelyDolbyVision { flags.append("Dolby Vision hint") }
        if isNativeDolbyVisionPreferred { flags.append("Native DV preferred") }
        if isLikelyHDR { flags.append("HDR hint") }
        if isMatroskaOrUnsupportedContainer { flags.append("MKV/unsupported container") }
        if isLikelyUnsupportedAudioOnlyRisk { flags.append("audio-only risk") }
        return flags.isEmpty ? "generic HTTP stream" : flags.joined(separator: " • ")
    }
}

enum PlayerEngine: String, CaseIterable {
    case avplayer
    case ksplayer
    case vlc
}

enum UniversalCodecSupport {
    static let buildMarker = "DEBRID_CHANNELS_TVOS_BUILD_V760_EPISODE_ALERT_POSITION_AND_INTERVAL_HARDCODE_FIX_READY_UPLOAD"

    static var vlcCompiledIn: Bool {
        #if canImport(TVVLCKit)
        return true
        #else
        return false
        #endif
    }


    static var ksPlayerCompiledIn: Bool {
        #if canImport(KSPlayer)
        return true
        #else
        return false
        #endif
    }


    static func profile(for url: URL, hint: String = "") -> NativePlaybackProfile {
        let value = (url.absoluteString + " " + hint).lowercased()
        let isHLS = value.contains(".m3u8") || value.contains("application/vnd.apple.mpegurl") || value.contains("mpegurl")
        let isAppleContainer = isHLS || value.contains(".mp4") || value.contains("%2emp4") || value.contains(".m4v") || value.contains("%2em4v") || value.contains(".mov") || value.contains("%2emov")
        let isMatroska = value.contains(".mkv") || value.contains("%2emkv") || value.contains("matroska")
        let unsupportedContainer = isMatroska || value.contains(".avi") || value.contains("%2eavi") || value.contains(".webm") || value.contains("%2ewebm") || value.contains(".vob") || value.contains("%2evob")
        let isDolbyVision = value.contains("dolby vision") || value.contains(" dolbyvision") || value.contains(" dv ") || value.contains("dvhe") || value.contains("dvh1") || value.contains("profile 5") || value.contains("profile 7") || value.contains("profile 8")
        let nativeDVPreferred = isAppleContainer && (value.contains("profile 5") || value.contains("profile 8") || value.contains("dvhe.05") || value.contains("dvhe.08") || value.contains("dvh1") || isHLS)
        let hdr = isDolbyVision || value.contains("hdr10") || value.contains("hdr10+") || value.contains("hlg") || value.contains("bt2020") || value.contains("main10")
        let audioRisk = value.contains(" dts") || value.contains("dts-hd") || value.contains("dtshd") || value.contains("truehd") || value.contains("mlp") || value.contains("atmos truehd") || value.contains("vp9") || value.contains("av1")
        let profile7 = value.contains("profile 7") || value.contains("dvhe.07") || value.contains("dolby vision profile 7")
        let requiresVLC = unsupportedContainer || profile7 || audioRisk
        return NativePlaybackProfile(
            normalizedHint: value,
            isHLS: isHLS,
            isAppleContainer: isAppleContainer,
            isMatroskaOrUnsupportedContainer: unsupportedContainer,
            isLikelyDolbyVision: isDolbyVision,
            isNativeDolbyVisionPreferred: nativeDVPreferred,
            isLikelyHDR: hdr,
            isLikelyUnsupportedAudioOnlyRisk: audioRisk || profile7,
            requiresVLCForContainer: requiresVLC
        )
    }

    static func shouldPreferVLC(for url: URL, hint: String = "") -> Bool {
        let p = profile(for: url, hint: hint)
        if p.normalizedHint.hasPrefix("magnet:") { return false }
        return false
    }

    static func playbackEngineName(for url: URL, hint: String = "") -> String {
        if ksPlayerCompiledIn && vlcCompiledIn { return "AVPlayer default + KSPlayer/TVVLCKit explicit fallbacks" }
        if ksPlayerCompiledIn { return "AVPlayer default + KSPlayer explicit fallback" }
        if vlcCompiledIn { return "AVPlayer default + TVVLCKit explicit fallback" }
        return "AVPlayer default; fallback packages missing"
    }


    static func inferredSourceFPS(for profile: NativePlaybackProfile) -> String {
        let value = profile.normalizedHint
        if value.contains("23.976") || value.contains("23_976") || value.contains("24000/1001") { return "23.976 target" }
        if value.contains("24fps") || value.contains(" 24 ") || value.contains(".24.") { return "24 target" }
        if value.contains("25fps") || value.contains(" 25 ") || value.contains(".25.") { return "25 target" }
        if value.contains("29.97") || value.contains("30000/1001") { return "29.97 target" }
        if value.contains("30fps") || value.contains(" 30 ") || value.contains(".30.") { return "30 target" }
        if value.contains("50fps") || value.contains(" 50 ") || value.contains(".50.") { return "50 target" }
        if value.contains("59.94") || value.contains("60000/1001") { return "59.94 target" }
        if value.contains("60fps") || value.contains(" 60 ") || value.contains(".60.") { return "60 target" }
        // Most VOD movie/show files are 23.976/24p even when the file name only exposes 1080p/2160p.
        return "23.976/24 target"
    }

    static func magnetDiagnostic(for value: String) -> String? {
        let lower = value.lowercased()
        guard lower.hasPrefix("magnet:") || lower.contains("infohash") else { return nil }
        return "Magnet/infoHash items require the torrent framework/service path before playback. Direct TorBox/debrid HTTP(S) stream URLs play in-app; raw torrent streaming is isolated from AVFoundation."
    }
}


struct DebridPlaybackDiagnostics: Equatable {
    var activeEngine: String
    var hwDecode: String
    var renderBackend: String
    var decoder: String
    var fps: String
    var droppedFrames: String
    var notes: String
    var videoCodec: String = "Detecting"
    var audioCodec: String = "Detecting"
    var audioChannels: String = "Detecting"
    var sampleRate: String = "Detecting"
    var scanType: String = "Detecting"
    var avDrift: String = "Measuring"
    var subtitleRenderer: String = "System"
    var selectedPlayerOverride: String = "Auto"
    var effectivePlayerEngine: String = "Unknown"
    var forceVLCSurface: String = "false"
    var forceKSPlayerSurface: String = "false"
    var finalPlaybackURLType: String = "Unknown"
    var cbsMetadataSignal: String = "unavailable"
    var channelsTimingRiskSignal: String = "unavailable"
    var cbsProfileActive: String = "unavailable"
    var hlsRewriteSucceeded: String = "unavailable"
    var cbsOriginalURLType: String = "unavailable"
    var cbsFinalURLType: String = "unavailable"
    var fallbackReason: String = "None"
    var hardwareAccelerationSetting: String = DebridHardwareAccelerationSetting.auto.diagnosticsName
    var activeDecoder: String = "Unknown"
    var renderer: String = "Unknown"
    var hardwareFallbackReason: String = "None"
}

enum DebridPlaybackDiagnosticsFactory {
    static func make(engine: String, profile: NativePlaybackProfile, controlsVisible: Bool, isPlaying: Bool, hardwareAcceleration: DebridHardwareAccelerationSetting = .auto) -> DebridPlaybackDiagnostics {
        let isKS = engine.lowercased().contains("ksplayer")
        let isVLC = engine.lowercased().contains("vlc")
        let render = isKS ? "Metal" : (isVLC ? "VLC drawable" : "AVPlayerLayer")
        let decoder: String = {
            if hardwareAcceleration == .forceOff {
                if isKS || isVLC { return "Software" }
                return "VideoToolbox"
            }
            if isKS || isVLC { return "VideoToolbox" }
            return "VideoToolbox"
        }()
        let hw: String = {
            switch hardwareAcceleration {
            case .auto: return isKS ? "Auto / preferred" : (isVLC ? "Auto / engine-managed" : "Apple native")
            case .forceOn: return isKS ? "Force On / hardware preferred" : (isVLC ? "Force On / best effort" : "Apple native")
            case .forceOff: return (isKS || isVLC) ? "Force Off / software decode" : "Apple native; software-only not exposed"
            }
        }()
        let subtitleRenderer = isVLC ? "libVLC/default" : "System/default"
        let fps = UniversalCodecSupport.inferredSourceFPS(for: profile)
        let dropped = isPlaying ? "Engine monitor" : "0 idle"
        var noteBits: [String] = []
        noteBits.append("content cadence")
        if profile.isHLS { noteBits.append("HLS") }
        if profile.isLikelyHDR { noteBits.append("HDR/DV hint") }
        if profile.isMatroskaOrUnsupportedContainer { noteBits.append("MKV/container fallback risk") }
        if !controlsVisible { noteBits.append("overlay idle") } else { noteBits.append("overlay visible") }
        let hint = profile.normalizedHint
        let video: String = {
            if hint.contains("hevc") || hint.contains("h265") || hint.contains("h.265") { return "HEVC/H.265" }
            if hint.contains("h264") || hint.contains("h.264") || hint.contains("avc") { return "H.264/AVC" }
            if profile.isHLS { return "HLS video" }
            return "Engine-reported"
        }()
        let audio: String = {
            if hint.contains("ac3") || hint.contains("eac3") || hint.contains("e-ac3") || hint.contains("dolby") { return "AC3/E-AC3 hint" }
            if hint.contains("aac") { return "AAC hint" }
            if hint.contains("mp2") || hint.contains("mpeg audio") { return "MP2/MPEG audio hint" }
            return "Engine-reported"
        }()
        let audioChannels: String = {
            if hint.contains("5.1") || hint.contains("6ch") { return "5.1 / 6ch hint" }
            if hint.contains("2.0") || hint.contains("stereo") || hint.contains("2ch") { return "Stereo / 2ch hint" }
            if hint.contains("mono") || hint.contains("1ch") { return "Mono / 1ch hint" }
            return "Engine-reported"
        }()
        let sampleRate: String = {
            if hint.contains("48khz") || hint.contains("48000") { return "48 kHz hint" }
            if hint.contains("44.1khz") || hint.contains("44100") { return "44.1 kHz hint" }
            return "Engine-reported"
        }()
        let scan: String = {
            if hint.contains("1080i") || hint.contains("interlaced") || hint.contains("59.94i") || hint.contains("60i") { return "Interlaced hint" }
            if hint.contains("1080p") || hint.contains("720p") || hint.contains("2160p") { return "Progressive hint" }
            return profile.isHLS ? "HLS unknown" : "Unknown"
        }()
        let drift = isPlaying ? (isVLC ? "Estimating: VLC clock/PCR" : "Estimating: renderer clock") : "Paused"
        var diagnostics = DebridPlaybackDiagnostics(activeEngine: engine, hwDecode: hw, renderBackend: render, decoder: decoder, fps: fps, droppedFrames: dropped, notes: noteBits.joined(separator: " • "), videoCodec: video, audioCodec: audio, audioChannels: audioChannels, sampleRate: sampleRate, scanType: scan, avDrift: drift, subtitleRenderer: subtitleRenderer)
        diagnostics.hardwareAccelerationSetting = hardwareAcceleration.diagnosticsName
        diagnostics.activeDecoder = decoder
        diagnostics.renderer = render
        if hardwareAcceleration == .forceOff && !isKS && !isVLC {
            diagnostics.hardwareFallbackReason = "AVPlayer does not expose a software-only tvOS override."
        }
        return diagnostics
    }
}

struct UniversalVideoSurface: View {
    let url: URL
    let avPlayer: AVPlayer?
    let videoFitMode: DebridVideoFitMode
    var forceVLC: Bool = true
    var routeHint: String = ""
    var vlcShouldPlay: Bool = true
    var vlcSeekSerial: Int = 0
    var vlcSeekSeconds: Double = 0
    var vlcSurfaceToken: Int = 0
    var ksShouldPlay: Bool = true
    // vBRDC085: explicit Play pulse for confirmed automatic resume, independent of
    // whether the Boolean shouldPlay value changed.
    var ksPlayAssertionSerial: Int = 0
    var ksSeekSerial: Int = 0
    var ksSeekSeconds: Double = 0
    var ksReloadToken: Int = 0
    var ksStartTimeSeconds: Double = 0
    var ksSeekIsAbsolute: Bool = false
    var preferAetherEngine: Bool = false
    var preferKSPlayer: Bool = true
    var preferAVFoundation: Bool = false
    var isLiveStream: Bool = false
    var playbackSessionID: UUID? = nil
    var httpHeaders: [String: String] = [:]
    var externalAudioURL: URL? = nil
    var externalAudioOffsetMS: Int = 0
    var externalAudioTrackIndex: Int? = nil
    var externalAudioHTTPHeaders: [String: String] = [:]
    var onKSExternalAudioReady: (() -> Void)? = nil
    var onKSExternalAudioFailure: ((String) -> Void)? = nil
    var enableDisplayMatch: Bool = false
    var displayMatchIsLive: Bool = false
    var hardwareAcceleration: DebridHardwareAccelerationSetting = .auto
    var ksSelectedAudioTrackIndex: Int? = nil
    var ksSelectedSubtitleTrackIndex: Int? = nil
    var ksSelectedExternalSubtitleURL: URL? = nil
    var ksSubtitleDelayMS: Int = 0
    var ksTrackSelectionSerial: Int = 0
    // Phase 15: VOD-only gain. Live TV/trailers and every existing call site default to 0 dB.
    var ksAudioGainDB: Double = 0
    var aetherSelectedAudioTrackID: Int? = nil
    var aetherSelectedSubtitleTrackID: Int? = nil
    var aetherTrackSelectionSerial: Int = 0
    var onPlaybackTimeUpdate: ((Double, Double) -> Void)? = nil
    var onAetherFirstFrameReady: (() -> Void)? = nil
    var onAetherBufferingChanged: ((Bool) -> Void)? = nil
    var onAetherPlaybackFailure: ((String) -> Void)? = nil
    var onAetherPlaybackEnded: (() -> Void)? = nil
    var onAetherRouteChanged: ((String) -> Void)? = nil
    var onAetherTracksDiscovered: (([[String: Any]], [[String: Any]]) -> Void)? = nil
    var onAetherSubtitleTextChanged: ((String) -> Void)? = nil
    var onKSBufferUpdate: ((Double, Double) -> Void)? = nil
    var onKSTracksDiscovered: (([RealMediaTrackOption], [RealMediaTrackOption]) -> Void)? = nil
    var onKSPlaybackFailure: ((String) -> Void)? = nil
    var onKSPlaybackEnded: (() -> Void)? = nil
    // vBRDC043: Skip Intro signals are produced entirely by the active Apple TV player.
    // Chapters are local container metadata; fingerprints are tiny irreversible audio summaries.
    var onKSChaptersDiscovered: (([PlaybackChapterMarker]) -> Void)? = nil
    var onKSAudioFingerprintSample: ((PlaybackAudioFingerprintSample) -> Void)? = nil

    var body: some View {
        DebridVideoFitContainer(mode: videoFitMode) {
            engineSurface
        }
    }

    private var engineSurface: AnyView {
        if preferAetherEngine {
            // vBRDC251: Aether is runtime-loaded from the signed embedded bridge only when
            // playback asks for it. Keep the browsing app executable free of an eager Aether
            // linkage; a runtime load failure is reported through the existing KS fallback lane.
            return AnyView(
                PlaybackKitAetherHost(
                    url: url,
                    shouldPlay: ksShouldPlay,
                    playAssertionSerial: ksPlayAssertionSerial,
                    seekSerial: ksSeekSerial,
                    seekSeconds: ksSeekSeconds,
                    seekIsAbsolute: ksSeekIsAbsolute,
                    reloadToken: ksReloadToken,
                    startTimeSeconds: ksStartTimeSeconds,
                    isLiveStream: isLiveStream,
                    playbackSessionID: playbackSessionID,
                    httpHeaders: httpHeaders,
                    // vBRDC255 Phase 4: keep Aether from changing the system output
                    // dynamic-range/display mode while SwiftUI VOD artwork/chrome is on screen.
                    // This removes the Aether-only SDR artwork color shift. Phase 5 owns the
                    // final HDR/Dolby Vision/frame-rate policy and can re-enable matching only
                    // behind a renderer-safe presentation transition.
                    enableDisplayMatch: false,
                    selectedAudioTrackID: aetherSelectedAudioTrackID,
                    selectedSubtitleTrackID: aetherSelectedSubtitleTrackID,
                    trackSelectionSerial: aetherTrackSelectionSerial,
                    onPlaybackTimeUpdate: onPlaybackTimeUpdate,
                    onBufferUpdate: onKSBufferUpdate,
                    onBufferingChanged: onAetherBufferingChanged,
                    onFirstFrameReady: onAetherFirstFrameReady,
                    onPlaybackFailure: onAetherPlaybackFailure,
                    onPlaybackEnded: onAetherPlaybackEnded,
                    onRouteChanged: onAetherRouteChanged,
                    onTracksDiscovered: onAetherTracksDiscovered,
                    onSubtitleTextChanged: onAetherSubtitleTextChanged
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            )
        } else if preferAVFoundation {
            return AnyView(
                AVPlayerControllerSurface(player: avPlayer, videoGravity: videoFitMode.avVideoGravity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            )
        } else if preferKSPlayer {
            #if canImport(KSPlayer)
            return AnyView(
                PlaybackKitKSPlayerHost(url: url, shouldPlay: ksShouldPlay, playAssertionSerial: ksPlayAssertionSerial, seekSerial: ksSeekSerial, seekSeconds: ksSeekSeconds, seekIsAbsolute: ksSeekIsAbsolute, reloadToken: ksReloadToken, startTimeSeconds: ksStartTimeSeconds, externalAudioURL: externalAudioURL, externalAudioOffsetMS: externalAudioOffsetMS, externalAudioTrackIndex: externalAudioTrackIndex, externalAudioHTTPHeaders: externalAudioHTTPHeaders, contentMode: videoFitMode.uiContentMode, isLiveStream: isLiveStream, playbackSessionID: playbackSessionID, routeHint: routeHint, httpHeaders: httpHeaders, enableDisplayMatch: enableDisplayMatch, displayMatchIsLive: displayMatchIsLive, selectedAudioTrackIndex: ksSelectedAudioTrackIndex, selectedSubtitleTrackIndex: ksSelectedSubtitleTrackIndex, selectedExternalSubtitleURL: ksSelectedExternalSubtitleURL, subtitleDelayMS: ksSubtitleDelayMS, trackSelectionSerial: ksTrackSelectionSerial, audioGainDB: ksAudioGainDB, onPlaybackTimeUpdate: onPlaybackTimeUpdate, onBufferUpdate: onKSBufferUpdate, onTracksDiscovered: onKSTracksDiscovered, onPlaybackFailure: onKSPlaybackFailure, onPlaybackEnded: onKSPlaybackEnded, onExternalAudioReady: onKSExternalAudioReady, onExternalAudioFailure: onKSExternalAudioFailure, onChaptersDiscovered: onKSChaptersDiscovered, onAudioFingerprintSample: onKSAudioFingerprintSample)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            )
            #else
            return AnyView(
                MissingInternalEngineSurface(message: "KSPlayer/FFmpeg/Metal was not compiled into this IPA. Use VLC Internal while the KSPlayer package resolves.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            )
            #endif
        } else {
            #if canImport(TVVLCKit)
            return AnyView(
                TVVLCKitVideoSurface(url: url, shouldPlay: vlcShouldPlay, seekSerial: vlcSeekSerial, seekSeconds: vlcSeekSeconds, seekIsAbsolute: false, reloadToken: vlcSurfaceToken, isLiveStream: isLiveStream, externalAudioURL: externalAudioURL, externalAudioOffsetMS: externalAudioOffsetMS, hardwareAcceleration: hardwareAcceleration, contentMode: videoFitMode.uiContentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            )
            #else
            return AnyView(
                MissingInternalEngineSurface(message: "TVVLCKit/libVLC was not compiled into this IPA. Use KSPlayer Internal or external Infuse/VLC/SenPlayer.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            )
            #endif
        }
    }
}


// Phase 12: KSPlayer surface implementation moved into the PlaybackKit source tree.

struct MissingInternalEngineSurface: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Text("Internal Engine Missing")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                Text(message)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 980)
            }
            .foregroundStyle(.white)
            .padding(42)
        }
    }
}

#if canImport(TVVLCKit)
struct TVVLCKitVideoSurface: UIViewRepresentable {
    let url: URL
    let shouldPlay: Bool
    let seekSerial: Int
    let seekSeconds: Double
    let seekIsAbsolute: Bool
    let reloadToken: Int
    var isLiveStream: Bool = false
    var externalAudioURL: URL? = nil
    var externalAudioOffsetMS: Int = 0
    var hardwareAcceleration: DebridHardwareAccelerationSetting = .auto
    var contentMode: UIView.ContentMode = .scaleAspectFit

    final class Coordinator {
        let player = VLCMediaPlayer()
        var currentURL: URL?
        var lastSeekSerial: Int = 0
        var lastReloadToken: Int = -1
        var currentStartTimeSeconds: Double = 0
        var currentExternalAudioURL: URL?
        var currentExternalAudioOffsetMS: Int = 0
    }

    final class VLCView: UIView {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VLCView {
        let view = VLCView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        configure(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: VLCView, context: Context) {
        configure(view: view, coordinator: context.coordinator)
    }

    private func configure(view: VLCView, coordinator: Coordinator) {
        // v129: Always attach the drawable before playback. Without this, TVVLCKit can start
        // decoding audio before the tvOS UIView is attached, causing black video until VLC is
        // selected manually.
        view.contentMode = contentMode
        switch contentMode {
        case .scaleAspectFill: view.layer.contentsGravity = .resizeAspectFill
        case .scaleToFill: view.layer.contentsGravity = .resize
        default: view.layer.contentsGravity = .resizeAspect
        }
        coordinator.player.drawable = view

        let shouldReload = coordinator.currentURL != url || coordinator.lastReloadToken != reloadToken
        if shouldReload {
            coordinator.currentURL = url
            coordinator.lastReloadToken = reloadToken
            coordinator.lastSeekSerial = seekSerial
            coordinator.player.stop()
            coordinator.player.drawable = view

            let media = VLCMedia(url: url)
            let liveOptions = [
                "network-caching": "1800",
                "file-caching": "1200",
                "live-caching": "1800",
                "clock-jitter": "500",
                "clock-synchro": "1"
            ]
            let vodOptions = [
                "network-caching": "1200",
                "file-caching": "1200",
                "live-caching": "900",
                "clock-jitter": "0",
                "clock-synchro": "1"
            ]
            var options = isLiveStream ? liveOptions : vodOptions
            options.merge([
                "http-reconnect": "1",
                "audio-language": "eng,en",
                "sub-language": "",
                "no-spu": "1",
                "drop-late-frames": "1",
                "skip-frames": "1"
            ]) { _, new in new }
            switch hardwareAcceleration {
            case .auto:
                options["avcodec-hw"] = "any"
            case .forceOn:
                options["avcodec-hw"] = "any"
                print("[HardwareAcceleration] VLC Force On: requesting TVVLCKit/libVLC hardware decode when available.")
            case .forceOff:
                options["avcodec-hw"] = "none"
                print("[HardwareAcceleration] VLC Force Off: requesting software decode.")
            }
            media.addOptions(options)
            coordinator.player.media = media

            if shouldPlay {
                coordinator.player.play()
                for delay in [0.20, 0.85, 1.80] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        coordinator.player.drawable = view
                        if coordinator.currentURL == url && !coordinator.player.isPlaying {
                            coordinator.player.play()
                        }
                    }
                }
            }
        }

        if seekSerial != coordinator.lastSeekSerial {
            coordinator.lastSeekSerial = seekSerial
            let target = max(0, coordinator.player.time.intValue + Int32(seekSeconds * 1000.0))
            coordinator.player.time = VLCTime(int: target)
        }

        if shouldPlay {
            if !coordinator.player.isPlaying {
                coordinator.player.drawable = view
                coordinator.player.play()
            }
        } else {
            if coordinator.player.isPlaying { coordinator.player.pause() }
        }
    }

    static func dismantleUIView(_ uiView: VLCView, coordinator: Coordinator) {
        coordinator.player.stop()
    }
}
#endif


// v106: AVPlayerViewController-backed surface used only as a rendering container.
// Apple transport controls remain disabled; Debrid Channels draws its own overlay.
// resizeAspect is the default so video keeps the source aspect ratio and does not crop/stretch.
struct AVPlayerControllerSurface: UIViewControllerRepresentable {
    let player: AVPlayer?
    let videoGravity: AVLayerVideoGravity

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity
        controller.view.backgroundColor = .black
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

// DEBRID_CHANNELS_TVOS_BUILD_V160_VOD_UI_ARTWORK_CONTROLS_CAREFUL
