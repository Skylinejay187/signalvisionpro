import SwiftUI

// vBRDC068: presentation-only visual system for catalog/search/media-info surfaces.
// It deliberately does not own navigation, focus, playback, catalog geometry, or metadata.
// The goal is to make the existing UI feel like one coherent "Unity" surface without
// moving rows, replacing the Live TV root, or adding heavyweight image-processing work.
enum UnityMediaVisualAccent {
    private static let palette: [Color] = [
        Color(red: 0.22, green: 0.76, blue: 1.00),
        Color(red: 0.98, green: 0.50, blue: 0.20),
        Color(red: 0.60, green: 0.42, blue: 1.00),
        Color(red: 0.20, green: 0.88, blue: 0.72),
        Color(red: 1.00, green: 0.32, blue: 0.48),
        Color(red: 0.96, green: 0.76, blue: 0.22)
    ]

    static func accent(for item: MediaItem) -> Color {
        // Never use Swift's randomized Hashable seed for appearance. This stable scalar
        // signature keeps a title's subtle accent consistent between launches/devices.
        var signature: UInt64 = 1469598103934665603
        for scalar in "\(item.title)|\(item.year)|\(item.type)".unicodeScalars {
            signature ^= UInt64(scalar.value)
            signature &*= 1099511628211
        }
        return palette[Int(signature % UInt64(palette.count))]
    }
}

struct UnityCatalogCardChrome: View {
    let item: MediaItem
    let focused: Bool
    var cornerRadius: CGFloat = 24
    var compact: Bool = false

    private var accent: Color { UnityMediaVisualAccent.accent(for: item) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(focused ? 0.075 : 0.025),
                            accent.opacity(focused ? 0.045 : 0.012),
                            Color.clear,
                            Color.black.opacity(focused ? 0.05 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(focused ? 0.90 : 0.18),
                            accent.opacity(focused ? 0.78 : 0.18),
                            Color.white.opacity(focused ? 0.20 : 0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? (compact ? 1.8 : 2.2) : 0.8
                )

            // One restrained specular sweep makes the cards feel like a physical glass
            // object. Static gradients are intentionally used instead of perpetual shaders.
            LinearGradient(
                colors: [Color.white.opacity(focused ? 0.13 : 0.035), Color.clear, Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // vBRDC067: the vBRDC066 top dash / status-dot / lower accent rail looked
            // like unexplained playback or cache indicators on physical Apple TV. They were
            // decorative only, so remove them and let the glass edge/specular treatment carry
            // the card identity without implying nonexistent state.
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct UnityCatalogHeroAura: View {
    let item: MediaItem
    var intensity: Double = 1.0

    private var accent: Color { UnityMediaVisualAccent.accent(for: item) }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [accent.opacity(0.14 * intensity), accent.opacity(0.035 * intensity), Color.clear],
                center: .leading,
                startRadius: 10,
                endRadius: 720
            )
            RadialGradient(
                colors: [Color.white.opacity(0.035 * intensity), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct UnityCompactFranchiseRibbon: View {
    let item: MediaItem
    let visibleItems: [MediaItem]
    let totalCount: Int
    let baseIndex: Int
    let focusedIndex: Int?

    private var accent: Color { UnityMediaVisualAccent.accent(for: item) }
    private var expanded: Bool { focusedIndex != nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            collapsedRibbon

            if expanded {
                expandedShelf
                    .offset(y: -100)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(4)
            }
        }
        .frame(width: 808, height: 66, alignment: .bottomLeading)
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: expanded)
        .accessibilityElement(children: .contain)
    }

    private var collapsedRibbon: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(accent.opacity(expanded ? 0.22 : 0.13))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color.white.opacity(0.94))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("EXPLORE THE FRANCHISE")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(1.15)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(totalCount == 1 ? "1 linked title" : "\(totalCount) linked titles")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: -14) {
                ForEach(Array(visibleItems.prefix(4).enumerated()), id: \.element.id) { offset, franchiseItem in
                    ZStack {
                        Color.black.opacity(0.44)
                        if let landscape = franchiseItem.landscapeURL, !landscape.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            RemoteImageFit(url: landscape, mode: .fill, showPlaceholder: false)
                        } else {
                            RemoteImageFit(url: franchiseItem.posterURL, mode: .fit, showPlaceholder: false)
                                .padding(2)
                        }
                    }
                    .frame(width: 48, height: 29)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                    )
                    .rotationEffect(.degrees(Double(offset - 1) * 1.8))
                    .zIndex(Double(10 - offset))
                }
            }
            .frame(width: 124, alignment: .trailing)

            Image(systemName: expanded ? "chevron.up" : "chevron.right")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(accent.opacity(0.92))
                .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .frame(width: 808, height: 62)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(expanded ? 0.085 : 0.052), accent.opacity(expanded ? 0.080 : 0.030), Color.black.opacity(0.20)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(expanded ? 0.44 : 0.16), accent.opacity(expanded ? 0.58 : 0.18), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: expanded ? 1.5 : 0.8
                )
        )
        .shadow(color: accent.opacity(expanded ? 0.18 : 0.04), radius: expanded ? 14 : 6, y: 4)
    }

    private var expandedShelf: some View {
        HStack(spacing: 10) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { offset, franchiseItem in
                let absoluteIndex = baseIndex + offset
                UnityFranchiseMiniCard(
                    item: franchiseItem,
                    selected: focusedIndex == absoluteIndex,
                    accent: accent
                )
            }
        }
        .padding(10)
        .frame(width: 808, height: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.40))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), accent.opacity(0.48), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        )
        .shadow(color: .black.opacity(0.58), radius: 24, y: 12)
        .shadow(color: accent.opacity(0.16), radius: 18, y: 4)
    }
}

private struct UnityFranchiseMiniCard: View {
    let item: MediaItem
    let selected: Bool
    let accent: Color

    private var hasLandscape: Bool {
        guard let landscape = item.landscapeURL else { return false }
        return !landscape.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLogo: Bool {
        guard let logo = item.logoURL else { return false }
        return !logo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.48)

                // vBRDC068: the franchise shelf is intentionally landscape-first. A real
                // landscape/backdrop fills the wide card; portrait art is only a fallback and
                // stays aspect-fit so it is never brutally cropped into landscape geometry.
                if hasLandscape {
                    RemoteImageFit(url: item.landscapeURL, mode: .fill, showPlaceholder: false)
                        .saturation(selected ? 1.06 : 0.94)
                        .contrast(1.03)
                } else {
                    RemoteImageFit(url: item.posterURL, mode: .fit, showPlaceholder: false)
                        .padding(4)
                        .saturation(selected ? 1.06 : 0.94)
                }

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.08), Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Clearlogos are never used as crop-fill artwork. Give every logo a fixed
                // safe box and aspect-fit it so long/wide franchise marks remain complete.
                if hasLogo {
                    RemoteImageFit(url: item.logoURL, mode: .fit, showPlaceholder: false)
                        .frame(width: 96, height: 30, alignment: .leading)
                        .padding(.leading, 8)
                        .padding(.bottom, 7)
                }
            }
            .frame(width: 150, height: 84)
            .clipped()

            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Spacer(minLength: 2)

                if !item.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.year)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 150, height: 36)
            .background(Color.black.opacity(0.78))
        }
        .frame(width: 150, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(selected ? accent.opacity(0.96) : Color.white.opacity(0.10), lineWidth: selected ? 2.4 : 0.8)
        )
        .scaleEffect(selected ? 1.045 : 1.0)
        .shadow(color: selected ? accent.opacity(0.28) : .black.opacity(0.20), radius: selected ? 14 : 5, y: selected ? 6 : 2)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: selected)
    }
}

// MARK: - Catalog row motion presets

struct UnityCatalogPersistentMotionTransform {
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    let angleY: Double
    let angleZ: Double
    let opacity: Double

    init(
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat,
        angleY: Double = 0,
        angleZ: Double = 0,
        opacity: Double
    ) {
        self.x = x
        self.y = y
        self.scale = scale
        self.angleY = angleY
        self.angleZ = angleZ
        self.opacity = opacity
    }

    static let identity = UnityCatalogPersistentMotionTransform(
        x: 0,
        y: 0,
        scale: 1,
        angleY: 0,
        angleZ: 0,
        opacity: 1
    )
}

/// vBRDC103: compositor-only motion for the persistent fixed-slot catalog rail.
/// The rail's layout and image-loader identities never change while this runs.
struct UnityCatalogPersistentRailMotionModifier: ViewModifier {
    let transform: UnityCatalogPersistentMotionTransform
    let phase: CGFloat

    func body(content: Content) -> some View {
        let clampedPhase = min(max(phase, 0), 1)
        let remaining = 1 - clampedPhase
        content
            .scaleEffect(transform.scale + ((1 - transform.scale) * clampedPhase))
            .rotation3DEffect(
                .degrees(transform.angleY * Double(remaining)),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.72
            )
            .rotationEffect(.degrees(transform.angleZ * Double(remaining)))
            .offset(x: transform.x * remaining, y: transform.y * remaining)
            .opacity(transform.opacity + ((1 - transform.opacity) * Double(clampedPhase)))
    }
}


/// vBRDC068: presentation-only horizontal catalog motion. These styles change only the
/// insertion/removal animation used when the selected catalog item changes. They never
/// own focus, mutate selectedIndex, move a row vertically, or change catalog geometry.
enum UnityCatalogRowMotionStyle {
    static let defaultName = "Native Smooth"
    static let names = [
        "Native Smooth",
        "Classic Spring",
        "Smooth Glide",
        "Cinematic Drift",
        "Elastic",
        "Quick Snap",
        "Soft Float",
        "Depth Shift",
        "Carousel Tilt",
        "Parallax Sweep",
        "Arc Rise",
        "Zoom Through",
        "Deck Flip",
        "Momentum Slide",
        "Soft Bounce",
        "Glass Drift",
        "Orbit Tilt",
        "Wave Glide",
        "Perspective Push",
        "Ribbon Sweep",
        "Floating Deck",
        "Rubber Band",
        "Cinema Push",
        "Micro Snap",
        "Focus Rush",
        "Velvet Slide",
        "Horizon Glide",
        "Magnetic Pull",
        "Spring Roll",
        "Feather Sweep",
        "Turbo Flick",
        "Camera Dolly",
        "Lens Pull",
        "Stage Slide",
        "Portal Zoom",
        "Sidewinder",
        "Pendulum",
        "Helix Tilt",
        "Prism Drift",
        "Cascade",
        "Hover Shift",
        "Satellite",
        "Backdrop Push",
        "Recoil",
        "Whisper Snap",
        "Overshoot Glide",
        "Gravity Drop",
        "Lift Off",
        "Instant"
    ]

    static func animation(for name: String) -> Animation? {
        switch normalized(name) {
        case "native smooth":
            // vBRDC297: Nuvio-inspired default motion — short ease-out with no spring
            // settling/overshoot. This keeps the existing Signal rail geometry and style
            // while letting tvOS focus cadence feel native under rapid remote input.
            return .easeOut(duration: 0.22)
        case "smooth glide":
            return .easeInOut(duration: 0.30)
        case "cinematic drift":
            return .spring(response: 0.52, dampingFraction: 0.90)
        case "elastic":
            return .interpolatingSpring(stiffness: 205, damping: 18)
        case "quick snap":
            return .easeOut(duration: 0.17)
        case "soft float":
            return .spring(response: 0.46, dampingFraction: 0.82)
        case "depth shift":
            return .spring(response: 0.40, dampingFraction: 0.87)
        case "carousel tilt":
            return .spring(response: 0.44, dampingFraction: 0.82)
        case "parallax sweep":
            return .spring(response: 0.38, dampingFraction: 0.88)
        case "arc rise":
            return .spring(response: 0.48, dampingFraction: 0.80)
        case "zoom through":
            return .spring(response: 0.34, dampingFraction: 0.86)
        case "deck flip":
            return .spring(response: 0.43, dampingFraction: 0.78)
        case "momentum slide":
            return .interpolatingSpring(stiffness: 240, damping: 25)
        case "soft bounce":
            return .interpolatingSpring(stiffness: 175, damping: 16)
        case "glass drift":
            return .easeInOut(duration: 0.38)
        case "orbit tilt":
            return .spring(response: 0.50, dampingFraction: 0.79)
        case "wave glide":
            return .spring(response: 0.46, dampingFraction: 0.84)
        case "perspective push":
            return .spring(response: 0.36, dampingFraction: 0.90)
        case "ribbon sweep":
            return .easeInOut(duration: 0.34)
        case "floating deck":
            return .spring(response: 0.54, dampingFraction: 0.83)
        case "rubber band":
            return .interpolatingSpring(stiffness: 150, damping: 14)
        case "cinema push":
            return .spring(response: 0.39, dampingFraction: 0.86)
        case "micro snap":
            return .easeOut(duration: 0.12)
        case "focus rush":
            return .spring(response: 0.29, dampingFraction: 0.88)
        case "velvet slide":
            return .easeInOut(duration: 0.44)
        case "horizon glide":
            return .spring(response: 0.47, dampingFraction: 0.91)
        case "magnetic pull":
            return .interpolatingSpring(stiffness: 230, damping: 23)
        case "spring roll":
            return .interpolatingSpring(stiffness: 180, damping: 17)
        case "feather sweep":
            return .easeInOut(duration: 0.36)
        case "turbo flick":
            return .easeOut(duration: 0.135)
        case "camera dolly":
            return .spring(response: 0.41, dampingFraction: 0.90)
        case "lens pull":
            return .spring(response: 0.38, dampingFraction: 0.87)
        case "stage slide":
            return .spring(response: 0.45, dampingFraction: 0.86)
        case "portal zoom":
            return .spring(response: 0.33, dampingFraction: 0.84)
        case "sidewinder":
            return .spring(response: 0.42, dampingFraction: 0.80)
        case "pendulum":
            return .spring(response: 0.50, dampingFraction: 0.79)
        case "helix tilt":
            return .spring(response: 0.46, dampingFraction: 0.78)
        case "prism drift":
            return .easeInOut(duration: 0.40)
        case "cascade":
            return .spring(response: 0.49, dampingFraction: 0.83)
        case "hover shift":
            return .spring(response: 0.43, dampingFraction: 0.89)
        case "satellite":
            return .spring(response: 0.52, dampingFraction: 0.81)
        case "backdrop push":
            return .spring(response: 0.37, dampingFraction: 0.89)
        case "recoil":
            return .interpolatingSpring(stiffness: 245, damping: 20)
        case "whisper snap":
            return .easeOut(duration: 0.10)
        case "overshoot glide":
            return .interpolatingSpring(stiffness: 195, damping: 18)
        case "gravity drop":
            return .spring(response: 0.48, dampingFraction: 0.82)
        case "lift off":
            return .spring(response: 0.45, dampingFraction: 0.81)
        case "instant":
            return nil
        default:
            // Byte-for-behavior equivalent timing to the pre-vBRDC068 catalog rail.
            return .spring(response: 0.42, dampingFraction: 0.84)
        }
    }

    // vBRDC103: The physical catalog renderer now keeps one persistent rail tree alive.
    // These transforms are sourced from the exact insertion side of the existing 48
    // motion presets, so visual theme choices survive without destroying/recreating
    // every card/image loader on each D-pad press.
    static func persistentArrivalTransform(for name: String, direction: Int) -> UnityCatalogPersistentMotionTransform {
        let d = CGFloat(direction == 0 ? 1 : direction)
        switch normalized(name) {
        case "native smooth":
            return UnityCatalogPersistentMotionTransform(x: 52 * d, y: 0, scale: 0.992, opacity: 0.28)
        case "smooth glide":
            return UnityCatalogPersistentMotionTransform(x: 82 * d, y: 0, scale: 0.985, opacity: 0.10)
        case "cinematic drift":
            return UnityCatalogPersistentMotionTransform(x: 108 * d, y: 9, scale: 0.955, angleY: -4.5 * Double(d), opacity: 0.05)
        case "elastic":
            return UnityCatalogPersistentMotionTransform(x: 148 * d, y: 0, scale: 0.91, angleY: -7.0 * Double(d), opacity: 0.02)
        case "quick snap":
            return UnityCatalogPersistentMotionTransform(x: 44 * d, y: 0, scale: 0.995, opacity: 0.38)
        case "soft float":
            return UnityCatalogPersistentMotionTransform(x: 70 * d, y: 18, scale: 0.965, angleZ: 0.55 * Double(d), opacity: 0.08)
        case "depth shift":
            return UnityCatalogPersistentMotionTransform(x: 56 * d, y: 0, scale: 0.875, angleY: -10.0 * Double(d), opacity: 0.06)
        case "carousel tilt":
            return UnityCatalogPersistentMotionTransform(x: 104 * d, y: 0, scale: 0.93, angleY: -14.0 * Double(d), opacity: 0.04)
        case "parallax sweep":
            return UnityCatalogPersistentMotionTransform(x: 128 * d, y: 0, scale: 0.975, angleY: -5.5 * Double(d), opacity: 0.12)
        case "arc rise":
            return UnityCatalogPersistentMotionTransform(x: 92 * d, y: 30, scale: 0.94, angleZ: 1.2 * Double(d), opacity: 0.04)
        case "zoom through":
            return UnityCatalogPersistentMotionTransform(x: 34 * d, y: 0, scale: 0.78, angleY: -3.0 * Double(d), opacity: 0.02)
        case "deck flip":
            return UnityCatalogPersistentMotionTransform(x: 76 * d, y: 0, scale: 0.91, angleY: -23.0 * Double(d), angleZ: 0.8 * Double(d), opacity: 0.03)
        case "momentum slide":
            return UnityCatalogPersistentMotionTransform(x: 166 * d, y: 0, scale: 0.97, angleY: -2.5 * Double(d), opacity: 0.08)
        case "soft bounce":
            return UnityCatalogPersistentMotionTransform(x: 66 * d, y: 14, scale: 0.90, angleZ: 0.35 * Double(d), opacity: 0.06)
        case "glass drift":
            return UnityCatalogPersistentMotionTransform(x: 52 * d, y: 8, scale: 0.975, angleY: -2.0 * Double(d), opacity: 0.00)
        case "orbit tilt":
            return UnityCatalogPersistentMotionTransform(x: 98 * d, y: 22, scale: 0.92, angleY: -11.0 * Double(d), angleZ: 1.8 * Double(d), opacity: 0.03)
        case "wave glide":
            return UnityCatalogPersistentMotionTransform(x: 84 * d, y: 24, scale: 0.955, angleY: -5.0 * Double(d), angleZ: 1.0 * Double(d), opacity: 0.05)
        case "perspective push":
            return UnityCatalogPersistentMotionTransform(x: 62 * d, y: 0, scale: 0.84, angleY: -16.0 * Double(d), opacity: 0.03)
        case "ribbon sweep":
            return UnityCatalogPersistentMotionTransform(x: 136 * d, y: 7, scale: 0.985, angleZ: 0.65 * Double(d), opacity: 0.02)
        case "floating deck":
            return UnityCatalogPersistentMotionTransform(x: 74 * d, y: 34, scale: 0.90, angleY: -8.0 * Double(d), angleZ: 1.1 * Double(d), opacity: 0.04)
        case "rubber band":
            return UnityCatalogPersistentMotionTransform(x: 116 * d, y: 0, scale: 0.88, angleY: -6.0 * Double(d), opacity: 0.04)
        case "cinema push":
            return UnityCatalogPersistentMotionTransform(x: 48 * d, y: 0, scale: 0.82, angleY: -9.0 * Double(d), opacity: 0.01)
        case "micro snap":
            return UnityCatalogPersistentMotionTransform(x: 24 * d, y: 0, scale: 0.998, opacity: 0.55)
        case "focus rush":
            return UnityCatalogPersistentMotionTransform(x: 92 * d, y: 0, scale: 0.94, angleY: -7.0 * Double(d), opacity: 0.08)
        case "velvet slide":
            return UnityCatalogPersistentMotionTransform(x: 74 * d, y: 4, scale: 0.985, angleY: -2.0 * Double(d), opacity: 0.03)
        case "horizon glide":
            return UnityCatalogPersistentMotionTransform(x: 142 * d, y: 0, scale: 0.97, angleY: -3.5 * Double(d), opacity: 0.07)
        case "magnetic pull":
            return UnityCatalogPersistentMotionTransform(x: 118 * d, y: 0, scale: 0.89, angleY: -9.0 * Double(d), opacity: 0.05)
        case "spring roll":
            return UnityCatalogPersistentMotionTransform(x: 104 * d, y: 16, scale: 0.91, angleZ: 2.3 * Double(d), opacity: 0.04)
        case "feather sweep":
            return UnityCatalogPersistentMotionTransform(x: 96 * d, y: 10, scale: 0.99, angleZ: 0.35 * Double(d), opacity: 0.12)
        case "turbo flick":
            return UnityCatalogPersistentMotionTransform(x: 68 * d, y: 0, scale: 0.985, angleY: -3.0 * Double(d), opacity: 0.32)
        case "camera dolly":
            return UnityCatalogPersistentMotionTransform(x: 40 * d, y: 0, scale: 0.83, angleY: -4.0 * Double(d), opacity: 0.02)
        case "lens pull":
            return UnityCatalogPersistentMotionTransform(x: 28 * d, y: 0, scale: 0.74, opacity: 0.01)
        case "stage slide":
            return UnityCatalogPersistentMotionTransform(x: 154 * d, y: 12, scale: 0.965, angleZ: 0.45 * Double(d), opacity: 0.05)
        case "portal zoom":
            return UnityCatalogPersistentMotionTransform(x: 12 * d, y: 0, scale: 0.66, angleY: -8.0 * Double(d), opacity: 0.00)
        case "sidewinder":
            return UnityCatalogPersistentMotionTransform(x: 122 * d, y: 26, scale: 0.94, angleY: -8.5 * Double(d), angleZ: 2.0 * Double(d), opacity: 0.04)
        case "pendulum":
            return UnityCatalogPersistentMotionTransform(x: 86 * d, y: 18, scale: 0.95, angleZ: 3.4 * Double(d), opacity: 0.04)
        case "helix tilt":
            return UnityCatalogPersistentMotionTransform(x: 84 * d, y: 20, scale: 0.90, angleY: -18.0 * Double(d), angleZ: 2.7 * Double(d), opacity: 0.03)
        case "prism drift":
            return UnityCatalogPersistentMotionTransform(x: 62 * d, y: 14, scale: 0.97, angleY: -6.5 * Double(d), angleZ: 0.9 * Double(d), opacity: 0.02)
        case "cascade":
            return UnityCatalogPersistentMotionTransform(x: 102 * d, y: 36, scale: 0.92, angleY: -5.0 * Double(d), opacity: 0.03)
        case "hover shift":
            return UnityCatalogPersistentMotionTransform(x: 72 * d, y: 22, scale: 0.965, angleY: -4.0 * Double(d), opacity: 0.06)
        case "satellite":
            return UnityCatalogPersistentMotionTransform(x: 112 * d, y: 30, scale: 0.89, angleY: -13.0 * Double(d), angleZ: 2.0 * Double(d), opacity: 0.02)
        case "backdrop push":
            return UnityCatalogPersistentMotionTransform(x: 50 * d, y: 0, scale: 0.80, angleY: -11.0 * Double(d), opacity: 0.02)
        case "recoil":
            return UnityCatalogPersistentMotionTransform(x: 134 * d, y: 0, scale: 0.90, angleY: -8.0 * Double(d), opacity: 0.04)
        case "whisper snap":
            return UnityCatalogPersistentMotionTransform(x: 16 * d, y: 0, scale: 0.999, opacity: 0.62)
        case "overshoot glide":
            return UnityCatalogPersistentMotionTransform(x: 152 * d, y: 0, scale: 0.945, angleY: -5.0 * Double(d), opacity: 0.05)
        case "gravity drop":
            return UnityCatalogPersistentMotionTransform(x: 78 * d, y: -30, scale: 0.93, angleZ: -0.7 * Double(d), opacity: 0.04)
        case "lift off":
            return UnityCatalogPersistentMotionTransform(x: 82 * d, y: 34, scale: 0.92, angleZ: 0.8 * Double(d), opacity: 0.03)
        case "instant":
            return .identity
        default:
            // Classic Spring previously used move(edge:) + opacity. A restrained full-rail
            // arrival keeps the same spring timing while avoiding a full SwiftUI remount.
            return UnityCatalogPersistentMotionTransform(x: 96 * d, y: 0, scale: 0.975, opacity: 0.08)
        }
    }

    static func transition(for name: String, direction: Int) -> AnyTransition {
        let d = CGFloat(direction == 0 ? 1 : direction)
        let insertion: AnyTransition
        let removal: AnyTransition

        switch normalized(name) {
        case "native smooth":
            insertion = transform(x: 52 * d, y: 0, scale: 0.992, opacity: 0.28)
            removal = transform(x: -38 * d, y: 0, scale: 0.996, opacity: 0.24)
        case "smooth glide":
            insertion = transform(x: 82 * d, y: 0, scale: 0.985, opacity: 0.10)
            removal = transform(x: -64 * d, y: 0, scale: 0.99, opacity: 0.10)
        case "cinematic drift":
            insertion = transform(x: 108 * d, y: 9, scale: 0.955, angleY: -4.5 * Double(d), opacity: 0.05)
            removal = transform(x: -72 * d, y: -4, scale: 0.975, angleY: 3.0 * Double(d), opacity: 0.05)
        case "elastic":
            insertion = transform(x: 148 * d, y: 0, scale: 0.91, angleY: -7.0 * Double(d), opacity: 0.02)
            removal = transform(x: -94 * d, y: 0, scale: 0.95, angleY: 5.0 * Double(d), opacity: 0.02)
        case "quick snap":
            insertion = transform(x: 44 * d, y: 0, scale: 0.995, opacity: 0.38)
            removal = transform(x: -32 * d, y: 0, scale: 0.995, opacity: 0.28)
        case "soft float":
            insertion = transform(x: 70 * d, y: 18, scale: 0.965, angleZ: 0.55 * Double(d), opacity: 0.08)
            removal = transform(x: -54 * d, y: -12, scale: 0.98, angleZ: -0.35 * Double(d), opacity: 0.08)
        case "depth shift":
            insertion = transform(x: 56 * d, y: 0, scale: 0.875, angleY: -10.0 * Double(d), opacity: 0.06)
            removal = transform(x: -42 * d, y: 0, scale: 1.04, angleY: 7.0 * Double(d), opacity: 0.04)
        case "carousel tilt":
            insertion = transform(x: 104 * d, y: 0, scale: 0.93, angleY: -14.0 * Double(d), opacity: 0.04)
            removal = transform(x: -74 * d, y: 0, scale: 0.96, angleY: 11.0 * Double(d), opacity: 0.04)
        case "parallax sweep":
            insertion = transform(x: 128 * d, y: 0, scale: 0.975, angleY: -5.5 * Double(d), opacity: 0.12)
            removal = transform(x: -38 * d, y: 0, scale: 1.015, angleY: 2.0 * Double(d), opacity: 0.14)
        case "arc rise":
            insertion = transform(x: 92 * d, y: 30, scale: 0.94, angleZ: 1.2 * Double(d), opacity: 0.04)
            removal = transform(x: -62 * d, y: -22, scale: 0.97, angleZ: -0.8 * Double(d), opacity: 0.05)
        case "zoom through":
            insertion = transform(x: 34 * d, y: 0, scale: 0.78, angleY: -3.0 * Double(d), opacity: 0.02)
            removal = transform(x: -24 * d, y: 0, scale: 1.13, angleY: 2.0 * Double(d), opacity: 0.02)
        case "deck flip":
            insertion = transform(x: 76 * d, y: 0, scale: 0.91, angleY: -23.0 * Double(d), angleZ: 0.8 * Double(d), opacity: 0.03)
            removal = transform(x: -58 * d, y: 0, scale: 0.94, angleY: 18.0 * Double(d), angleZ: -0.5 * Double(d), opacity: 0.03)
        case "momentum slide":
            insertion = transform(x: 166 * d, y: 0, scale: 0.97, angleY: -2.5 * Double(d), opacity: 0.08)
            removal = transform(x: -106 * d, y: 0, scale: 0.985, angleY: 1.5 * Double(d), opacity: 0.08)
        case "soft bounce":
            insertion = transform(x: 66 * d, y: 14, scale: 0.90, angleZ: 0.35 * Double(d), opacity: 0.06)
            removal = transform(x: -48 * d, y: -8, scale: 1.025, angleZ: -0.25 * Double(d), opacity: 0.06)
        case "glass drift":
            insertion = transform(x: 52 * d, y: 8, scale: 0.975, angleY: -2.0 * Double(d), opacity: 0.00)
            removal = transform(x: -44 * d, y: -6, scale: 0.985, angleY: 1.5 * Double(d), opacity: 0.00)
        case "orbit tilt":
            insertion = transform(x: 98 * d, y: 22, scale: 0.92, angleY: -11.0 * Double(d), angleZ: 1.8 * Double(d), opacity: 0.03)
            removal = transform(x: -72 * d, y: -18, scale: 0.95, angleY: 9.0 * Double(d), angleZ: -1.4 * Double(d), opacity: 0.03)
        case "wave glide":
            insertion = transform(x: 84 * d, y: 24, scale: 0.955, angleY: -5.0 * Double(d), angleZ: 1.0 * Double(d), opacity: 0.05)
            removal = transform(x: -64 * d, y: -18, scale: 0.975, angleY: 4.0 * Double(d), angleZ: -0.7 * Double(d), opacity: 0.05)
        case "perspective push":
            insertion = transform(x: 62 * d, y: 0, scale: 0.84, angleY: -16.0 * Double(d), opacity: 0.03)
            removal = transform(x: -38 * d, y: 0, scale: 1.09, angleY: 11.0 * Double(d), opacity: 0.03)
        case "ribbon sweep":
            insertion = transform(x: 136 * d, y: 7, scale: 0.985, angleZ: 0.65 * Double(d), opacity: 0.02)
            removal = transform(x: -118 * d, y: -5, scale: 0.985, angleZ: -0.45 * Double(d), opacity: 0.02)
        case "floating deck":
            insertion = transform(x: 74 * d, y: 34, scale: 0.90, angleY: -8.0 * Double(d), angleZ: 1.1 * Double(d), opacity: 0.04)
            removal = transform(x: -50 * d, y: -26, scale: 0.96, angleY: 6.0 * Double(d), angleZ: -0.8 * Double(d), opacity: 0.04)
        case "rubber band":
            insertion = transform(x: 116 * d, y: 0, scale: 0.88, angleY: -6.0 * Double(d), opacity: 0.04)
            removal = transform(x: -82 * d, y: 0, scale: 1.04, angleY: 4.0 * Double(d), opacity: 0.04)
        case "cinema push":
            insertion = transform(x: 48 * d, y: 0, scale: 0.82, angleY: -9.0 * Double(d), opacity: 0.01)
            removal = transform(x: -32 * d, y: 0, scale: 1.10, angleY: 6.0 * Double(d), opacity: 0.01)
        case "micro snap":
            insertion = transform(x: 24 * d, y: 0, scale: 0.998, opacity: 0.55)
            removal = transform(x: -18 * d, y: 0, scale: 0.998, opacity: 0.50)
        case "focus rush":
            insertion = transform(x: 92 * d, y: 0, scale: 0.94, angleY: -7.0 * Double(d), opacity: 0.08)
            removal = transform(x: -56 * d, y: 0, scale: 1.025, angleY: 3.5 * Double(d), opacity: 0.10)
        case "velvet slide":
            insertion = transform(x: 74 * d, y: 4, scale: 0.985, angleY: -2.0 * Double(d), opacity: 0.03)
            removal = transform(x: -62 * d, y: -3, scale: 0.99, angleY: 1.4 * Double(d), opacity: 0.03)
        case "horizon glide":
            insertion = transform(x: 142 * d, y: 0, scale: 0.97, angleY: -3.5 * Double(d), opacity: 0.07)
            removal = transform(x: -88 * d, y: 0, scale: 0.985, angleY: 2.2 * Double(d), opacity: 0.08)
        case "magnetic pull":
            insertion = transform(x: 118 * d, y: 0, scale: 0.89, angleY: -9.0 * Double(d), opacity: 0.05)
            removal = transform(x: -44 * d, y: 0, scale: 1.055, angleY: 4.0 * Double(d), opacity: 0.06)
        case "spring roll":
            insertion = transform(x: 104 * d, y: 16, scale: 0.91, angleZ: 2.3 * Double(d), opacity: 0.04)
            removal = transform(x: -72 * d, y: -10, scale: 1.02, angleZ: -1.5 * Double(d), opacity: 0.05)
        case "feather sweep":
            insertion = transform(x: 96 * d, y: 10, scale: 0.99, angleZ: 0.35 * Double(d), opacity: 0.12)
            removal = transform(x: -74 * d, y: -6, scale: 0.995, angleZ: -0.2 * Double(d), opacity: 0.12)
        case "turbo flick":
            insertion = transform(x: 68 * d, y: 0, scale: 0.985, angleY: -3.0 * Double(d), opacity: 0.32)
            removal = transform(x: -44 * d, y: 0, scale: 0.99, angleY: 2.0 * Double(d), opacity: 0.26)
        case "camera dolly":
            insertion = transform(x: 40 * d, y: 0, scale: 0.83, angleY: -4.0 * Double(d), opacity: 0.02)
            removal = transform(x: -28 * d, y: 0, scale: 1.075, angleY: 2.6 * Double(d), opacity: 0.03)
        case "lens pull":
            insertion = transform(x: 28 * d, y: 0, scale: 0.74, opacity: 0.01)
            removal = transform(x: -20 * d, y: 0, scale: 1.16, opacity: 0.01)
        case "stage slide":
            insertion = transform(x: 154 * d, y: 12, scale: 0.965, angleZ: 0.45 * Double(d), opacity: 0.05)
            removal = transform(x: -112 * d, y: -8, scale: 0.985, angleZ: -0.3 * Double(d), opacity: 0.05)
        case "portal zoom":
            insertion = transform(x: 12 * d, y: 0, scale: 0.66, angleY: -8.0 * Double(d), opacity: 0.00)
            removal = transform(x: -12 * d, y: 0, scale: 1.20, angleY: 5.0 * Double(d), opacity: 0.00)
        case "sidewinder":
            insertion = transform(x: 122 * d, y: 26, scale: 0.94, angleY: -8.5 * Double(d), angleZ: 2.0 * Double(d), opacity: 0.04)
            removal = transform(x: -86 * d, y: 18, scale: 0.975, angleY: 6.0 * Double(d), angleZ: -1.2 * Double(d), opacity: 0.05)
        case "pendulum":
            insertion = transform(x: 86 * d, y: 18, scale: 0.95, angleZ: 3.4 * Double(d), opacity: 0.04)
            removal = transform(x: -58 * d, y: -14, scale: 0.98, angleZ: -2.5 * Double(d), opacity: 0.05)
        case "helix tilt":
            insertion = transform(x: 84 * d, y: 20, scale: 0.90, angleY: -18.0 * Double(d), angleZ: 2.7 * Double(d), opacity: 0.03)
            removal = transform(x: -60 * d, y: -14, scale: 0.96, angleY: 13.0 * Double(d), angleZ: -1.8 * Double(d), opacity: 0.03)
        case "prism drift":
            insertion = transform(x: 62 * d, y: 14, scale: 0.97, angleY: -6.5 * Double(d), angleZ: 0.9 * Double(d), opacity: 0.02)
            removal = transform(x: -46 * d, y: -10, scale: 0.985, angleY: 4.5 * Double(d), angleZ: -0.6 * Double(d), opacity: 0.02)
        case "cascade":
            insertion = transform(x: 102 * d, y: 36, scale: 0.92, angleY: -5.0 * Double(d), opacity: 0.03)
            removal = transform(x: -68 * d, y: -28, scale: 0.97, angleY: 3.0 * Double(d), opacity: 0.04)
        case "hover shift":
            insertion = transform(x: 72 * d, y: 22, scale: 0.965, angleY: -4.0 * Double(d), opacity: 0.06)
            removal = transform(x: -54 * d, y: -16, scale: 0.985, angleY: 2.8 * Double(d), opacity: 0.07)
        case "satellite":
            insertion = transform(x: 112 * d, y: 30, scale: 0.89, angleY: -13.0 * Double(d), angleZ: 2.0 * Double(d), opacity: 0.02)
            removal = transform(x: -76 * d, y: -24, scale: 0.95, angleY: 9.0 * Double(d), angleZ: -1.4 * Double(d), opacity: 0.03)
        case "backdrop push":
            insertion = transform(x: 50 * d, y: 0, scale: 0.80, angleY: -11.0 * Double(d), opacity: 0.02)
            removal = transform(x: -34 * d, y: 0, scale: 1.12, angleY: 7.0 * Double(d), opacity: 0.02)
        case "recoil":
            insertion = transform(x: 134 * d, y: 0, scale: 0.90, angleY: -8.0 * Double(d), opacity: 0.04)
            removal = transform(x: -64 * d, y: 0, scale: 1.065, angleY: 5.0 * Double(d), opacity: 0.04)
        case "whisper snap":
            insertion = transform(x: 16 * d, y: 0, scale: 0.999, opacity: 0.62)
            removal = transform(x: -12 * d, y: 0, scale: 0.999, opacity: 0.58)
        case "overshoot glide":
            insertion = transform(x: 152 * d, y: 0, scale: 0.945, angleY: -5.0 * Double(d), opacity: 0.05)
            removal = transform(x: -92 * d, y: 0, scale: 1.035, angleY: 3.0 * Double(d), opacity: 0.05)
        case "gravity drop":
            insertion = transform(x: 78 * d, y: -30, scale: 0.93, angleZ: -0.7 * Double(d), opacity: 0.04)
            removal = transform(x: -52 * d, y: 24, scale: 0.98, angleZ: 0.5 * Double(d), opacity: 0.05)
        case "lift off":
            insertion = transform(x: 82 * d, y: 34, scale: 0.92, angleZ: 0.8 * Double(d), opacity: 0.03)
            removal = transform(x: -56 * d, y: -26, scale: 0.975, angleZ: -0.55 * Double(d), opacity: 0.04)
        case "instant":
            return .identity
        default:
            // Classic Spring preserves the familiar pre-setting move/opacity behavior,
            // while respecting the direction the user actually moved.
            insertion = .move(edge: direction < 0 ? .leading : .trailing).combined(with: .opacity)
            removal = .move(edge: direction < 0 ? .trailing : .leading).combined(with: .opacity)
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }

    /// vBRDC092: compositor ownership lasts through the selected row style's visible
    /// arrival, not a fixed 180 ms. The old fixed deadline woke wallpaper/pulse/image
    /// publications while slower 0.4-0.55 s transitions were still landing.
    static func frameBudgetSettleDuration(for name: String) -> TimeInterval {
        // The frame-budget window is deliberately a little longer than the visible curve,
        // especially for under-damped/interpolating springs. It does not slow the row
        // transition itself; it only delays ambient wallpaper/glow/preview/ticker/image
        // publications until the focused card has genuinely reached its resting transform.
        switch normalized(name) {
        case "native smooth": return 0.30
        case "instant": return 0.12
        case "whisper snap": return 0.16
        case "micro snap": return 0.18
        case "turbo flick": return 0.20
        case "quick snap": return 0.24
        case "focus rush": return 0.38
        case "zoom through", "portal zoom": return 0.43
        case "smooth glide": return 0.40
        case "ribbon sweep", "feather sweep": return 0.44
        case "perspective push", "backdrop push": return 0.46
        case "glass drift", "prism drift": return 0.49
        case "velvet slide": return 0.53
        case "cinematic drift": return 0.60
        case "orbit tilt": return 0.61
        case "floating deck": return 0.64
        case "satellite": return 0.62
        case "arc rise", "gravity drop": return 0.59
        case "pendulum", "cascade": return 0.62
        case "soft float", "wave glide", "helix tilt", "lift off": return 0.57
        case "horizon glide", "stage slide", "hover shift": return 0.56
        case "depth shift", "parallax sweep": return 0.50
        case "carousel tilt", "deck flip", "sidewinder": return 0.58
        case "camera dolly", "lens pull": return 0.52
        case "cinema push": return 0.50
        case "elastic": return 0.60
        case "momentum slide": return 0.54
        case "soft bounce": return 0.61
        case "rubber band": return 0.70
        case "magnetic pull": return 0.54
        case "spring roll": return 0.60
        case "recoil": return 0.57
        case "overshoot glide": return 0.62
        case "classic spring": return 0.54
        default: return 0.54
        }
    }

    static func subtitle(for name: String) -> String {
        switch normalized(name) {
        case "smooth glide": return "clean, even side-to-side glide"
        case "cinematic drift": return "slower premium drift with light depth"
        case "elastic": return "springier travel with a stronger arrival"
        case "quick snap": return "fast, crisp catalog movement"
        case "soft float": return "gentle lift while cards move"
        case "depth shift": return "cards move through foreground depth"
        case "carousel tilt": return "angled carousel-style travel"
        case "parallax sweep": return "layered sweep with a subtle depth lead"
        case "arc rise": return "cards travel in a light upward arc"
        case "zoom through": return "quick foreground zoom into the next card"
        case "deck flip": return "deeper card-deck flip with perspective"
        case "momentum slide": return "longer kinetic slide with a firm stop"
        case "soft bounce": return "compact bounce and gentle lift on arrival"
        case "glass drift": return "clean transparent-feeling fade and glide"
        case "orbit tilt": return "curved tilt with stronger cinematic depth"
        case "wave glide": return "flowing rise-and-fall motion across the rail"
        case "perspective push": return "strong depth push into the next selection"
        case "ribbon sweep": return "wide silky sweep with a light angled finish"
        case "floating deck": return "stacked-card float with a softer landing"
        case "rubber band": return "stretchier spring with a lively rebound"
        case "cinema push": return "foreground push inspired by film UI transitions"
        case "micro snap": return "ultra-short response for very fast browsing"
        case "focus rush": return "fast focus pull with a compact depth kick"
        case "velvet slide": return "slow silky glide with almost no bounce"
        case "horizon glide": return "wide premium travel across the catalog rail"
        case "magnetic pull": return "next card feels pulled firmly into focus"
        case "spring roll": return "rolling spring arrival with light rotation"
        case "feather sweep": return "soft airy sweep for relaxed browsing"
        case "turbo flick": return "very fast flick for rapid remote navigation"
        case "camera dolly": return "film-camera dolly move through foreground depth"
        case "lens pull": return "strong focus-style zoom between cards"
        case "stage slide": return "wide theatrical slide with a soft finish"
        case "portal zoom": return "dramatic deep zoom into the next selection"
        case "sidewinder": return "diagonal winding travel with perspective"
        case "pendulum": return "swinging card movement with controlled rotation"
        case "helix tilt": return "spiraling perspective tilt without moving focus"
        case "prism drift": return "layered angled drift with a polished finish"
        case "cascade": return "falling-and-rising deck motion across the row"
        case "hover shift": return "floating horizontal move with a gentle lift"
        case "satellite": return "wide orbital arc around the focused card"
        case "backdrop push": return "strong background-to-foreground depth move"
        case "recoil": return "fast impact motion with a spring recoil"
        case "whisper snap": return "minimal almost-instant motion with soft fade"
        case "overshoot glide": return "long glide that lightly overshoots the target"
        case "gravity drop": return "drops into focus with a controlled landing"
        case "lift off": return "rises into focus with a light cinematic float"
        case "native smooth": return "Apple TV-style ease-out motion with no spring overshoot"
        case "instant": return "no horizontal transition animation"
        default: return "original Debrid Channels spring motion"
        }
    }

    private static func normalized(_ name: String) -> String {
        names.contains(name) ? name.lowercased() : defaultName.lowercased()
    }

    private static func transform(
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat,
        angleY: Double = 0,
        angleZ: Double = 0,
        opacity: Double
    ) -> AnyTransition {
        .modifier(
            active: UnityCatalogRowMotionTransitionModifier(
                x: x,
                y: y,
                scale: scale,
                angleY: angleY,
                angleZ: angleZ,
                opacity: opacity
            ),
            identity: UnityCatalogRowMotionTransitionModifier(
                x: 0,
                y: 0,
                scale: 1,
                angleY: 0,
                angleZ: 0,
                opacity: 1
            )
        )
    }
}

private struct UnityCatalogRowMotionTransitionModifier: ViewModifier {
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    let angleY: Double
    let angleZ: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(angleY), axis: (x: 0, y: 1, z: 0), perspective: 0.58)
            .rotationEffect(.degrees(angleZ))
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

struct CatalogRowMotionPicker: View {
    @Binding var selectedStyle: String
    @FocusState private var focusedStyle: String?
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(UnityCatalogRowMotionStyle.names, id: \.self) { style in
                let isFocused = focusedStyle == style
                Button {
                    selectedStyle = style
                    UserDefaults.standard.set(style, forKey: "catalogRowScrollingAnimationPreset")
                    // vBRDC203: asynchronous UserDefaults persistence avoids a settings focus hitch.
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedStyle == style ? "checkmark.circle.fill" : "rectangle.3.group.fill")
                            .font(.system(size: 15, weight: .black))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style)
                                .font(.system(size: 14.5, weight: .black, design: .rounded))
                                .lineLimit(1)
                            Text(UnityCatalogRowMotionStyle.subtitle(for: style))
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(selectedStyle == style ? Color.black.opacity(0.62) : Color.white.opacity(0.52))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle((selectedStyle == style || isFocused) ? Color.black : Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(selectedStyle == style ? Color.cyan.opacity(0.92) : (isFocused ? Color.orange.opacity(0.82) : Color.white.opacity(0.085)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke((selectedStyle == style || isFocused) ? Color.white.opacity(0.90) : Color.white.opacity(0.10), lineWidth: (selectedStyle == style || isFocused) ? 2 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .focused($focusedStyle, equals: style)
                .modifier(SettingsRoundedFocusVisual(cornerRadius: 15))
            }
        }
        .padding(.top, 4)
    }
}
