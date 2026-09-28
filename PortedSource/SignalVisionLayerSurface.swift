import SwiftUI

/// Build 25: independently managed, fixed-position Signal visual/focus surfaces.
/// These are composited inside ONE window, not movable visionOS system windows;
/// using separate system windows would not guarantee exact pixel registration.
enum SignalVisionLayer: String {
    case base = "Live TV / Signal"
    case catalog = "Home / Movies / Shows"
    case detail = "Media Information"

    var fixedDepth: CGFloat {
        switch self {
        case .base: return 0
        case .catalog: return 18
        case .detail: return 36
        }
    }
}

struct SignalVisionLayerSurface: ViewModifier {
    let level: SignalVisionLayer
    let active: Bool
    let visible: Bool

    func body(content: Content) -> some View {
        content
            // Build 34: Media Information remains a real floating/glass layer, while
            // catalogs stay flat. Its compositor foundation is independent of the
            // connector line so retracting/disabling that line cannot erase the panel.
            .background {
                if level == .detail && visible {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.2)
                        }
                        .shadow(color: .black.opacity(0.70), radius: 34, x: 0, y: 18)
                        .allowsHitTesting(false)
                }
            }
            .compositingGroup()
            .offset(z: visible ? (level == .detail ? 24 : level.fixedDepth) : 0)
            .allowsHitTesting(active && visible)
            .accessibilityHidden(!active || !visible)
            .onAppear { print("[SignalVisionLayers] mounted \(level.rawValue)") }
    }
}


/// An optical floating shell for catalogs without recreating Signal's layouts.
/// The narrow inset exposes the persistent Live TV window behind the catalog.
struct SignalVisionCatalogShell: ViewModifier {
    let presented: Bool

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color.black.opacity(presented ? 0.55 : 0))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.48), Color.cyan.opacity(0.15),
                                     Color.white.opacity(0.06), Color.orange.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 1.6
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(presented ? 0.75 : 0), radius: 34, x: 0, y: 19)
        #else
        content
        #endif
    }
}
