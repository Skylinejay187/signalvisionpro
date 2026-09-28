#if os(visionOS)
import Foundation
import SwiftUI
import RealityKit
import ARKit
import QuartzCore
import simd

@MainActor
enum SignalCinemaEnvironment: String, CaseIterable, Identifiable {
    case paidFab = "Paid FAB Theater"
    case cleanRoom = "Clean Room"
    var id: String { rawValue }
}

@MainActor
final class SignalImmersiveFoundationState: ObservableObject {
    static let shared = SignalImmersiveFoundationState()
    @Published var tabletX: Float = 0.30
    @Published var tabletY: Float = -0.18
    @Published var tabletZ: Float = -0.75
    @Published var recenterRevision = 0
    @Published var foundationReady = false
    @Published var environment: SignalCinemaEnvironment = .paidFab
    @Published var environmentScale: Float = 1.0
    @Published var environmentDepth: Float = 0.0
    @Published var environmentHeight: Float = 0.0
    @Published var environmentStatus: String = "Fallback ready — loading paid theater…"

    func resetTablet() {
        tabletX = 0.30
        tabletY = -0.18
        tabletZ = -0.75
    }
    func requestRecenter() { recenterRevision &+= 1 }
}

@MainActor
private final class SignalDevicePoseTracker {
    static let shared = SignalDevicePoseTracker()
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var started = false

    func startIfNeeded() async {
        guard !started, WorldTrackingProvider.isSupported else { return }
        started = true
        do { try await session.run([worldTracking]) }
        catch {
            started = false
            print("[SignalCinema] world tracking start failed: \(error)")
        }
    }

    func pose() -> simd_float4x4? {
        guard worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }
}

struct SignalImmersiveBootstrap: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var requested = false

    var body: some View {
        Color.clear.frame(width: 1, height: 1).task {
            guard !requested else { return }
            requested = true
            if case .opened = await openImmersiveSpace(id: "signal-cinema") {
                dismissWindow(id: "signal-main")
            }
        }
    }
}

private enum SignalCinemaLoadError: LocalizedError {
    case sceneAttachmentFailed(String)
    case paidTheaterNotRenderable(String)
    var errorDescription: String? {
        switch self {
        case .sceneAttachmentFailed(let detail): return detail
        case .paidTheaterNotRenderable(let detail): return detail
        }
    }
}

struct SignalImmersiveFoundationSpace: View {
    @StateObject private var state = SignalImmersiveFoundationState.shared
    @State private var lastAppliedRecenter = -1
    @State private var tabletDragOffset: SIMD3<Float>?

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = "SignalCinemaRoot"
            content.add(root)

            // Tablet lives in its own world-space root after one-shot head placement.
            let tabletWorld = Entity()
            tabletWorld.name = "SignalTabletWorldRoot"
            content.add(tabletWorld)

            let environments = Entity()
            environments.name = "SignalEnvironmentContainer"
            root.addChild(environments)

            // Never synchronously load USDZ content while visionOS is establishing
            // the immersive scene. Apple explicitly warns that Entity.load(named:) blocks the
            // main actor and can trigger the scene-update watchdog. Start with a lightweight
            // scene, then asynchronously stream the paid environments after entry.
            let clean = Self.makeCleanCinema()
            clean.name = "SignalCleanRoomEnvironment"
            environments.addChild(clean)

            Task { @MainActor in
                // Give the immersive scene a chance to commit before starting asset I/O.
                try? await Task.sleep(nanoseconds: 650_000_000)
                state.environmentStatus = "Loading paid FAB theater…"
                do {
                    let fab = try await Self.loadCinemaAsset(named: "SignalPaidFabMovieTheater")
                    fab.name = "SignalPaidFabEnvironment"
                    await Task.yield()
                    fab.components.set(Self.runtimeCalibration(for: fab, preferredRoomDepth: 18.0))
                    Self.applyCalibratedEnvironmentTransform(fab, scaleFactor: 1.0, height: 0, depth: 0)
                    // RESET9: attach deterministically to the CURRENT live container. Do not
                    // infer attachment success from decode success. Explicitly enable the paid
                    // entity and disable the fallback only after parentage is established.
                    environments.addChild(fab)
                    fab.isEnabled = true
                    await Task.yield()
                    guard fab.parent === environments else {
                        throw SignalCinemaLoadError.sceneAttachmentFailed("FAB entity has no live environment parent")
                    }
                    let audit = Self.renderabilityAudit(for: fab)
                    guard audit.isPaidTheaterRenderable else {
                        fab.isEnabled = false
                        clean.isEnabled = true
                        throw SignalCinemaLoadError.paidTheaterNotRenderable("FAB renderability gate failed: \(audit.summary)")
                    }
                    let attachedBounds = fab.visualBounds(relativeTo: environments)
                    guard attachedBounds.extents.x > 0.1,
                          attachedBounds.extents.y > 0.1,
                          attachedBounds.extents.z > 0.1 else {
                        fab.isEnabled = false
                        clean.isEnabled = true
                        throw SignalCinemaLoadError.paidTheaterNotRenderable("paid theater has empty post-attachment bounds")
                    }

                    // RESET10C: a successful decode/audit is not enough. The previous code
                    // immediately called the generic visibility helper while the ready marker
                    // was nested under the imported USD hierarchy. On-device testing proved
                    // that could leave the clean fallback enabled over a valid FAB theater.
                    // Commit the transition explicitly at the live environment-container level.
                    let readyMarker = Entity()
                    readyMarker.name = "SignalPaidFabRenderableMarker"
                    fab.addChild(readyMarker)
                    fab.isEnabled = true
                    clean.isEnabled = false
                    state.environmentStatus = String(
                        format: "FAB ACTIVE • seats+walls+screen • %d models • %.1f×%.1f×%.1fm",
                        audit.modelCount, attachedBounds.extents.x, attachedBounds.extents.y, attachedBounds.extents.z
                    )
                } catch {
                    state.environmentStatus = "FAB failed: \(error.localizedDescription)"
                    print("[SignalCinema] async FAB load failed: \(error)")
                }

            }

            if let tablet = attachments.entity(for: "signal-control-tablet") {
                let rig = Entity()
                rig.name = "SignalTabletRig"
                rig.isEnabled = false

                tablet.name = "SignalControlTablet"
                rig.addChild(tablet)

                // Dedicated RealityKit drag handle. The SwiftUI controls no longer have to
                // compete with a drag gesture for pinch input.
                let handleMaterial = UnlitMaterial(color: .init(white: 0.62, alpha: 0.92))
                let handle = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(0.32, 0.026, 0.026), cornerRadius: 0.013),
                    materials: [handleMaterial]
                )
                handle.name = "SignalTabletDragHandle"
                handle.position = [0, 0.245, 0.015]
                handle.components.set(InputTargetComponent())
                handle.components.set(CollisionComponent(shapes: [
                    ShapeResource.generateBox(size: SIMD3<Float>(0.38, 0.075, 0.08))
                ]))
                handle.components.set(HoverEffectComponent())
                rig.addChild(handle)

                // RESET7: Apple-recommended one-shot head anchoring. The tablet is placed
                // relative to the center of the wearer's head exactly once, then remains
                // stationary in the immersive world until the user drags or recenters it.
                let headAnchor = AnchorEntity(.head, trackingMode: .once)
                headAnchor.name = "SignalTabletHeadAnchor"
                headAnchor.addChild(rig)
                content.add(headAnchor)
                rig.position = [state.tabletX, state.tabletY, state.tabletZ]
                rig.isEnabled = true

                // RESET9: .once is the important part. RealityKit resolves the head-relative
                // spawn once and then leaves this anchor fixed in world space. No timed detach,
                // no race with attachment transforms, and no face-locked controller.
            }

            Self.updateEnvironmentVisibility(in: root, selected: state.environment)
        } update: { content, attachments in
            guard let root = content.entities.first(where: { $0.name == "SignalCinemaRoot" }) else { return }

            if state.recenterRevision != lastAppliedRecenter {
                // Keep the cinema world placement independent from the personal controller.
                if let pose = SignalDevicePoseTracker.shared.pose() {
                    root.transform = Self.horizontalSpawnTransform(from: pose)
                    state.foundationReady = true
                }
                if let headAnchor = content.entities.first(where: { $0.name == "SignalTabletHeadAnchor" }) as? AnchorEntity,
                   let rig = headAnchor.findEntity(named: "SignalTabletRig") {
                    headAnchor.anchoring.trackingMode = .once
                    headAnchor.reanchor(.head, preservingWorldTransform: false)
                    rig.position = [state.tabletX, state.tabletY, state.tabletZ]
                    rig.orientation = simd_quatf()
                    rig.isEnabled = true
                }
                lastAppliedRecenter = state.recenterRevision
            }

            Self.updateEnvironmentVisibility(in: root, selected: state.environment)
            Self.applyEnvironmentAdjustment(in: root, state: state)

            // Do not rewrite the detached tablet transform every SwiftUI update. Its world-space
            // transform is authoritative after the initial head-relative placement.
            if let headAnchor = content.entities.first(where: { $0.name == "SignalTabletHeadAnchor" }),
               let rig = headAnchor.findEntity(named: "SignalTabletRig") {
                rig.isEnabled = true
            }
        } attachments: {
            Attachment(id: "signal-control-tablet") {
                SignalCinemaControlTablet(state: state)
                    .frame(width: 620, height: 440)
                    .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 34))
            }
        }
        // True spatial entity drag. This no longer interprets a 2D SwiftUI pixel delta as
        // world X/Y; the pinch location is converted into the tablet parent's 3D coordinates.
        .gesture(
            DragGesture(minimumDistance: 0)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard value.entity.name == "SignalTabletDragHandle",
                          let rig = value.entity.parent,
                          rig.name == "SignalTabletRig",
                          let tabletAnchor = rig.parent else { return }
                    let pointer = value.convert(value.location3D, from: .local, to: tabletAnchor)
                    if tabletDragOffset == nil {
                        tabletDragOffset = rig.position - pointer
                    }
                    let target = pointer + (tabletDragOffset ?? .zero)
                    rig.position = target
                    state.tabletX = target.x
                    state.tabletY = target.y
                    state.tabletZ = target.z
                }
                .onEnded { _ in tabletDragOffset = nil }
        )
        .task {
            await SignalDevicePoseTracker.shared.startIfNeeded()
            // Wait for a valid tracked headset pose before exposing either environment or HUD.
            for _ in 0..<150 {
                if SignalDevicePoseTracker.shared.pose() != nil {
                    state.resetTablet()
                    state.requestRecenter()
                    return
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private static func loadCinemaAsset(named name: String) async throws -> Entity {
        // Resolve the exact packaged USDZ URL first. This avoids depending on whether Xcode
        // preserves the Cinema resource directory or flattens it during Copy Bundle Resources.
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "Cinema"),
            Bundle.main.url(forResource: name, withExtension: "usdz")
        ]
        if let url = candidates.compactMap({ $0 }).first {
            print("[SignalCinema] loading asset URL: \(url.path)")
            return try await Entity(contentsOf: url)
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).usdz"])
    }

    private static func loadBundledEntity(_ resource: String) -> Entity? {
        let candidates = [resource, "\(resource).usdz", "Cinema/\(resource)", "Cinema/\(resource).usdz"]
        for candidate in candidates {
            if let entity = try? Entity.load(named: candidate, in: .main) { return entity }
        }
        print("[SignalCinema] missing bundled environment: \(resource)")
        return nil
    }

    private static func horizontalSpawnTransform(from pose: simd_float4x4) -> Transform {
        let p = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var f = SIMD3<Float>(-pose.columns.2.x, 0, -pose.columns.2.z)
        f = simd_length_squared(f) < 0.0001 ? SIMD3<Float>(0, 0, -1) : simd_normalize(f)
        let yaw = atan2(f.x, -f.z)
        return Transform(scale: .one, rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: p)
    }

    private static func updateEnvironmentVisibility(in root: Entity, selected: SignalCinemaEnvironment) {
        let fab = root.findEntity(named: "SignalPaidFabEnvironment")
        fab?.isEnabled = selected == .paidFab
        // RESET10: do not hide the fallback merely because an entity exists or reports bounds.
        // The FAB marker is created only after seats, walls and the architectural screen all
        // resolve to real ModelComponents after live-scene attachment.
        // findEntity(named:) is not relied on for readiness because the marker lives
        // below a hierarchy imported from USDZ. A paid FAB entity is enabled only after all
        // renderability gates pass; until then the clean room remains the fallback.
        let fabReady = fab?.isEnabled == true && fab?.children.isEmpty == false
        let selectedAssetReady = selected == .paidFab && fabReady
        if selected == .cleanRoom {
            fab?.isEnabled = false
        } else if fabReady {
            fab?.isEnabled = true
        }
        root.findEntity(named: "SignalCleanRoomEnvironment")?.isEnabled = selected == .cleanRoom || !selectedAssetReady
    }

    private struct RenderabilityAudit {
        var modelCount = 0
        var hasSeats = false
        var hasWalls = false
        var hasScreen = false
        var isPaidTheaterRenderable: Bool { modelCount >= 3 && hasSeats && hasWalls && hasScreen }
        var summary: String { "models=\(modelCount) seats=\(hasSeats) walls=\(hasWalls) screen=\(hasScreen)" }
    }

    private static func renderabilityAudit(for entity: Entity) -> RenderabilityAudit {
        var audit = RenderabilityAudit()
        func containsModel(_ node: Entity) -> Bool {
            if node.components[ModelComponent.self] != nil { return true }
            return node.children.contains(where: containsModel)
        }
        func countModels(_ node: Entity) -> Int {
            (node.components[ModelComponent.self] == nil ? 0 : 1)
                + node.children.reduce(0) { $0 + countModels($1) }
        }
        audit.modelCount = countModels(entity)
        if let seats = findDescendant(in: entity, where: { $0.name.localizedCaseInsensitiveContains("seat") }) {
            audit.hasSeats = containsModel(seats)
        }
        if let walls = findDescendant(in: entity, where: { $0.name.localizedCaseInsensitiveContains("wall") }) {
            audit.hasWalls = containsModel(walls)
        }
        if let screen = findDescendant(in: entity, where: { $0.name.localizedCaseInsensitiveContains("screen") }) {
            audit.hasScreen = containsModel(screen)
        }
        print("[SignalCinema] renderability audit: \(audit.summary)")
        return audit
    }

    private static func applyEnvironmentAdjustment(in root: Entity, state: SignalImmersiveFoundationState) {
        let factor = max(0.80, min(1.25, state.environmentScale))
        if let fab = root.findEntity(named: "SignalPaidFabEnvironment") {
            applyCalibratedEnvironmentTransform(
                fab, scaleFactor: factor, height: state.environmentHeight, depth: state.environmentDepth
            )
        }
    }

    private static func runtimeCalibration(for entity: Entity, preferredRoomDepth: Float) -> SignalEnvironmentCalibrationComponent {
        let bounds = entity.visualBounds(relativeTo: entity)
        let center = bounds.center
        let extents = bounds.extents

        // RESET10: derive the cinema coordinate system from the purchased asset itself.
        // The screen defines the front, the seats define the viewing region, and the imported
        // minimum Y defines the floor. This avoids arbitrary offsets and old below-seat flips.
        let screen = findDescendant(in: entity) { $0.name.localizedCaseInsensitiveContains("screen") }
        let seats = findDescendant(in: entity) { $0.name.localizedCaseInsensitiveContains("seat") }
        let screenBounds = screen?.visualBounds(relativeTo: entity)
        let seatBounds = seats?.visualBounds(relativeTo: entity)
        let screenCenter = screenBounds?.center ?? SIMD3<Float>(center.x, center.y, bounds.max.z)
        let seatingCenter = seatBounds?.center ?? center

        var toScreen = SIMD2<Float>(screenCenter.x - seatingCenter.x, screenCenter.z - seatingCenter.z)
        if simd_length_squared(toScreen) < 0.0001 { toScreen = SIMD2<Float>(0, 1) }
        toScreen = simd_normalize(toScreen)

        // Normalize the imported room to a sane Vision Pro scale from its own RealityKit bounds.
        let horizontalDepth = max(abs(extents.x), abs(extents.z))
        let baseScale = horizontalDepth > 0.001 ? min(1.0, preferredRoomDepth / horizontalDepth) : 1.0

        // Bias the eye point toward the rear of the authored seating region while keeping a
        // real seated eye height above the imported floor.
        let seatingDepth = max(seatBounds?.extents.x ?? 0, seatBounds?.extents.z ?? 0)
        let rearBias = max(0.0, seatingDepth * 0.18)
        let eyeHeightSource = 1.25 / max(baseScale, 0.0001)
        let viewer = SIMD3<Float>(
            seatingCenter.x - toScreen.x * rearBias,
            bounds.min.y + eyeHeightSource,
            seatingCenter.z - toScreen.y * rearBias
        )

        // Rotate the source viewer->screen direction onto RealityKit forward (-Z).
        let yaw = atan2(-toScreen.x, -toScreen.y)
        return SignalEnvironmentCalibrationComponent(sourceViewerPoint: viewer, baseScale: baseScale, yaw: yaw)
    }

    private static func findDescendant(in entity: Entity, where predicate: (Entity) -> Bool) -> Entity? {
        if predicate(entity) { return entity }
        for child in entity.children {
            if let match = findDescendant(in: child, where: predicate) { return match }
        }
        return nil
    }

    private static func applyCalibratedEnvironmentTransform(
        _ entity: Entity,
        scaleFactor: Float,
        height: Float,
        depth: Float
    ) {
        guard let calibration = entity.components[SignalEnvironmentCalibrationComponent.self] else { return }
        let scale = calibration.baseScale * scaleFactor
        let rotation = simd_quatf(angle: calibration.yaw, axis: SIMD3<Float>(0, 1, 0))
        let scaledViewerPoint = calibration.sourceViewerPoint * scale
        // RealityKit transform order is scale -> rotation -> translation. This translation
        // makes the authored source-space viewer point land exactly on local (0,0,0).
        var translation = -rotation.act(scaledViewerPoint)
        translation.y += height
        translation.z += depth
        entity.transform = Transform(
            scale: SIMD3<Float>(repeating: scale),
            rotation: rotation,
            translation: translation
        )
    }

    private static func applyBlackSeatMaterialIfPresent(in entity: Entity) {
        if entity.name.localizedCaseInsensitiveContains("seat"),
           let model = entity as? ModelEntity,
           var component = model.model {
            let charcoal = SimpleMaterial(
                color: .init(red: 0.025, green: 0.027, blue: 0.030, alpha: 1),
                roughness: 0.72,
                isMetallic: false
            )
            component.materials = Array(repeating: charcoal, count: max(1, component.materials.count))
            model.model = component
        }
        for child in entity.children { applyBlackSeatMaterialIfPresent(in: child) }
    }

    private static func makeCleanCinema() -> Entity {
        let room = Entity()
        func box(_ name: String, _ size: SIMD3<Float>, _ pos: SIMD3<Float>, _ material: SimpleMaterial) {
            let e = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            e.name = name
            e.position = pos
            room.addChild(e)
        }
        let dark = SimpleMaterial(color: .init(white: 0.035, alpha: 1), roughness: 0.82, isMetallic: false)
        let wall = SimpleMaterial(color: .init(red: 0.07, green: 0.055, blue: 0.06, alpha: 1), roughness: 0.9, isMetallic: false)
        let screen = SimpleMaterial(color: .init(white: 0.72, alpha: 1), roughness: 0.96, isMetallic: false)
        box("Floor", [12, 0.12, 15], [0, -1.30, -1], dark)
        box("Ceiling", [12, 0.12, 15], [0, 3.4, -1], dark)
        box("LeftWall", [0.15, 4.8, 15], [-6, 1.05, -1], wall)
        box("RightWall", [0.15, 4.8, 15], [6, 1.05, -1], wall)
        box("FrontWall", [12, 4.8, 0.15], [0, 1.05, -8.25], wall)
        box("BackWall", [12, 4.8, 0.15], [0, 1.05, 6.25], wall)
        box("MainScreen", [7.8, 3.45, 0.08], [0, 0.65, -8.10], screen)
        return room
    }
}

private struct SignalEnvironmentCalibrationComponent: Component {
    var sourceViewerPoint: SIMD3<Float>
    var baseScale: Float
    var yaw: Float
}

private struct SignalCinemaControlTablet: View {
    @ObservedObject var state: SignalImmersiveFoundationState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SIGNAL").font(.system(size: 19, weight: .black))
                    Text("VISION CINEMA / RESET10").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "move.3d")
                Text("Pinch + drag the bar above tablet").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state.environmentStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Environment").font(.headline)
            Picker("Environment", selection: $state.environment) {
                ForEach(SignalCinemaEnvironment.allCases) { environment in
                    Text(environment.rawValue).tag(environment)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button("Recenter") {
                    state.resetTablet()
                    state.requestRecenter()
                }.buttonStyle(.borderedProminent)
                Button("Reset Tablet") { state.resetTablet() }
                Spacer()
                Text(String(format: "x %.2f  y %.2f  z %.2f", state.tabletX, state.tabletY, state.tabletZ))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack {
                Text("Room size")
                Slider(value: $state.environmentScale, in: 0.80...1.25)
                Text("Depth")
                Slider(value: $state.environmentDepth, in: -2.0...2.0)
                Text("Height")
                Slider(value: $state.environmentHeight, in: -1.0...1.0)
            }
            .font(.caption)
        }
        .padding(24)
        .background(.black.opacity(0.20))
    }
}
#endif
