import SwiftUI
import ARKit
import RoomPlan
import RealityKit
import AppIntents

enum AppRoute: Hashable { case depth, room, item, quickItem, photoItem, history, scan(UUID) }
@MainActor final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var path: [AppRoute] = []
    func home() { path.removeAll() }
    func result(_ record: ScanRecord) { path = [.history, .scan(record.id)] }
}

@main struct TruDepthApp: App {
    @StateObject private var router = AppRouter.shared
    @StateObject private var store = ScanStore.shared
    var body: some SwiftUI.Scene {
        WindowGroup {
            NavigationStack(path: $router.path) {
                HomeView().navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .depth:
                        if ScanCapability.liveDepth.isSupported { LiveMeshView() }
                        else { UnsupportedCaptureView(feature: "Live depth") }
                    case .room:
                        if ScanCapability.roomScan.isSupported { RoomScanView() }
                        else { UnsupportedCaptureView(feature: "Room scanning") }
                    case .item: ItemModeView()
                    case .quickItem:
                        if ScanCapability.objectScan.isSupported { ObjectScanView() }
                        else { UnsupportedCaptureView(feature: "LiDAR item scanning") }
                    case .photoItem:
                        if ScanCapability.photoScan.isSupported { PhotoScanView() }
                        else { UnsupportedCaptureView(feature: "Photo capture and reconstruction") }
                    case .history: ScanHistoryView()
                    case .scan(let id): ScanDetailView(id: id)
                    }
                }
            }
            .environmentObject(router).environmentObject(store)
            .preferredColorScheme(.dark).tint(.accent)
            .task { await store.load() }
            .alert("Scan library", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }
}

@MainActor enum ScanCapability {
    case liveDepth, roomScan, objectScan, photoScan
    var isSupported: Bool {
        switch self {
        case .liveDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        case .roomScan: RoomCaptureSession.isSupported
        case .objectScan: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        case .photoScan: ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported
        }
    }
}

@MainActor enum CapturePreviewRendering {
    static func configure(_ view: ARView) {
        // Avoid RealityKit's HDR/LUT preview path implicated by device validation logs.
        // This affects display only, not captured geometry, photographs, or exports.
        view.renderOptions.formUnion([.disableHDR, .disableMotionBlur, .disableDepthOfField,
                                      .disableCameraGrain, .disableGroundingShadows, .disableAREnvironmentLighting])
        view.environment.sceneUnderstanding.options = []
    }

    static func cropOutline(extent: SIMD3<Float>) -> Entity {
        let outline = Entity()
        let thickness = max(0.001, min(extent.x, extent.y, extent.z) * 0.008)
        let material = UnlitMaterial(color: .systemTeal)
        for axis in 0..<3 {
            let other = (axis + 1) % 3, remaining = (axis + 2) % 3
            var size = SIMD3<Float>(repeating: thickness)
            size[axis] = extent[axis]
            let mesh = MeshResource.generateBox(size: size)
            for a: Float in [-1, 1] { for b: Float in [-1, 1] {
                let edge = ModelEntity(mesh: mesh, materials: [material])
                edge.position[other] = a * extent[other] * 0.5
                edge.position[remaining] = b * extent[remaining] * 0.5
                outline.addChild(edge)
            } }
        }
        return outline
    }
}

struct HomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text("trudepth").font(.system(size: 42, weight: .regular)).padding(.bottom, 36)
            NavigationLink("live depth", value: AppRoute.depth)
            NavigationLink("scan room", value: AppRoute.room)
            NavigationLink("scan item", value: AppRoute.item)
            NavigationLink("history", value: AppRoute.history)
            Spacer()
            Text("Captured and processed on your iPhone.").font(.footnote).foregroundStyle(.secondary)
        }.font(.system(size: 26, weight: .regular)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(32).background(.black)
    }
}

struct UnsupportedCaptureView: View {
    let feature: String
    var body: some View {
        ContentUnavailableView("Capture unavailable", systemImage: "camera.metering.unknown",
            description: Text("\(feature) requires compatible camera and LiDAR hardware. Your saved scans and exports remain available in history."))
            .scanNavigation("capture")
    }
}

struct ItemModeView: View {
    var body: some View {
        List {
            NavigationLink(value: AppRoute.quickItem) {
                Label { VStack(alignment: .leading, spacing: 6) {
                    Text("Quick LiDAR scan")
                    Text("Measure an object and capture its shape. Keep it stationary and walk around it.").font(.subheadline).foregroundStyle(.secondary)
                } } icon: { Image(systemName: "cube.transparent") }
            }
            NavigationLink(value: AppRoute.photoItem) {
                Label { VStack(alignment: .leading, spacing: 6) {
                    Text("Detailed photo scan")
                    Text("Guided photography creates a textured model. Processing takes longer; photos stay on this iPhone.").font(.subheadline).foregroundStyle(.secondary)
                } } icon: { Image(systemName: "camera.aperture") }
            }
        }.scanNavigation("scan item")
    }
}

struct ScanNavigation: ViewModifier {
    @EnvironmentObject var router: AppRouter
    let title: String
    var hasUnsavedChanges = false
    @State private var confirmExit = false
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Main Menu") {
                        if hasUnsavedChanges { confirmExit = true } else { router.home() }
                    }
                }
            }
            .confirmationDialog("Leave with an unsaved room?", isPresented: $confirmExit, titleVisibility: .visible) {
                Button("Leave Scan", role: .destructive) { router.home() }
                Button("Keep Scanning", role: .cancel) {}
            } message: {
                Text("Room data that has not been written to disk will be lost. Previously saved rooms remain in history.")
            }
    }
}
extension View {
    func scanNavigation(_ title: String, hasUnsavedChanges: Bool = false) -> some View {
        modifier(ScanNavigation(title: title, hasUnsavedChanges: hasUnsavedChanges))
    }
}

@MainActor private enum CaptureAwakeOwners {
    static var owners: Set<UUID> = []
    static func set(_ id: UUID, active: Bool) {
        if active { owners.insert(id) } else { owners.remove(id) }
        UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
    }
}
private struct CaptureAwake: ViewModifier {
    let active: Bool
    @State private var id = UUID()
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.onAppear { update() }.onChange(of: active) { update() }.onChange(of: phase) { update() }
            .onDisappear { CaptureAwakeOwners.set(id, active: false) }
    }
    private func update() { CaptureAwakeOwners.set(id, active: active && phase == .active) }
}
extension View { func awakeDuringScan(_ active: Bool) -> some View { modifier(CaptureAwake(active: active)) } }
extension Color { static let accent = Color(red: 0, green: 0.831, blue: 1) }

struct StartScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Scan"
    static let description = IntentDescription("Open TruDepth's item capture options.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.path = [.item]
        return .result()
    }
}
struct TruDepthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartScanIntent(), phrases: ["Start a scan in \(.applicationName)"], shortTitle: "Start Scan", systemImageName: "viewfinder")
    }
}
