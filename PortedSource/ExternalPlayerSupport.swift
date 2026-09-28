import Foundation
import UIKit

enum ExternalPlaybackTarget: String, CaseIterable, Identifiable {
    case infuse = "Infuse"
    case vlc = "VLC"
    case senPlayer = "SenPlayer"

    var id: String { rawValue }

    var schemeCandidates: [String] {
        switch self {
        case .infuse:
            return ["infuse"]
        case .vlc:
            return ["vlc", "vlc-x-callback"]
        case .senPlayer:
            return ["senplayer", "sen"]
        }
    }

    func launchURLs(for streamURL: URL, title: String, subtitles: [String]) -> [URL] {
        let encodedURL = streamURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? streamURL.absoluteString
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let firstSub = subtitles.first?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        switch self {
        case .infuse:
            var values = ["url=\(encodedURL)", "filename=\(encodedTitle)"]
            if let firstSub { values.append("sub=\(firstSub)") }
            return [URL(string: "infuse://x-callback-url/play?" + values.joined(separator: "&"))].compactMap { $0 }
        case .vlc:
            return [
                URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encodedURL)"),
                URL(string: "vlc://\(streamURL.absoluteString)")
            ].compactMap { $0 }
        case .senPlayer:
            return [
                URL(string: "senplayer://x-callback-url/play?url=\(encodedURL)&title=\(encodedTitle)"),
                URL(string: "senplayer://play?url=\(encodedURL)"),
                URL(string: "sen://play?url=\(encodedURL)")
            ].compactMap { $0 }
        }
    }
}

@MainActor
enum ExternalPlayerLauncher {
    static func open(_ target: ExternalPlaybackTarget, streamURL: URL, title: String, subtitles: [String], status: @escaping (String) -> Void) {
        let urls = target.launchURLs(for: streamURL, title: title, subtitles: subtitles)
        guard !urls.isEmpty else {
            status("No launch URL could be generated for \(target.rawValue).")
            return
        }

        func attempt(_ index: Int) {
            guard index < urls.count else {
                status("Could not open \(target.rawValue). Make sure it is installed on this Apple TV and supports URL handoff for direct streams.")
                return
            }
            let candidate = urls[index]
            UIApplication.shared.open(candidate, options: [:]) { success in
                if success {
                    status("Opened stream in \(target.rawValue).")
                } else {
                    attempt(index + 1)
                }
            }
        }

        attempt(0)
    }
}
