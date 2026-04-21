import SwiftUI
import ARKit
import RealityKit
import Combine

// MARK: - Live Mesh Screen

struct LiveMeshView: View {
    @StateObject private var viewModel = LiveMeshViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if viewModel.isSupported {
                ARMeshContainer(viewModel: viewModel)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            overlayUI
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var overlayUI: some View {
        VStack {
            topBar
            Spacer()
            if !viewModel.isSupported { unsupportedBadge }
            bottomControls
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            Spacer()
            if viewModel.isSupported { distanceBadge }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var distanceBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.distanceIsNear ? Color(hex: "30D158") : Color(hex: "FF453A"))
                .frame(width: 8, height: 8)
            Text(viewModel.centerDistance)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private var unsupportedBadge: some View {
        Label("LiDAR not available on this device", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(16)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 16)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            Picker("Visualization", selection: $viewModel.visualization) {
                ForEach(MeshVisualization.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            if viewModel.visualization == .depth {
                depthLegend
            }
        }
        .padding(.bottom, 36)
    }

    private var depthLegend: some View {
        HStack(spacing: 8) {
            Text("0 m")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            LinearGradient(
                colors: [.red, .yellow, .green, .cyan, .blue],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 6)
            .clipShape(Capsule())
            Text("5 m")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Visualization Mode

enum MeshVisualization: CaseIterable {
    case classification, wireframe, depth

    var label: String {
        switch self {
        case .classification: "Classify"
        case .wireframe:      "Wireframe"
        case .depth:          "Depth"
        }
    }
}

// MARK: - ARView Container

struct ARMeshContainer: UIViewRepresentable {
    @ObservedObject var viewModel: LiveMeshViewModel

    func makeUIView(context: Context) -> ARView {
        viewModel.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - View Model

@MainActor
final class LiveMeshViewModel: ObservableObject {

    let arView: ARView = {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        return v
    }()

    @Published var visualization: MeshVisualization = .classification {
        didSet { applyVisualization(visualization) }
    }
    @Published var centerDistance: String = "-- m"
    @Published var distanceIsNear: Bool = true

    let isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)

    private var distanceTimer: AnyCancellable?

    func start() {
        guard isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.frameSemantics = [.sceneDepth]
        config.environmentTexturing = .automatic
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        applyVisualization(.classification)
        startDistancePolling()
    }

    func stop() {
        arView.session.pause()
        distanceTimer?.cancel()
    }

    func applyVisualization(_ mode: MeshVisualization) {
        switch mode {
        case .classification:
            arView.debugOptions = [.showSceneUnderstanding]
            arView.environment.sceneUnderstanding.options = [.occlusion]
        case .wireframe:
            arView.debugOptions = [.showSceneUnderstanding, .showWireframe]
            arView.environment.sceneUnderstanding.options = [.occlusion]
        case .depth:
            arView.debugOptions = []
            arView.environment.sceneUnderstanding.options = []
            colorMeshByDepth()
        }
    }

    // Color each mesh anchor face by its distance from the camera.
    private func colorMeshByDepth() {
        guard let frame = arView.session.currentFrame else { return }
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            guard let entity = arView.scene.findEntity(named: anchor.identifier.uuidString) as? ModelEntity
            else { continue }
            let pos = anchor.transform.columns.3
            let dist = simd_length(simd_float3(pos.x, pos.y, pos.z))
            var mat = UnlitMaterial()
            mat.color = .init(tint: jetColor(for: dist))
            entity.model?.materials = [mat]
        }
    }

    private func jetColor(for distance: Float) -> UIColor {
        let t = Double(max(0, min(1, distance / 5.0)))
        let hue = 0.67 * (1.0 - t) // blue (far) → red (near)
        return UIColor(hue: hue, saturation: 0.9, brightness: 1.0, alpha: 0.85)
    }

    private func startDistancePolling() {
        distanceTimer = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sampleCenterDepth() }
    }

    private func sampleCenterDepth() {
        guard let depthMap = arView.session.currentFrame?.sceneDepth?.depthMap else { return }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let value = base.assumingMemoryBound(to: Float32.self)[(h / 2) * w + (w / 2)]
        guard value > 0 else { return }
        centerDistance = String(format: "%.2f m", value)
        distanceIsNear = value <= 5.0
    }
}
