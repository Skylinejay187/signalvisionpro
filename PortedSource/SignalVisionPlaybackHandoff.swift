import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// Build 38 single-owner theater handoff.
/// The theater never opens the media URL itself. KSPlayer/Aether keep their existing
/// decoder/audio owner and their registered render surface is temporarily mounted into
/// the immersive screen attachment. AVFoundation shares the already-created AVPlayer.
@MainActor
final class SignalVisionPlaybackHandoff: ObservableObject {
    static let shared = SignalVisionPlaybackHandoff()

    enum Engine: String {
        case avFoundation = "AVPlayer"
        case ksPlayer = "KSPlayer"
        case aether = "AetherEngine"
        case unknown = "Playback"
    }

    enum Command: String {
        case togglePlayPause, rewind, fastForward, audio, subtitles, productionRatings,
             spotlightHub, exitTheater, exitPlayback
    }

    static let commandNotification = Notification.Name("SignalVision.Theater.PlaybackCommand")

    @Published private(set) var sessionID: UUID?
    @Published private(set) var engine: Engine = .unknown
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasReusableRenderSurface = false

    private(set) var avPlayer: AVPlayer?
    private var lastClockPublish = Date.distantPast

    private init() {}

    func begin(sessionID: UUID, engineName: String, avPlayer: AVPlayer?) {
        self.sessionID = sessionID
        self.engine = Self.engine(from: engineName)
        self.avPlayer = avPlayer
        self.hasReusableRenderSurface = PlaybackController.shared.hasRegisteredRenderSurface(sessionID: sessionID)
    }

    func updateEngine(_ engineName: String, avPlayer: AVPlayer?) {
        engine = Self.engine(from: engineName)
        if let avPlayer { self.avPlayer = avPlayer }
        if let sessionID {
            hasReusableRenderSurface = PlaybackController.shared.hasRegisteredRenderSurface(sessionID: sessionID)
        }
    }

    func updateClock(elapsed: Double, duration: Double, isPlaying: Bool, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastClockPublish) >= 0.5 || self.isPlaying != isPlaying else { return }
        lastClockPublish = now
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.isPlaying = isPlaying
    }

    func end(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        self.sessionID = nil
        engine = .unknown
        elapsed = 0
        duration = 0
        isPlaying = false
        hasReusableRenderSurface = false
        avPlayer = nil
    }

    func send(_ command: Command) {
        NotificationCenter.default.post(name: Self.commandNotification, object: command.rawValue)
    }

    private static func engine(from name: String) -> Engine {
        let value = name.lowercased()
        if value.contains("aether") { return .aether }
        if value.contains("ksplayer") { return .ksPlayer }
        if value.contains("avplayer") || value.contains("avfoundation") { return .avFoundation }
        return .unknown
    }
}

/// Hosts the exact PlaybackKit persistent surface in the RealityView attachment.
/// No URL, player, decoder or audio session is created here.
@MainActor
struct SignalVisionReusablePlaybackSurface: UIViewRepresentable {
    let sessionID: UUID

    final class Container: UIView {
        override class var layerClass: AnyClass { CALayer.self }
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isOpaque = true
            clipsToBounds = true
            isUserInteractionEnabled = false
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    }

    func makeUIView(context: Context) -> Container {
        let view = Container(frame: .zero)
        PlaybackController.shared.mountRenderHost(in: view, sessionID: sessionID)
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        PlaybackController.shared.mountRenderHost(in: view, sessionID: sessionID)
    }

    static func dismantleUIView(_ view: Container, coordinator: ()) {
        PlaybackController.shared.restoreRenderHostToOriginalAnchor(sessionID: nil)
    }
}

/// AVFoundation fallback uses the same AVPlayer object that Signal already owns.
/// This is a second presentation target, not a second playback/decoder/audio owner.
@MainActor
struct SignalVisionSharedAVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        // Never pause/replace the shared player here. The normal Signal VOD session owns it.
        controller.player = nil
    }
}
