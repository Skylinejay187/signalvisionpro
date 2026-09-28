import Foundation
import SwiftUI
import UIKit
import Darwin

private enum DebridAetherRuntimeEvent {
    static let time = Notification.Name("DebridChannels.Aether.time")
    static let buffer = Notification.Name("DebridChannels.Aether.buffer")
    static let buffering = Notification.Name("DebridChannels.Aether.buffering")
    static let firstFrame = Notification.Name("DebridChannels.Aether.firstFrame")
    static let failure = Notification.Name("DebridChannels.Aether.failure")
    static let ended = Notification.Name("DebridChannels.Aether.ended")
    static let route = Notification.Name("DebridChannels.Aether.route")
    static let tracks = Notification.Name("DebridChannels.Aether.tracks")
    static let subtitleText = Notification.Name("DebridChannels.Aether.subtitleText")
}

/// vBRDC252: Xcode/SwiftPM owns native embedding of the bridge and its transitive Aether
/// frameworks. The app still creates no Aether engine/player object until an Aether playback
/// surface is requested; this preserves standard signed packaging for ATVLoadly/Signulous.
@MainActor
private final class DebridAetherRuntimeLoader {
    static let shared = DebridAetherRuntimeLoader()

    private typealias HostFactory = @convention(c) () -> UnsafeMutableRawPointer?
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var hostFactory: HostFactory?
    private(set) var lastError: String?

    private init() {}

    func makeHostView() -> UIView? {
        guard loadIfNeeded(), let hostFactory else { return nil }
        guard let pointer = hostFactory() else {
            lastError = "AetherPlaybackBridge factory returned no view."
            return nil
        }
        let view = Unmanaged<UIView>.fromOpaque(pointer).takeRetainedValue()
        // vBRDC255 Phase 4: the bridge is a presentation island. Keep SwiftUI/UIKit SDR
        // artwork outside it from inheriting translucent/elevated-black presentation effects.
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = true
        view.layer.backgroundColor = UIColor.black.cgColor
        view.layer.masksToBounds = true
        view.layer.shadowOpacity = 0
        view.layer.shadowRadius = 0
        view.layer.shadowOffset = .zero
        view.layer.compositingFilter = nil
        view.layer.filters = nil
        return view
    }

    private func loadIfNeeded() -> Bool {
        if frameworkHandle != nil, hostFactory != nil { return true }

        guard let frameworksURL = Bundle.main.privateFrameworksURL else {
            lastError = "The app bundle has no Frameworks directory."
            return false
        }
        let binaryURL = frameworksURL
            .appendingPathComponent("AetherPlaybackBridge.framework", isDirectory: true)
            .appendingPathComponent("AetherPlaybackBridge", isDirectory: false)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            lastError = "AetherPlaybackBridge.framework is missing from the installed app."
            return false
        }

        _ = dlerror()
        guard let handle = dlopen(binaryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            lastError = dlerror().map { String(cString: $0) } ?? "dlopen failed for AetherPlaybackBridge."
            return false
        }
        guard let symbol = dlsym(handle, "DebridAetherCreateHostView") else {
            lastError = dlerror().map { String(cString: $0) } ?? "AetherPlaybackBridge factory symbol is missing."
            dlclose(handle)
            return false
        }

        frameworkHandle = handle
        hostFactory = unsafeBitCast(symbol, to: HostFactory.self)
        lastError = nil
        return true
    }
}

/// Aether surface with late object creation. There is intentionally no `import AetherPlaybackBridge`
/// here; the app communicates through KVC/selectors + NotificationCenter. The framework graph is
/// natively embedded/linked by Xcode, while Aether engine/player objects are created only on demand.
struct PlaybackKitAetherHost: UIViewRepresentable {
    let url: URL
    let shouldPlay: Bool
    let playAssertionSerial: Int
    let seekSerial: Int
    let seekSeconds: Double
    let seekIsAbsolute: Bool
    let reloadToken: Int
    let startTimeSeconds: Double
    var isLiveStream: Bool = false
    var playbackSessionID: UUID? = nil
    var httpHeaders: [String: String] = [:]
    var enableDisplayMatch: Bool = true
    var videoGravityRaw: String = "resizeAspect"
    var selectedAudioTrackID: Int? = nil
    var selectedSubtitleTrackID: Int? = nil
    var trackSelectionSerial: Int = 0
    var onPlaybackTimeUpdate: ((Double, Double) -> Void)? = nil
    var onBufferUpdate: ((Double, Double) -> Void)? = nil
    var onBufferingChanged: ((Bool) -> Void)? = nil
    var onFirstFrameReady: (() -> Void)? = nil
    var onPlaybackFailure: ((String) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onRouteChanged: ((String) -> Void)? = nil
    var onTracksDiscovered: (([[String: Any]], [[String: Any]]) -> Void)? = nil
    var onSubtitleTextChanged: ((String) -> Void)? = nil

    @MainActor
    final class Coordinator: PlaybackRenderSurfaceLifecycleOwner {
        var currentURL: URL?
        let surfaceID = UUID()
        var registration: PlaybackRenderSurfaceRegistration?
        weak var hostView: UIView?
        var currentTime: Double = 0
        var lastReloadToken = -1
        var lastSeekSerial = 0
        var lastPlayAssertionSerial = 0
        var lastShouldPlay = false
        var lastTrackSelectionSerial = -1
        var isAetherHost = false
        var observers: [NSObjectProtocol] = []
        var onPlaybackTimeUpdate: ((Double, Double) -> Void)?
        var onBufferUpdate: ((Double, Double) -> Void)?
        var onBufferingChanged: ((Bool) -> Void)?
        var onFirstFrameReady: (() -> Void)?
        var onPlaybackFailure: ((String) -> Void)?
        var onPlaybackEnded: (() -> Void)?
        var onRouteChanged: ((String) -> Void)?
        var onTracksDiscovered: (([[String: Any]], [[String: Any]]) -> Void)?
        var onSubtitleTextChanged: ((String) -> Void)?

        func installObservers(for view: UIView) {
            removeObservers()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.time, object: view, queue: .main) { [weak self] note in
                guard let self else { return }
                let current = (note.userInfo?["current"] as? NSNumber)?.doubleValue ?? 0
                let duration = (note.userInfo?["duration"] as? NSNumber)?.doubleValue ?? 0
                self.currentTime = current
                self.onPlaybackTimeUpdate?(current, duration)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.buffer, object: view, queue: .main) { [weak self] note in
                let buffered = (note.userInfo?["buffered"] as? NSNumber)?.doubleValue ?? 0
                let duration = (note.userInfo?["duration"] as? NSNumber)?.doubleValue ?? 0
                self?.onBufferUpdate?(buffered, duration)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.buffering, object: view, queue: .main) { [weak self] note in
                let buffering = (note.userInfo?["isBuffering"] as? NSNumber)?.boolValue ?? false
                self?.onBufferingChanged?(buffering)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.firstFrame, object: view, queue: .main) { [weak self] _ in
                self?.onFirstFrameReady?()
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.failure, object: view, queue: .main) { [weak self] note in
                let message = note.userInfo?["message"] as? String ?? "AetherEngine runtime failure."
                self?.onPlaybackFailure?(message)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.ended, object: view, queue: .main) { [weak self] _ in
                self?.onPlaybackEnded?()
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.route, object: view, queue: .main) { [weak self] note in
                let route = note.userInfo?["route"] as? String ?? "unknown"
                let reason = note.userInfo?["reason"] as? String
                self?.onRouteChanged?(reason.map { "\(route) • \($0)" } ?? route)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.tracks, object: view, queue: .main) { [weak self] note in
                let audio = note.userInfo?["audio"] as? [[String: Any]] ?? []
                let subtitles = note.userInfo?["subtitles"] as? [[String: Any]] ?? []
                self?.onTracksDiscovered?(audio, subtitles)
            })
            observers.append(center.addObserver(forName: DebridAetherRuntimeEvent.subtitleText, object: view, queue: .main) { [weak self] note in
                self?.onSubtitleTextChanged?(note.userInfo?["text"] as? String ?? "")
            })
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
            observers.removeAll()
        }

        func playbackKitStopAndReleaseSurface() {
            guard let hostView else { return }
            PlaybackKitAetherHost.performNoArgumentSelector("aetherStop", on: hostView)
            removeObservers()
            registration = nil
        }

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.onPlaybackTimeUpdate = onPlaybackTimeUpdate
        context.coordinator.onBufferUpdate = onBufferUpdate
        context.coordinator.onBufferingChanged = onBufferingChanged
        context.coordinator.onFirstFrameReady = onFirstFrameReady
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onRouteChanged = onRouteChanged
        context.coordinator.onTracksDiscovered = onTracksDiscovered
        context.coordinator.onSubtitleTextChanged = onSubtitleTextChanged

        guard let view = DebridAetherRuntimeLoader.shared.makeHostView() else {
            let placeholder = UIView(frame: .zero)
            placeholder.backgroundColor = .black
            placeholder.isOpaque = true
            placeholder.layer.backgroundColor = UIColor.black.cgColor
            let message = DebridAetherRuntimeLoader.shared.lastError ?? "AetherEngine runtime bridge could not be loaded."
            DispatchQueue.main.async { onPlaybackFailure?(message) }
            return placeholder
        }

        context.coordinator.isAetherHost = true
        context.coordinator.hostView = view
        context.coordinator.installObservers(for: view)
        configure(view: view, coordinator: context.coordinator)
        if let playbackSessionID {
            context.coordinator.registration = PlaybackController.shared.registerRenderSurfaceCandidate(
                view,
                surfaceID: context.coordinator.surfaceID,
                sessionID: playbackSessionID,
                lifecycleOwner: context.coordinator
            )
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onPlaybackTimeUpdate = onPlaybackTimeUpdate
        context.coordinator.onBufferUpdate = onBufferUpdate
        context.coordinator.onBufferingChanged = onBufferingChanged
        context.coordinator.onFirstFrameReady = onFirstFrameReady
        context.coordinator.onPlaybackFailure = onPlaybackFailure
        context.coordinator.onPlaybackEnded = onPlaybackEnded
        context.coordinator.onRouteChanged = onRouteChanged
        context.coordinator.onTracksDiscovered = onTracksDiscovered
        context.coordinator.onSubtitleTextChanged = onSubtitleTextChanged
        guard context.coordinator.isAetherHost else { return }
        configure(view: view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if let registration = coordinator.registration,
           PlaybackController.shared.sessionOwnsRenderSurface(registration) {
            // Build 38: the active session may currently be mounted in the immersive theater.
            // SwiftUI dismantling the original anchor must not stop the shared decoder/audio owner.
            return
        }
        if let registration = coordinator.registration {
            PlaybackController.shared.unregisterRenderSurfaceCandidate(view, registration: registration)
            coordinator.registration = nil
        }
        if coordinator.isAetherHost {
            performNoArgumentSelector("aetherStop", on: view)
        }
        coordinator.removeObservers()
    }

    private func configure(view: UIView, coordinator: Coordinator) {
        let needsLoad = coordinator.currentURL != url || coordinator.lastReloadToken != reloadToken
        if needsLoad {
            coordinator.currentURL = url
            coordinator.currentTime = max(0, startTimeSeconds)
            coordinator.lastReloadToken = reloadToken
            coordinator.lastSeekSerial = seekSerial
            coordinator.lastPlayAssertionSerial = playAssertionSerial
            coordinator.lastShouldPlay = shouldPlay

            view.setValue(url.absoluteString, forKey: "configuredURLString")
            view.setValue(NSNumber(value: max(0, startTimeSeconds)), forKey: "configuredStartTimeSeconds")
            view.setValue(NSNumber(value: isLiveStream), forKey: "configuredIsLiveStream")
            view.setValue(httpHeaders as NSDictionary, forKey: "configuredHTTPHeaders")
            view.setValue(NSNumber(value: enableDisplayMatch), forKey: "configuredEnableDisplayMatch")
            view.setValue(videoGravityRaw, forKey: "configuredVideoGravityRaw")
            view.setValue(NSNumber(value: shouldPlay), forKey: "configuredAutoplay")
            view.setValue(NSNumber(value: selectedAudioTrackID ?? -1), forKey: "configuredAudioTrackID")
            view.setValue(NSNumber(value: selectedSubtitleTrackID ?? -1), forKey: "configuredSubtitleTrackID")
            coordinator.lastTrackSelectionSerial = trackSelectionSerial
            Self.performNoArgumentSelector("aetherLoadConfiguredMedia", on: view)
            return
        }

        if seekSerial != coordinator.lastSeekSerial {
            coordinator.lastSeekSerial = seekSerial
            let target = seekIsAbsolute ? max(0, seekSeconds) : max(0, coordinator.currentTime + seekSeconds)
            view.setValue(NSNumber(value: target), forKey: "configuredSeekSeconds")
            Self.performNoArgumentSelector("aetherSeekConfiguredPosition", on: view)
        }

        if trackSelectionSerial != coordinator.lastTrackSelectionSerial {
            coordinator.lastTrackSelectionSerial = trackSelectionSerial
            view.setValue(NSNumber(value: selectedAudioTrackID ?? -1), forKey: "configuredAudioTrackID")
            view.setValue(NSNumber(value: selectedSubtitleTrackID ?? -1), forKey: "configuredSubtitleTrackID")
            Self.performNoArgumentSelector("aetherApplyTrackSelection", on: view)
        }

        if playAssertionSerial != coordinator.lastPlayAssertionSerial {
            coordinator.lastPlayAssertionSerial = playAssertionSerial
            Self.performNoArgumentSelector("aetherPlay", on: view)
        }

        if shouldPlay != coordinator.lastShouldPlay {
            coordinator.lastShouldPlay = shouldPlay
            Self.performNoArgumentSelector(shouldPlay ? "aetherPlay" : "aetherPause", on: view)
        }
    }

    private static func performNoArgumentSelector(_ name: String, on view: UIView) {
        let selector = NSSelectorFromString(name)
        guard view.responds(to: selector) else { return }
        _ = view.perform(selector)
    }
}
