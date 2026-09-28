import SwiftUI

// RESET1C: keep the navigation notification contract in this guaranteed-compiled
// compatibility unit. Do not depend on project/source discovery for these symbols.
enum SignalVisionRemoteEvent {
    static let direction = Notification.Name("SignalVision.Remote.Direction")
    static let back = Notification.Name("SignalVision.Remote.Back")
    static let home = Notification.Name("SignalVision.Remote.Home")
    static let catalogDirection = Notification.Name("SignalVision.Catalog.Direction")
}

// visionOS does not expose tvOS MoveCommandDirection/onMoveCommand.
// Preserve the original Unity directional routing for hardware keyboard arrows
// without modifying the unported Apple TV source. Native gaze/pinch selection
// continues through SwiftUI's existing focus and button interaction system.
enum SignalMoveDirection: Equatable {
    case up, down, left, right
}

extension View {
    func signalMoveCommand(perform action: @escaping (SignalMoveDirection) -> Void) -> some View {
        self
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                switch press.key {
                case .upArrow: action(.up)
                case .downArrow: action(.down)
                case .leftArrow: action(.left)
                case .rightArrow: action(.right)
                default: return .ignored
                }
                return .handled
            }
            .onReceive(NotificationCenter.default.publisher(for: SignalVisionRemoteEvent.direction)) { note in
                guard let direction = note.object as? SignalMoveDirection else { return }
                action(direction)
            }
    }
}


// v16: tvOS-only modifiers are not available on visionOS. Keep the same
// original Unity callbacks wired to keyboard equivalents; primary gaze/pinch
// operation still goes through the unchanged onTapGesture/Button actions.
extension View {
    @ViewBuilder
    func signalVisionFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func signalVisionExitCommand(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.onExitCommand(perform: action)
        #else
        self
            .onKeyPress(keys: [.escape]) { _ in action(); return .handled }
            .onReceive(NotificationCenter.default.publisher(for: SignalVisionRemoteEvent.back)) { _ in action() }
        #endif
    }

    @ViewBuilder
    func signalVisionPlayPauseCommand(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.onPlayPauseCommand(perform: action)
        #else
        self.onKeyPress(keys: [.space]) { _ in action(); return .handled }
        #endif
    }
    @ViewBuilder
    func signalVisionFocusEffectPolicy() -> some View {
        #if os(tvOS)
        self.focusEffectDisabled()
        #else
        // visionOS: retain the native gaze/hand focus highlight. The tvOS build
        // intentionally suppresses Apple's default focus ring because Signal draws
        // its own Unity chrome, but suppressing it on Vision Pro makes targets appear
        // non-interactive to eye targeting.
        self.hoverEffect(.highlight)
        #endif
    }

}

// RESET1C: app-wide Vision Pro catalog navigation palette. This is navigation
// infrastructure, not theater/environment code. Keep it in this guaranteed-compiled
// compatibility unit so XcodeGen source discovery cannot drop it independently.
struct SignalVisionCatalogArrows: View {
    let availableSize: CGSize
    @AppStorage("signalVisionCatalogPalettePositionV26") private var locationIndex = 0
    @AppStorage("signalVisionCatalogPaletteOffsetX") private var savedX: Double = 0
    @AppStorage("signalVisionCatalogPaletteOffsetY") private var savedY: Double = 0
    @GestureState private var gestureOffset: CGSize = .zero

    private func arrow(_ symbol: String, _ label: String, _ direction: SignalMoveDirection) -> some View {
        Button {
            NotificationCenter.default.post(name: SignalVisionRemoteEvent.catalogDirection, object: direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.bordered)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }

    private func cyclePosition() {
        locationIndex = (locationIndex + 1) % 4
        let horizontal = max(0, availableSize.width - 230)
        let vertical = max(0, availableSize.height * 0.27)
        switch locationIndex {
        case 1: savedX = Double(horizontal); savedY = 0
        case 2: savedX = Double(horizontal); savedY = Double(-vertical)
        case 3: savedX = 0; savedY = Double(-vertical)
        default: savedX = 0; savedY = 0
        }
    }

    private var repositionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                let x = CGFloat(savedX) + value.translation.width
                let y = CGFloat(savedY) + value.translation.height
                savedX = Double(min(max(-4, x), max(0, availableSize.width - 175)))
                savedY = Double(min(max(-availableSize.height * 0.55, y), availableSize.height * 0.38))
            }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.draw.fill")
                Button("Move") { cyclePosition() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Move catalog controls to another screen corner")
            }
            .font(.system(size: 16, weight: .medium))
            .frame(width: 146, height: 56)
            .contentShape(Rectangle())
            .simultaneousGesture(repositionGesture)
            .accessibilityLabel("Drag or choose Move to reposition catalog controls")
            arrow("chevron.up", "Previous catalog row", .up)
            HStack(spacing: 6) {
                arrow("chevron.left", "Previous poster", .left)
                arrow("chevron.right", "Next poster", .right)
            }
            arrow("chevron.down", "Next catalog row", .down)
        }
        .padding(8)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        .offset(CGSize(width: CGFloat(savedX) + gestureOffset.width,
                       height: CGFloat(savedY) + gestureOffset.height))
        .accessibilityLabel("Movable catalog navigation")
    }
}
