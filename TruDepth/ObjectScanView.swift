import SwiftUI
import ARKit
import RealityKit

struct ObjectScanView: View {
    @StateObject private var model = ObjectScanModel()
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack(alignment: .bottom) {
            ObjectARView(model: model).ignoresSafeArea(edges: .bottom)
            VStack(spacing: 10) {
                Text(model.status).font(.subheadline).multilineTextAlignment(.center)
                if let dimensions = model.asset?.dimensions { Text(dimensions.formatted(inches: false)).monospacedDigit() }
                if model.volume != nil && !model.busy {
                    DisclosureGroup("Adjust crop") {
                        cropSlider("Width", value: $model.width, range: 0.05...2)
                        cropSlider("Height", value: $model.height, range: 0.05...2)
                        cropSlider("Depth", value: $model.depth, range: 0.05...2)
                        cropSlider("Rotation", value: $model.yaw, range: -Float.pi...Float.pi)
                        Text("Tap the supporting surface to reposition the box.").font(.caption)
                    }
                    .onChange(of: model.width) { model.adjustVolume() }.onChange(of: model.height) { model.adjustVolume() }
                    .onChange(of: model.depth) { model.adjustVolume() }.onChange(of: model.yaw) { model.adjustVolume() }
                }
                if model.busy { ProgressView("Saving model locally...") }
                else if !model.running { Button("Start LiDAR scan") { model.start() }.buttonStyle(.borderedProminent) }
                else {
                    Text("Views: \(model.coverage.sectors.count)/4 minimum").font(.caption)
                    Button("Done") { model.finish() }.buttonStyle(.borderedProminent).disabled(!model.canFinish)
                }
            }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
        }.scanNavigation("quick item scan")
        .awakeDuringScan(model.running || model.busy)
        .onChange(of: model.result?.id) { if let result = model.result { router.result(result) } }
        .onChange(of: scenePhase) { if scenePhase == .background { model.stop() } }
        .onDisappear { model.stop() }
        .alert("Item scan", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func cropSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack { Text(title).frame(width: 70, alignment: .leading); Slider(value: value, in: range) }
    }
}

@MainActor final class ObjectScanModel: ObservableObject {
    let arView: ARView = {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        CapturePreviewRendering.configure(view)
        return view
    }()
    @Published var status = "Keep the object still. Walk around it with your iPhone."
    @Published var running = false
    @Published var busy = false
    @Published var error: String?
    @Published var result: ScanRecord?
    @Published var asset: ScanAsset?
    @Published var volume: ObjectCaptureVolume?
    @Published var coverage = ViewpointCoverage()
    @Published var width: Float = 0.24
    @Published var height: Float = 0.20
    @Published var depth: Float = 0.24
    @Published var yaw: Float = 0
    private var baseTransform: simd_float4x4?
    private let cropAnchor = AnchorEntity(world: .zero)
    private var bridge: ObjectFrameBridge?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var record: ScanRecord?
    private var trackingNormal = false
    private var cropVersion = UUID()
    var canFinish: Bool { running && trackingNormal && coverage.sufficient && asset != nil }

    func start() {
        guard !running, !busy else { return }
        guard ScanCapability.objectScan.isSupported else { error = "LiDAR mesh capture is not supported on this device."; return }
        generation = UUID(); let token = generation
        busy = true
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                try await CameraAccess.require(); try Task.checkCancellation()
                record = try await ScanStore.shared.create(.quickObject)
                guard token == generation else { return }
                coverage = ViewpointCoverage(); volume = nil; asset = nil; result = nil
                let bridge = makeBridge(token: token)
                self.bridge = bridge
                arView.session.delegate = bridge
                arView.session.delegateQueue = bridge.queue
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = .mesh; config.planeDetection = [.horizontal]
                config.environmentTexturing = .none; config.wantsHDREnvironmentTextures = false
                arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                arView.scene.addAnchor(cropAnchor)
                running = true; status = "Tap the supporting surface beneath the object to place the crop box."
            } catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    func place(_ point: CGPoint) {
        guard running, let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first else {
            status = "Move slowly until a horizontal surface is detected, then tap again."; return
        }
        baseTransform = hit.worldTransform; adjustVolume()
    }
    func adjustVolume() {
        guard var base = baseTransform else { return }
        base = base * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        base.columns.3 += base.columns.1 * (height * 0.5)
        let volume = ObjectCaptureVolume(transform: base, extent: SIMD3(width, height, depth))
        self.volume = volume; coverage = ViewpointCoverage(); asset = nil
        cropVersion = UUID()
        bridge?.setVolume(volume, version: cropVersion)
        cropAnchor.children.removeAll()
        let box = CapturePreviewRendering.cropOutline(extent: volume.extent)
        box.transform = Transform(matrix: volume.transform); cropAnchor.addChild(box)
    }
    private func makeBridge(token: UUID) -> ObjectFrameBridge {
        ObjectFrameBridge(callback: { [weak self] asset, camera, normal, version in
            Task { @MainActor in self?.receive(asset, camera: camera, normal: normal, token: token, version: version) }
        }, interrupted: { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.stop(); self.status = message
            }
        })
    }
    private func receive(_ asset: ScanAsset?, camera: SIMD3<Float>, normal: Bool, token: UUID, version: UUID) {
        guard running, token == generation, version == cropVersion, let volume else { return }
        self.asset = asset; trackingNormal = normal
        let center = volume.transform.columns.3
        if asset != nil { coverage.observe(camera: camera, center: SIMD3(center.x, center.y, center.z), trackingNormal: normal) }
        let touches = asset.map(volume.touchesBoundary) ?? false
        status = !normal ? "Tracking limited. Move slowly in good light." : touches ? "Geometry touches the crop boundary. Check the box for clipping or background." : canFinish ? "Ready. Review the crop, then save." : "Walk around the stationary object to capture more viewpoints."
    }
    func finish() {
        guard canFinish, let asset, let record else { return }
        running = false; busy = true; arView.session.pause(); arView.session.delegate = nil
        let token = generation
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                try await ScanStore.shared.repository.saveSources(record.id, files: ["mesh.json": .data(try JSONEncoder().encode(asset))])
                try Task.checkCancellation()
                let ready = try await ScanStore.shared.retry(record)
                if token == generation { result = ready }
            } catch {
                await ScanStore.shared.mark(record.id, state: .failed, failure: error.localizedDescription)
                if token == generation { self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        generation = UUID(); job?.cancel(); job = nil
        arView.session.delegate = nil; arView.session.pause(); cropAnchor.removeFromParent(); bridge = nil
        running = false; busy = false
        if let record, result == nil {
            let asset = asset
            Task {
                do {
                    if let asset { try await ScanStore.shared.repository.saveSources(record.id, files: ["mesh.json": .data(try JSONEncoder().encode(asset))]) }
                    await ScanStore.shared.mark(record.id, state: .interrupted)
                } catch { ScanStore.shared.error = error.localizedDescription }
            }
        }
        record = nil
    }
}

// ARKit calls are serialized on queue; only crop configuration crosses queues under lock.
private final class ObjectFrameBridge: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "TruDepth.mesh-snapshots", qos: .userInitiated)
    private let lock = NSLock()
    private var volume: ObjectCaptureVolume?
    private var version = UUID()
    private var lastTime: TimeInterval = 0
    private let callback: @Sendable (ScanAsset?, SIMD3<Float>, Bool, UUID) -> Void
    private let interrupted: @Sendable (String) -> Void
    init(callback: @escaping @Sendable (ScanAsset?, SIMD3<Float>, Bool, UUID) -> Void,
         interrupted: @escaping @Sendable (String) -> Void) { self.callback = callback; self.interrupted = interrupted }
    func setVolume(_ value: ObjectCaptureVolume, version: UUID) { lock.lock(); volume = value; self.version = version; lock.unlock() }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState != .nominal
        let interval: TimeInterval = constrained ? 0.7 : 0.35
        guard frame.timestamp - lastTime >= interval else { return }; lastTime = frame.timestamp
        lock.lock(); let crop = volume; let version = version; lock.unlock()
        guard let crop else { return }
        var meshes: [MeshSnapshot] = []
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            let geometry = anchor.geometry
            guard geometry.vertices.format == .float3, geometry.faces.indexCountPerPrimitive == 3 else { continue }
            guard geometry.faces.count * 3 * geometry.faces.bytesPerIndex <= geometry.faces.buffer.length else { continue }
            let bytes = UnsafeRawBufferPointer(start: geometry.vertices.buffer.contents(), count: geometry.vertices.buffer.length)
            guard let positions = try? MeshSnapshot.copyPositions(from: bytes, count: geometry.vertices.count,
                stride: geometry.vertices.stride, offset: geometry.vertices.offset) else { continue }
            let faces = geometry.faces
            guard faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4 else { continue }
            let indices = (0..<faces.count*3).map { i -> UInt32 in
                let pointer = faces.buffer.contents() + i * faces.bytesPerIndex
                return faces.bytesPerIndex == 2 ? UInt32(pointer.loadUnaligned(as: UInt16.self)) : pointer.loadUnaligned(as: UInt32.self)
            }
            let snapshot = MeshSnapshot(name: "Object", positions: positions, indices: indices)
            if let cropped = try? crop.crop(snapshot, anchorTransform: anchor.transform) { meshes.append(cropped) }
        }
        let p = frame.camera.transform.columns.3
        callback(try? ScanAsset(meshes: meshes).validated(), SIMD3(p.x, p.y, p.z), frame.camera.trackingState == .normal, version)
    }
    func sessionWasInterrupted(_ session: ARSession) { interrupted("Capture interrupted. Saved geometry is in history; start a new scan to continue capturing.") }
    func session(_ session: ARSession, didFailWithError error: Error) { interrupted(error.localizedDescription) }
}

struct ObjectARView: UIViewRepresentable {
    let model: ObjectScanModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIView(context: Context) -> ARView {
        model.arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return model.arView
    }
    func updateUIView(_ view: ARView, context: Context) {}
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) { view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) } }
    @MainActor final class Coordinator: NSObject {
        let model: ObjectScanModel
        init(_ model: ObjectScanModel) { self.model = model }
        @objc func tap(_ gesture: UITapGestureRecognizer) { model.place(gesture.location(in: model.arView)) }
    }
}
