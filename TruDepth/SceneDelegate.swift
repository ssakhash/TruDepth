import SwiftUI
import RealityKit
import ARKit
import MetalKit

struct LiveMeshView: View {
    @StateObject private var model = LiveDepthModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack(alignment: .bottom) {
            LiveARContainer(model: model).ignoresSafeArea(edges: .bottom)
            if model.depthMode {
                Color.black.ignoresSafeArea(edges: .bottom)
                if let renderer = model.renderer {
                    HeatmapContainer(renderer: renderer).rotationEffect(.degrees(180)).ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
                }
            }
            VStack(spacing: 12) {
                Text(model.distance).font(.system(.title, design: .monospaced))
                Picker("Display", selection: $model.depthMode) {
                    Text("Classify").tag(false)
                    Text("Depth").tag(true)
                }.pickerStyle(.segmented).onChange(of: model.depthMode) { model.applyMode() }
                if model.depthMode {
                    HStack { Text("Near").foregroundStyle(.blue); Spacer(); Text("5 m").foregroundStyle(.red) }.font(.caption)
                }
                Text(model.status).font(.caption).multilineTextAlignment(.center)
                Button("Save Depth Snapshot") { model.snapshot() }.buttonStyle(.borderedProminent).disabled(model.saving || !model.running)
                if model.saving { ProgressView() }
            }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
        }.scanNavigation("live depth")
        .awakeDuringScan(model.running)
        .task { await model.start() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await model.start() } } else if scenePhase == .background { model.stop() } }
        .onDisappear { model.stop() }
        .alert("Live depth", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@MainActor final class LiveDepthModel: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    @Published var depthMode = true
    @Published var distance = "-- m"
    @Published var status = "Depth snapshots include camera, confidence, and calibration data."
    @Published var error: String?
    @Published var saving = false
    @Published var running = false
    var renderer: DepthHeatmapRenderer?
    private var displayLink: CADisplayLink?
    private var lastFrame: TimeInterval = -1
    private var lastReadout: TimeInterval = -1
    private var generation = UUID()
    private var starting = false

    override init() {
        super.init()
        CapturePreviewRendering.configure(arView)
        do { renderer = try DepthHeatmapRenderer() }
        catch { self.error = error.localizedDescription }
    }
    func start() async {
        guard !running, !starting else { return }
        guard ScanCapability.liveDepth.isSupported else { error = "Live depth requires a LiDAR-equipped device."; return }
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        do {
            try await CameraAccess.require(); try Task.checkCancellation()
            guard token == generation else { return }
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = [.sceneDepth]
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { config.frameSemantics.insert(.smoothedSceneDepth) }
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) { config.sceneReconstruction = .meshWithClassification }
            arView.session.delegateQueue = .main; arView.session.delegate = self
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            running = true; applyMode()
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common); displayLink = link
        } catch { self.error = error.localizedDescription }
    }
    func applyMode() {
        arView.debugOptions = depthMode ? [] : [.showSceneUnderstanding]
        arView.environment.sceneUnderstanding.options = depthMode ? [] : [.occlusion]
        if !depthMode && !ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            status = "Classification is unavailable on this device. Depth remains available."
        }
    }
    @objc private func tick() {
        guard running, let frame = arView.session.currentFrame, frame.timestamp != lastFrame else { return }
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: constrained ? 30 : 60, preferred: constrained ? 30 : 60)
        lastFrame = frame.timestamp
        if depthMode, let data = frame.smoothedSceneDepth ?? frame.sceneDepth { renderer?.update(data) }
        if frame.timestamp - lastReadout > 0.1 {
            lastReadout = frame.timestamp
            distance = Self.centerDistance(frame.sceneDepth).map { String(format: "%.2f m", $0) } ?? "-- m"
        }
    }
    private static func centerDistance(_ data: ARDepthData?) -> Float? {
        guard let data, let confidence = data.confidenceMap else { return nil }
        let buffer = data.depthMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let values = CVPixelBufferGetBaseAddress(buffer), let mask = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var samples: [Float] = []
        for y in max(0, h/2-1)...min(h-1, h/2+1) { for x in max(0, w/2-1)...min(w-1, w/2+1) {
            let value = values.loadUnaligned(fromByteOffset: y*CVPixelBufferGetBytesPerRow(buffer)+x*4, as: Float.self)
            let level = mask.load(fromByteOffset: y*CVPixelBufferGetBytesPerRow(confidence)+x, as: UInt8.self)
            if value.isFinite && value > 0 && level >= 1 { samples.append(value) }
        } }
        return samples.isEmpty ? nil : samples.sorted()[samples.count/2]
    }
    func snapshot() {
        guard !saving, let frame = arView.session.currentFrame else { return }
        do {
            let snapshot = try DepthSnapshot.capture(frame)
            saving = true
            Task {
                defer { saving = false }
                do { _ = try await ScanStore.shared.saveDepth(snapshot); status = "Depth snapshot saved to history." }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); running = false; starting = false
        displayLink?.invalidate(); displayLink = nil
        arView.session.delegate = nil; arView.session.pause(); renderer?.clear()
        lastFrame = -1; lastReadout = -1; distance = "-- m"
    }
    func sessionWasInterrupted(_ session: ARSession) { distance = "-- m"; status = "Camera session interrupted." }
    func session(_ session: ARSession, didFailWithError error: Error) { self.error = error.localizedDescription; stop() }
}

struct LiveARContainer: UIViewRepresentable {
    let model: LiveDepthModel
    func makeUIView(context: Context) -> ARView { model.arView }
    func updateUIView(_ view: ARView, context: Context) {}
}
struct HeatmapContainer: UIViewRepresentable {
    let renderer: DepthHeatmapRenderer
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(); renderer.attach(view); return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
    static func dismantleUIView(_ view: MTKView, coordinator: ()) { view.delegate = nil; view.isPaused = true }
}

// Immutable retain-only owner: GPU completion keeps CoreVideo backing storage alive.
private final class DepthGPUFrame: @unchecked Sendable {
    let depth: CVPixelBuffer
    let confidence: CVPixelBuffer
    let depthTexture: CVMetalTexture
    let confidenceTexture: CVMetalTexture
    init(depth: CVPixelBuffer, confidence: CVPixelBuffer, depthTexture: CVMetalTexture, confidenceTexture: CVMetalTexture) {
        self.depth = depth; self.confidence = confidence; self.depthTexture = depthTexture; self.confidenceTexture = confidenceTexture
    }
}

@MainActor final class DepthHeatmapRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private weak var view: MTKView?
    private var frame: DepthGPUFrame?
    private var inflight = 0

    init(bundle: Bundle = .main) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ScanFailure.unsupportedAsset("Metal rendering is unavailable on this device.")
        }
        let library = try device.makeDefaultLibrary(bundle: bundle)
        guard let vertex = library.makeFunction(name: "depth_heatmap_vert"),
              let fragment = library.makeFunction(name: "depth_heatmap_frag") else {
            throw ScanFailure.unsupportedAsset("Depth rendering could not load its Metal shaders. Reinstall the app or report this error.")
        }
        self.device = device; self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else { throw ScanFailure.invalidGeometry }
    }
    func attach(_ view: MTKView) {
        view.device = device; view.colorPixelFormat = .bgra8Unorm
        view.delegate = self; view.isPaused = true; view.enableSetNeedsDisplay = false
        view.framebufferOnly = true; view.backgroundColor = .black; view.isUserInteractionEnabled = false
        self.view = view
    }
    func clear() { frame = nil }
    func update(_ data: ARDepthData) {
        guard inflight < 3, let cache, let confidence = data.confidenceMap else { return }
        let depth = data.depthMap
        var a: CVMetalTexture?, b: CVMetalTexture?
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, depth, nil, .r32Float, w, h, 0, &a) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, confidence, nil, .r8Uint, w, h, 0, &b) == kCVReturnSuccess,
              let a, let b else { return }
        frame = DepthGPUFrame(depth: depth, confidence: confidence, depthTexture: a, confidenceTexture: b)
        view?.draw()
    }
    func draw(in view: MTKView) {
        guard inflight < 3, let frame, let depth = CVMetalTextureGetTexture(frame.depthTexture), let confidence = CVMetalTextureGetTexture(frame.confidenceTexture),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var maxDepth: Float = 5
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(depth, index: 0); encoder.setFragmentTexture(confidence, index: 1)
        encoder.setFragmentBytes(&maxDepth, length: 4, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        inflight += 1
        command.addCompletedHandler { [frame, weak self] _ in
            withExtendedLifetime(frame) {}
            Task { @MainActor in self?.inflight -= 1 }
        }
        command.present(drawable); command.commit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
