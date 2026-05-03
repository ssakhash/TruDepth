import SwiftUI
import ARKit
import RealityKit
import Combine
import MetalKit

// MARK: - Live Mesh Screen

struct LiveMeshView: View {
    @StateObject private var viewModel = LiveMeshViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if viewModel.isSupported {
                ARMeshContainer(viewModel: viewModel)
                    .ignoresSafeArea()
                // Black backdrop so jet-color heatmap pops against dark background in depth mode.
                if viewModel.visualization == .depth {
                    Color.black.ignoresSafeArea()
                }
                // Metal heatmap overlay — always in hierarchy; renderer controls visibility.
                MTKHeatmapView(renderer: viewModel.heatmapRenderer)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .rotationEffect(.degrees(viewModel.visualization == .depth ? 180 : 0))
            } else {
                Color.black.ignoresSafeArea()
            }
            overlayUI
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: true)
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
        HStack(alignment: .center) {
            Button(action: { dismiss() }) {
                Text("main menu")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }

            Spacer()

            Text("live depth")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(DS.textTertiary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer()

            if viewModel.isSupported { distanceBadge }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var distanceBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.distanceIsNear ? Color.accent : .white.opacity(DS.textSecondary))
                .frame(width: 7, height: 7)
                .animation(.easeInOut(duration: 0.3), value: viewModel.distanceIsNear)
            Text(viewModel.centerDistance)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(viewModel.distanceIsNear ? Color.accent : .white.opacity(DS.textSecondary))
                .animation(.easeInOut(duration: 0.3), value: viewModel.distanceIsNear)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.6), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: viewModel.distanceIsNear)
    }

    private var unsupportedBadge: some View {
        Label("LiDAR not available on this device", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(16)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 16)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            CustomSegmentedControl(
                options: MeshVisualization.allCases.map(\.label),
                selectedIndex: Binding(
                    get: { MeshVisualization.allCases.firstIndex(of: viewModel.visualization) ?? 0 },
                    set: { idx in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            viewModel.visualization = MeshVisualization.allCases[idx]
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                )
            )
            .padding(.horizontal, 20)

            if viewModel.visualization == .depth {
                depthLegend
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button(action: { dismiss() }) {
                Text("main menu")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(DS.textSecondary))
            }
        }
        .animation(.spring(response: 0.4), value: viewModel.visualization == .depth)
        .padding(.bottom, 100)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - Custom Segmented Control

private struct CustomSegmentedControl: View {
    let options: [String]
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { idx in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        selectedIndex = idx
                    }
                }) {
                    Text(options[idx])
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selectedIndex == idx ? .white : .white.opacity(DS.textSecondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.white.opacity(selectedIndex == idx ? 0.15 : 0))
                                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selectedIndex)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(white: 0.1), in: Capsule())
    }
}

// MARK: - Visualization Mode

enum MeshVisualization: CaseIterable {
    case classification, depth

    var label: String {
        switch self {
        case .classification: "classify"
        case .depth:          "depth"
        }
    }
}

// MARK: - ARView Container

struct ARMeshContainer: UIViewRepresentable {
    let viewModel: LiveMeshViewModel

    func makeUIView(context: Context) -> ARView { viewModel.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Metal Heatmap Container

struct MTKHeatmapView: UIViewRepresentable {
    let renderer: DepthHeatmapRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.attach(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - Live Mesh View Model

@MainActor
final class LiveMeshViewModel: ObservableObject {

    let arView: ARView = {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        return v
    }()

    let heatmapRenderer: DepthHeatmapRenderer = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = DepthHeatmapRenderer(device: device) else {
            fatalError("Metal is not available on this device")
        }
        return renderer
    }()

    @Published var visualization: MeshVisualization = .classification {
        didSet { applyVisualization(visualization) }
    }
    @Published var centerDistance: String = "-- m"
    @Published var distanceIsNear: Bool = true

    let isSupported = ScanCapability.liveDepth.isSupported

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
            heatmapRenderer.mtkView?.isHidden = true
        case .depth:
            arView.debugOptions = []
            arView.environment.sceneUnderstanding.options = []
            heatmapRenderer.mtkView?.isHidden = false
        }
    }

    // MARK: - Center distance polling (off main thread)

    private func startDistancePolling() {
        distanceTimer = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sampleCenterDepth() }
    }

    private func sampleCenterDepth() {
        guard let depthMap = arView.session.currentFrame?.sceneDepth?.depthMap else { return }
        let isDepthMode = visualization == .depth
        // Capture main-actor properties before crossing into Sendable closure.
        let renderer = heatmapRenderer
        // CVPixelBuffer is not Sendable; wrap so the compiler accepts cross-thread transfer.
        // Safety: we own the lock/unlock on the background thread and don't alias it elsewhere.
        let box = UncheckedSendable(depthMap)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let depthMap = box.value

            // Feed Metal renderer while in depth mode (zero-copy texture path).
            if isDepthMode {
                renderer.update(depthMap: depthMap)
            }

            // Sample center pixel with correct stride.
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            guard w > 0, h > 0,
                  let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

            let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
            let value = base.assumingMemoryBound(to: Float32.self)[(h / 2) * stride + (w / 2)]
            guard value > 0 else { return }

            let text = String(format: "%.2f m", value)
            let near = value <= 5.0

            DispatchQueue.main.async {
                self?.centerDistance = text
                self?.distanceIsNear = near
            }
        }
    }
}

// MARK: - Sendable Helpers

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Metal Depth Heatmap Renderer

final class DepthHeatmapRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    private(set) var device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // Thread-safe depth texture access.
    private let textureLock = NSLock()
    private var currentCVTexture: CVMetalTexture?
    private var pendingDepthTexture: MTLTexture?

    var maxDepth: Float = 5.0
    @MainActor weak var mtkView: MTKView?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // Called once by MTKHeatmapView after the MTKView is created.
    @MainActor
    func attach(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = self
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isHidden = true  // hidden until depth mode is activated
        setupPipeline(pixelFormat: view.colorPixelFormat)
        mtkView = view
    }

    private func setupPipeline(pixelFormat: MTLPixelFormat) {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("DepthHeatmap.metal is not compiled into the TruDepth target.")
        }
        guard let vertFn = library.makeFunction(name: "depth_heatmap_vert"),
              let fragFn = library.makeFunction(name: "depth_heatmap_frag") else {
            fatalError("Missing depth heatmap Metal functions in the default library.")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Failed to build the depth heatmap render pipeline: \(error.localizedDescription)")
        }
    }

    // Called from a background thread by LiveMeshViewModel.
    func update(depthMap: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, depthMap, nil, .r32Float, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex else { return }
        CVMetalTextureCacheFlush(cache, 0)
        let texture = CVMetalTextureGetTexture(cvTex)
        textureLock.lock()
        currentCVTexture = cvTex   // keep CVMetalTexture alive
        pendingDepthTexture = texture
        textureLock.unlock()
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        textureLock.lock()
        let texture = pendingDepthTexture
        textureLock.unlock()

        guard let texture,
              let pipeline = pipelineState,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&maxDepth, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
