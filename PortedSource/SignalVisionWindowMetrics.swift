import SwiftUI
import UIKit

/// Window-local replacement for tvOS UIScreen measurements. The default is the initial Unity
/// canvas; a root GeometryReader updates the window bounds during resize on visionOS.
@MainActor
enum SignalVisionWindowMetrics {
    static var currentWindowBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let estimatedMaximumFramesPerSecond = 60
    static let contentScale: CGFloat = 1

    static func update(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        currentWindowBounds = CGRect(origin: .zero, size: size)
    }
}
