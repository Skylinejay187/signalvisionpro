import Foundation
import UIKit
import AVFoundation
import Combine
@_implementationOnly import AetherEngine

private enum AetherBridgeNotification {
    static let time = Notification.Name("DebridChannels.Aether.time")
    static let buffer = Notification.Name("DebridChannels.Aether.buffer")
    static let buffering = Notification.Name("DebridChannels.Aether.buffering")
    static let firstFrame = Notification.Name("DebridChannels.Aether.firstFrame")
    static let failure = Notification.Name("DebridChannels.Aether.failure")
    static let ended = Notification.Name("DebridChannels.Aether.ended")
    static let liveReset = Notification.Name("DebridChannels.Aether.liveReset")
    static let route = Notification.Name("DebridChannels.Aether.route")
    static let tracks = Notification.Name("DebridChannels.Aether.tracks")
    static let subtitleText = Notification.Name("DebridChannels.Aether.subtitleText")
}

/// Dynamic-framework boundary between Debrid Channels and AetherEngine.
///
/// vBRDC252 keeps this bridge under Xcode/SwiftPM native linking + embedding so its transitive
/// Aether runtime frameworks are packaged and signed correctly.
/// Debrid Channels `dlopen`s the signed framework only when an Aether playback surface is
/// actually requested. That keeps AetherEngine + its namespaced FFmpeg graph completely cold
/// while the user is browsing catalogs or the Live TV grid, while KSPlayer keeps its original
/// FFmpegKit graph in the app executable.
@MainActor
public final class AetherPlaybackHostView: UIView {
    /// vBRDC259: keep recovery inside Aether before conceding the source to KSPlayer.
    /// A healthy route still starts immediately; these rungs are entered only when the
    /// previous Aether route fails or produces no displayable frame.
    private enum LiveRoute: Int {
        case automaticURL
        case hlsIngest
        case softwareDecode

        var label: String {
            switch self {
            case .automaticURL: return "automatic-url"
            case .hlsIngest: return "hls-ingest"
            case .softwareDecode: return "software-decode"
            }
        }
    }
    // KVC/Objective-C runtime configuration surface. The app intentionally does not import
    // this Swift module, so every runtime command crosses only Foundation/UIKit values.
    @objc public dynamic var configuredURLString: String = ""
    @objc public dynamic var configuredStartTimeSeconds: Double = 0
    @objc public dynamic var configuredIsLiveStream: Bool = false
    @objc public dynamic var configuredHTTPHeaders: NSDictionary = [:]
    @objc public dynamic var configuredEnableDisplayMatch: Bool = true
    @objc public dynamic var configuredVideoGravityRaw: String = "resizeAspect"
    @objc public dynamic var configuredAutoplay: Bool = true
    @objc public dynamic var configuredSeekSeconds: Double = 0
    @objc public dynamic var configuredAudioTrackID: Int = -1
    @objc public dynamic var configuredSubtitleTrackID: Int = -1

    private let playerView = AetherPlayerView()
    private var engine: AetherEngine?
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var firstFramePublished = false
    private var failed = false
    // vBRDC280: Aether can surface EOF through more than one state/clock edge.
    // Publish one deterministic completion event per loaded VOD session so the app-side
    // Up Next pipeline is not dependent on one exact enum string from AetherEngine.
    private var endedPublished = false
    private var lastBufferingState: Bool?
    private var lastTimeNotificationAt: TimeInterval = 0
    private var lastTimeNotificationValue: Double = -1
    private var lastBufferNotificationAt: TimeInterval = 0
    private var lastBufferNotificationValue: Double = -1
    private var loadedURL: URL?
    private var loadedOptions: LoadOptions?
    private var liveBaseOptions: LoadOptions?
    private var liveRoute: LiveRoute = .automaticURL
    private var liveSourceLooksHLS = false
    private var liveAttemptSerial: UInt64 = 0
    private var liveRecoveryTask: Task<Void, Never>?
    private var liveRecoveryInFlight = false
    private var liveRetuneTask: Task<Void, Never>?
    private var liveRetuneInFlight = false
    private var liveRetuneCount = 0
    private var lastLiveRetuneAt: TimeInterval = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        bootstrapView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        bootstrapView()
    }

    private func bootstrapView() {
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.masksToBounds = true
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.compositingFilter = nil
        layer.filters = nil

        playerView.backgroundColor = .black
        playerView.isOpaque = true
        playerView.clipsToBounds = true
        playerView.layer.backgroundColor = UIColor.black.cgColor
        playerView.layer.masksToBounds = true
        playerView.layer.shadowOpacity = 0
        playerView.layer.shadowRadius = 0
        playerView.layer.shadowOffset = .zero
        playerView.layer.compositingFilter = nil
        playerView.layer.filters = nil
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // vBRDC255 Phase 4: keep the Aether presentation host a true opaque-black island.
        // Aether may rebuild its renderer while loading/seeking, so reassert only the outer
        // UIKit containers here. Do not mutate the renderer's internal Metal/video layers.
        backgroundColor = .black
        layer.backgroundColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.compositingFilter = nil
        layer.filters = nil
        playerView.backgroundColor = .black
        playerView.layer.backgroundColor = UIColor.black.cgColor
        playerView.layer.shadowOpacity = 0
        playerView.layer.compositingFilter = nil
        playerView.layer.filters = nil
    }

    @objc public func aetherLoadConfiguredMedia() {
        guard let url = URL(string: configuredURLString), !configuredURLString.isEmpty else {
            publishFailure("AetherEngine received an invalid playback URL.")
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in configuredHTTPHeaders {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        load(
            url: url,
            startTimeSeconds: configuredStartTimeSeconds,
            isLiveStream: configuredIsLiveStream,
            httpHeaders: headers,
            enableDisplayMatch: configuredEnableDisplayMatch,
            autoplay: configuredAutoplay
        )
    }

    @objc public func aetherSeekConfiguredPosition() {
        seek(to: configuredSeekSeconds)
    }

    @objc public func aetherPlay() { play() }
    @objc public func aetherPause() { pause() }
    @objc public func aetherStop() { stop() }
    @objc public func aetherApplyTrackSelection() {
        guard let engine else { return }
        if configuredAudioTrackID >= 0 {
            engine.selectAudioTrack(index: configuredAudioTrackID)
        }
        if configuredSubtitleTrackID >= 0 {
            engine.selectSubtitleTrack(index: configuredSubtitleTrackID)
        } else {
            engine.clearSubtitle()
            NotificationCenter.default.post(name: AetherBridgeNotification.subtitleText, object: self, userInfo: ["text": ""])
        }
    }

    public func load(
        url: URL,
        startTimeSeconds: Double,
        isLiveStream: Bool,
        httpHeaders: [String: String],
        enableDisplayMatch: Bool,
        autoplay: Bool
    ) {
        stopSession(advanceGeneration: true)
        failed = false
        endedPublished = false
        firstFramePublished = false
        duration = 0
        currentTime = 0
        lastTimeNotificationAt = 0
        lastTimeNotificationValue = -1
        lastBufferNotificationAt = 0
        lastBufferNotificationValue = -1
        lastBufferingState = nil

        let localGeneration = generation
        do {
            let engine = try AetherEngine()
            self.engine = engine
            switch configuredVideoGravityRaw {
            case "resizeAspectFill":
                engine.videoGravity = .resizeAspectFill
            case "resize":
                engine.videoGravity = .resize
            default:
                engine.videoGravity = .resizeAspect
            }
            engine.bind(view: playerView)
            // Phase 4: binding must not introduce a translucent/elevated-black host around
            // the actual video image. Renderer internals remain owned exclusively by Aether.
            setNeedsLayout()
            layoutIfNeeded()
            installObservers(engine: engine, generation: localGeneration)

            let nativeRemoteHLS = isLiveStream && Self.looksLikeRemoteHLS(url)
            var options = LoadOptions(
                suppressDisplayCriteria: isLiveStream,
                httpHeaders: httpHeaders,
                matchContentEnabled: isLiveStream ? false : enableDisplayMatch,
                isLive: isLiveStream,
                liveJoinProfile: isLiveStream ? .fastZap : .standard,
                nativeRemoteHLS: nativeRemoteHLS,
                nativeRemoteHLSIngestFallback: true,
                preferredAudioLanguages: ["en", "eng"],
                autoplay: autoplay
            )
            if isLiveStream {
                // Aether 6.81: explicitly opt into the live join behavior Debrid Channels needs.
                // `.fastZap` reduces the loopback holdback and `liveJoinStartsImmediately`
                // avoids AVPlayer holding the first live frame while minimizing stalls.
                options.liveJoinStartsImmediately = true
                options.preferredDecodePath = .automatic
                // Bound FFmpeg's live open so a sparse/broken channel cannot spend the engine's
                // 50 MB / 60 s default probe budget before the recovery ladder gets a decision.
                // This remains substantially more generous than the proven KSPlayer live probe.
                options.probesize = 4 * 1024 * 1024
                options.maxAnalyzeDuration = 5 * 1_000_000
            }
            loadedURL = url
            loadedOptions = options
            liveBaseOptions = isLiveStream ? options : nil
            liveSourceLooksHLS = isLiveStream && Self.looksLikeRemoteHLS(url)
            liveRoute = .automaticURL
            liveAttemptSerial = 0
            liveRetuneCount = 0
            lastLiveRetuneAt = 0
            let requestedStart = isLiveStream ? 0 : max(0, startTimeSeconds)

            if isLiveStream {
                startLiveAttempt(
                    engine: engine,
                    url: url,
                    baseOptions: options,
                    route: .automaticURL,
                    generation: localGeneration,
                    reason: "initial live tune"
                )
            } else {
                loadTask = Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine else { return }
                    do {
                        try await engine.load(url: url, options: options)
                        guard !Task.isCancelled, self.generation == localGeneration, self.engine === engine else { return }
                        if requestedStart > 0.25 {
                            await engine.seek(to: requestedStart)
                        }
                        guard !Task.isCancelled, self.generation == localGeneration, self.engine === engine else { return }
                        if autoplay { engine.play() } else { engine.pause() }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled, self.generation == localGeneration else { return }
                        self.publishFailure(error.localizedDescription)
                    }
                }
            }
        } catch {
            publishFailure("AetherEngine initialization failed: \(error.localizedDescription)")
        }
    }

    public func seek(to seconds: Double) {
        guard let engine else { return }
        let localGeneration = generation
        seekTask?.cancel()
        seekTask = Task { @MainActor [weak self, weak engine] in
            guard let self, let engine, self.generation == localGeneration else { return }
            await engine.seek(to: max(0, seconds))
        }
    }

    public func play() { engine?.play() }
    public func pause() { engine?.pause() }
    public func stop() { stopSession(advanceGeneration: true) }

    private func stopSession(advanceGeneration: Bool) {
        if advanceGeneration { generation &+= 1 }
        loadTask?.cancel()
        loadTask = nil
        seekTask?.cancel()
        seekTask = nil
        liveRecoveryTask?.cancel()
        liveRecoveryTask = nil
        liveRecoveryInFlight = false
        liveRetuneTask?.cancel()
        liveRetuneTask = nil
        liveRetuneInFlight = false
        liveAttemptSerial &+= 1
        liveBaseOptions = nil
        liveSourceLooksHLS = false
        loadedURL = nil
        loadedOptions = nil
        cancellables.removeAll()
        engine?.stop()
        engine = nil
        // Leave a deterministic black presentation island behind during teardown/source
        // transitions so a stale HDR/renderer surface cannot bloom through SwiftUI chrome.
        backgroundColor = .black
        playerView.backgroundColor = .black
        layer.backgroundColor = UIColor.black.cgColor
        playerView.layer.backgroundColor = UIColor.black.cgColor
        setNeedsLayout()
    }

    private func installObservers(engine: AetherEngine, generation observedGeneration: UInt64) {
        engine.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] value in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                self.duration = value.isFinite ? max(0, value) : 0
                self.publishTimeNotification(force: true)
            }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] value in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration, value.isFinite else { return }
                self.currentTime = max(0, value)
                self.publishTimeNotification(force: false)
                // vBRDC280: some Aether routes finish at the media clock without ever
                // publishing a literal state description of "ended". Use the same
                // decoder clock as a bounded EOF fallback for non-live VOD. This only
                // fires within 150 ms of a known duration and is one-shot per load.
                self.publishEndedIfNeeded(reason: "clock")
            }
            .store(in: &cancellables)

        engine.clock.$bufferedPosition
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] value in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration, value.isFinite else { return }
                self.publishBufferNotification(position: max(0, value))
            }
            .store(in: &cancellables)

        // Aether's own LiveHost reference explicitly warns that session-ready/state=playing
        // is not first-frame readiness. Lifting Debrid Channels' loading cover from that
        // earlier signal can expose a permanent black surface on live startup.
        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] ready in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration,
                      ready, !self.firstFramePublished else { return }
                self.firstFramePublished = true
                self.liveRecoveryTask?.cancel()
                self.liveRecoveryTask = nil
                self.liveRecoveryInFlight = false
                NotificationCenter.default.post(name: AetherBridgeNotification.firstFrame, object: self)
            }
            .store(in: &cancellables)

        // 6.81 host contract: liveSourceReset is a required retune signal, not a terminal
        // engine error. If it is ignored a channel can sit black/stalled forever while the
        // engine still owns a session. Retune the exact source under a bounded guard.
        engine.liveSourceReset
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                NotificationCenter.default.post(name: AetherBridgeNotification.liveReset, object: self)
                if self.firstFramePublished {
                    self.scheduleLiveRetune(engine: engine, generation: observedGeneration)
                } else {
                    self.advanceLiveRecovery(
                        engine: engine, generation: observedGeneration,
                        reason: "Aether liveSourceReset before first frame"
                    )
                }
            }
            .store(in: &cancellables)

        engine.$playbackPhase
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] phase in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                let value = String(describing: phase).lowercased()
                let buffering = value.contains("loading") || value.contains("rebuffer") || value.contains("stall") || value.contains("seeking")
                self.publishBufferingNotification(buffering)
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] _ in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                self.publishTracks(engine: engine)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] _ in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                self.publishTracks(engine: engine)
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] cues in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                let text = cues.compactMap { Self.extractSubtitleText(from: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
                NotificationCenter.default.post(name: AetherBridgeNotification.subtitleText, object: self, userInfo: ["text": text])
            }
            .store(in: &cancellables)

        engine.$videoRoute
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] route in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                NotificationCenter.default.post(
                    name: AetherBridgeNotification.route,
                    object: self,
                    userInfo: ["route": String(describing: route)]
                )
            }
            .store(in: &cancellables)

        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] state in
                guard let self, let engine, self.engine === engine, self.generation == observedGeneration else { return }
                let value = String(describing: state).lowercased()
                if value.hasPrefix("error") {
                    let detail = engine.errorInfo.map { " | \($0)" } ?? ""
                    if self.loadedOptions?.isLive == true {
                        if self.firstFramePublished {
                            self.scheduleLiveRetune(engine: engine, generation: observedGeneration)
                        } else {
                            self.advanceLiveRecovery(
                                engine: engine, generation: observedGeneration,
                                reason: "Aether state error: \(state)\(detail)"
                            )
                        }
                    } else {
                        self.publishFailure("AetherEngine playback error: \(state)\(detail)")
                    }
                } else if value.contains("ended") || value.contains("finished") || value.contains("completed") {
                    self.publishEndedIfNeeded(reason: "state=\(value)", force: true)
                }
            }
            .store(in: &cancellables)
    }

    private func publishEndedIfNeeded(reason: String, force: Bool = false) {
        guard !endedPublished, loadedOptions?.isLive != true else { return }
        if !force {
            guard duration.isFinite, duration > 30, currentTime.isFinite, currentTime > 5 else { return }
            let remaining = max(0, duration - currentTime)
            guard remaining <= 0.15 else { return }
        }
        endedPublished = true
        publishTimeNotification(force: true)
        NotificationCenter.default.post(
            name: AetherBridgeNotification.ended,
            object: self,
            userInfo: ["reason": reason]
        )
    }

    private func publishTracks(engine: AetherEngine) {
        let audio = engine.audioTracks.enumerated().map { offset, track in
            Self.trackDictionary(track, fallback: "Audio \(offset + 1)")
        }
        let subtitles = engine.subtitleTracks.enumerated().map { offset, track in
            Self.trackDictionary(track, fallback: "Subtitle \(offset + 1)")
        }
        NotificationCenter.default.post(
            name: AetherBridgeNotification.tracks,
            object: self,
            userInfo: ["audio": audio, "subtitles": subtitles]
        )
    }

    private static func trackDictionary(_ track: Any, fallback: String) -> [String: Any] {
        let mirror = Mirror(reflecting: track)
        var id = -1
        var label = fallback
        var language = ""
        var codec = ""
        var isDefault = false
        var isForced = false
        var isHearingImpaired = false
        for child in mirror.children {
            guard let raw = child.label?.lowercased() else { continue }
            if raw == "id", let value = child.value as? Int { id = value }
            if ["title", "name", "displayname", "label"].contains(raw), let value = child.value as? String, !value.isEmpty { label = value }
            if raw == "language", let value = child.value as? String { language = value }
            if raw == "codec", let value = child.value as? String { codec = value }
            if raw == "isdefault", let value = child.value as? Bool { isDefault = value }
            if raw == "isforced", let value = child.value as? Bool { isForced = value }
            if raw == "ishearingimpaired", let value = child.value as? Bool { isHearingImpaired = value }
        }
        return [
            "id": id, "label": label, "language": language, "codec": codec,
            "isDefault": isDefault, "isForced": isForced, "isSDH": isHearingImpaired
        ]
    }

    private static func extractSubtitleText(from value: Any) -> String? {
        var strings: [String] = []
        func walk(_ candidate: Any, depth: Int) {
            guard depth < 8 else { return }
            if let text = candidate as? String {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { strings.append(clean) }
                return
            }
            let mirror = Mirror(reflecting: candidate)
            for child in mirror.children {
                let label = child.label?.lowercased() ?? ""
                if label.contains("font") || label.contains("color") || label.contains("face") { continue }
                walk(child.value, depth: depth + 1)
            }
        }
        walk(value, depth: 0)
        let unique = strings.reduce(into: [String]()) { result, value in
            if result.last != value { result.append(value) }
        }
        return unique.isEmpty ? nil : unique.joined(separator: "")
    }

    private static func looksLikeRemoteHLS(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        if url.pathExtension.lowercased() == "m3u8" { return true }
        if raw.contains(".m3u8") { return true }
        if raw.contains("format=m3u8") || raw.contains("type=m3u8") || raw.contains("extension=m3u8") { return true }
        return false
    }

    private func liveOptions(base: LoadOptions, route: LiveRoute) -> LoadOptions {
        var options = base
        options.isLive = true
        options.liveJoinProfile = .fastZap
        options.liveJoinStartsImmediately = true
        options.nativeRemoteHLSIngestFallback = true
        switch route {
        case .automaticURL:
            options.nativeRemoteHLS = liveSourceLooksHLS
            options.preferredDecodePath = .automatic
        case .hlsIngest:
            options.nativeRemoteHLS = false
            options.preferredDecodePath = .automatic
        case .softwareDecode:
            options.nativeRemoteHLS = false
            options.preferredDecodePath = .software
        }
        return options
    }

    private func liveWatchdogSeconds(for route: LiveRoute) -> Double {
        switch route {
        case .automaticURL: return 7.5
        case .hlsIngest: return 9.0
        case .softwareDecode: return 10.0
        }
    }

    private func postLiveRoute(_ route: LiveRoute, reason: String) {
        NotificationCenter.default.post(
            name: AetherBridgeNotification.route,
            object: self,
            userInfo: ["route": "live/\(route.label)", "reason": reason]
        )
    }

    private func startLiveAttempt(
        engine: AetherEngine,
        url: URL,
        baseOptions: LoadOptions,
        route: LiveRoute,
        generation expectedGeneration: UInt64,
        reason: String
    ) {
        guard self.engine === engine, generation == expectedGeneration else { return }
        liveAttemptSerial &+= 1
        let attempt = liveAttemptSerial
        liveRoute = route
        liveRecoveryInFlight = false
        failed = false
        firstFramePublished = false
        publishBufferingNotification(true)

        let options = liveOptions(base: baseOptions, route: route)
        loadedOptions = options
        postLiveRoute(route, reason: reason)

        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self, weak engine] in
            guard let self, let engine,
                  self.engine === engine,
                  self.generation == expectedGeneration,
                  self.liveAttemptSerial == attempt else { return }
            do {
                if route == .hlsIngest || (route == .softwareDecode && self.liveSourceLooksHLS) {
                    // Explicit ingest is the header-safe IPTV route. Headers ride the master/media
                    // playlists, every segment and AES key instead of depending on AVURLAsset's
                    // redirect behavior. The software rung uses the same ingest but forces Aether's
                    // per-session SoftwarePlaybackHost when VideoToolbox produces ready-but-black.
                    let reader = HLSLiveIngestReader(playlistURL: url, httpHeaders: options.httpHeaders)
                    _ = try await engine.load(
                        source: .custom(reader, formatHint: "mpegts"),
                        options: options
                    )
                } else {
                    _ = try await engine.load(url: url, options: options)
                }
                guard !Task.isCancelled,
                      self.engine === engine,
                      self.generation == expectedGeneration,
                      self.liveAttemptSerial == attempt else { return }
                if options.autoplay { engine.play() } else { engine.pause() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.engine === engine,
                      self.generation == expectedGeneration,
                      self.liveAttemptSerial == attempt else { return }
                self.advanceLiveRecovery(
                    engine: engine,
                    generation: expectedGeneration,
                    reason: "\(route.label) load failed: \(error.localizedDescription)"
                )
            }
        }

        armLiveFirstFrameWatchdog(
            engine: engine,
            generation: expectedGeneration,
            attempt: attempt,
            route: route
        )
    }

    private func armLiveFirstFrameWatchdog(
        engine: AetherEngine,
        generation expectedGeneration: UInt64,
        attempt: UInt64,
        route: LiveRoute
    ) {
        liveRecoveryTask?.cancel()
        let delay = liveWatchdogSeconds(for: route)
        liveRecoveryTask = Task { @MainActor [weak self, weak engine] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self, let engine,
                  self.engine === engine,
                  self.generation == expectedGeneration,
                  self.liveAttemptSerial == attempt,
                  !self.firstFramePublished else { return }
            self.advanceLiveRecovery(
                engine: engine,
                generation: expectedGeneration,
                reason: "\(route.label) produced no displayable frame in \(String(format: "%.1f", delay))s"
            )
        }
    }

    private func nextLiveRoute(after route: LiveRoute) -> LiveRoute? {
        switch route {
        case .automaticURL:
            return liveSourceLooksHLS ? .hlsIngest : .softwareDecode
        case .hlsIngest:
            return .softwareDecode
        case .softwareDecode:
            return nil
        }
    }

    private func advanceLiveRecovery(
        engine: AetherEngine,
        generation expectedGeneration: UInt64,
        reason: String
    ) {
        guard self.engine === engine,
              generation == expectedGeneration,
              loadedOptions?.isLive == true,
              !firstFramePublished,
              !liveRecoveryInFlight else { return }
        liveRecoveryInFlight = true
        liveRecoveryTask?.cancel()
        liveRecoveryTask = nil

        guard let base = liveBaseOptions, let url = loadedURL,
              let next = nextLiveRoute(after: liveRoute) else {
            liveRecoveryInFlight = false
            publishFailure("AetherEngine Live TV exhausted native/ingest/software routes. \(reason)")
            return
        }

        startLiveAttempt(
            engine: engine,
            url: url,
            baseOptions: base,
            route: next,
            generation: expectedGeneration,
            reason: reason
        )
    }

    private func scheduleLiveRetune(engine: AetherEngine, generation expectedGeneration: UInt64) {
        guard let url = loadedURL, let base = liveBaseOptions, loadedOptions?.isLive == true else { return }
        guard !liveRetuneInFlight else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let tooSoon = lastLiveRetuneAt > 0 && (now - lastLiveRetuneAt) < 20
        guard liveRetuneCount < 3, !tooSoon else {
            publishFailure("AetherEngine live source reset was exhausted; KSPlayer fallback required.")
            return
        }

        liveRetuneInFlight = true
        liveRetuneCount += 1
        lastLiveRetuneAt = now
        let route = liveRoute
        liveRetuneTask?.cancel()
        liveRetuneTask = Task { @MainActor [weak self, weak engine] in
            guard let self, let engine, self.engine === engine, self.generation == expectedGeneration else { return }
            self.liveRetuneInFlight = false
            self.startLiveAttempt(
                engine: engine,
                url: url,
                baseOptions: base,
                route: route,
                generation: expectedGeneration,
                reason: "liveSourceReset retune #\(self.liveRetuneCount)"
            )
        }
    }

    private func publishTimeNotification(force: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        // vBRDC256 Phase 5: decoder clocks can publish at frame cadence. The app only
        // needs a smooth UI/session clock, not 30–60 MainActor invalidations per second.
        // Coalesce to roughly 3 Hz while still forcing duration/seek boundary updates.
        let movedEnough = abs(currentTime - lastTimeNotificationValue) >= 0.30
        guard force || movedEnough || uptime - lastTimeNotificationAt >= 0.34 else { return }
        lastTimeNotificationAt = uptime
        lastTimeNotificationValue = currentTime
        NotificationCenter.default.post(
            name: AetherBridgeNotification.time,
            object: self,
            userInfo: ["current": currentTime, "duration": duration]
        )
    }

    private func publishBufferNotification(position: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        // Buffer progress is presentation metadata; it does not need decoder-rate
        // publication. A slower cadence removes avoidable SwiftUI/Now Playing pressure.
        let movedEnough = abs(position - lastBufferNotificationValue) >= 0.75
        guard movedEnough || uptime - lastBufferNotificationAt >= 0.80 else { return }
        lastBufferNotificationAt = uptime
        lastBufferNotificationValue = position
        NotificationCenter.default.post(
            name: AetherBridgeNotification.buffer,
            object: self,
            userInfo: ["buffered": position, "duration": duration]
        )
    }

    private func publishBufferingNotification(_ buffering: Bool) {
        guard lastBufferingState != buffering else { return }
        lastBufferingState = buffering
        NotificationCenter.default.post(
            name: AetherBridgeNotification.buffering,
            object: self,
            userInfo: ["isBuffering": buffering]
        )
    }

    private func publishFailure(_ message: String) {
        guard !failed else { return }
        failed = true
        NotificationCenter.default.post(
            name: AetherBridgeNotification.failure,
            object: self,
            userInfo: ["message": message]
        )
    }
}

/// C ABI factory used by the app after `dlopen`. Returning an opaque retained UIView keeps
/// the app target free of any Swift symbol reference to AetherPlaybackBridge.
@_cdecl("DebridAetherCreateHostView")
public func DebridAetherCreateHostView() -> UnsafeMutableRawPointer {
    let view = MainActor.assumeIsolated { AetherPlaybackHostView(frame: .zero) }
    return Unmanaged.passRetained(view).toOpaque()
}
