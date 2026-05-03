import SwiftUI
import ARKit
import RealityKit
import ModelIO
import simd

// MARK: - Object Scan Screen

struct ObjectScanView: View {
    @StateObject private var viewModel = ObjectScanViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.phase {
            case .idle:
                idleScreen
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
            case .capturing:
                ZStack {
                    if viewModel.isSupported {
                        ARObjectContainer(viewModel: viewModel).ignoresSafeArea()
                    }
                    capturingOverlay
                }
                .transition(.opacity)
            case .processing:
                processingScreen
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
            case .done:
                if let url = viewModel.exportURL {
                    ModelViewerView(
                        capturedRoom: nil,
                        exportURL: url,
                        title: "object model",
                        dismissLabel: "main menu",
                        onNewScan: viewModel.reset
                    )
                    .transition(.opacity)
                } else {
                    doneScreen
                        .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.phase)
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: viewModel.phase == .capturing)
        .onDisappear { viewModel.cancelScan() }
    }

    // MARK: Idle

    private var idleScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "cube.transparent")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 8) {
                Text("scan item")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Text("Place the object on a flat surface.\nKeep the phone still and slowly\nrotate the object in front of it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.body)
                    .frame(maxWidth: 280)
            }

            if !viewModel.isSupported {
                Text("LiDAR required — not available on this device")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 12)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.startScan()
                }) {
                    Text("start scanning")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(viewModel.isSupported ? .black : .white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            viewModel.isSupported ? Color.accent : Color(white: 0.15),
                            in: Capsule()
                        )
                }
                .disabled(!viewModel.isSupported)

                    Button(action: { dismiss() }) {
                        Text("main menu")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(DS.textTertiary))
                    }
                }
                .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }

    // MARK: Capturing

    private var capturingOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    viewModel.cancelScan()
                }) {
                    Text("cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.12), in: Capsule())
                }

                Spacer()

                Text(viewModel.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(.white.opacity(DS.textSecondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.12), in: Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.finishScan()
                }) {
                    Text("done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(viewModel.canFinishScan ? .black : .white.opacity(0.4))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.canFinishScan ? Color.accent : Color(white: 0.15),
                            in: Capsule()
                        )
                }
                .disabled(!viewModel.canFinishScan)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if viewModel.captureVolume == nil {
                cropPlacementPrompt
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(0.96)))
            }

            if let dims = viewModel.liveDimensions {
                dimensionsHUD(dims)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            mainMenuButton
                .padding(.bottom, 32)
        }
        .animation(.spring(response: 0.4), value: viewModel.liveDimensions != nil)
    }

    // MARK: Processing

    private var processingScreen: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                mainMenuButton
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()
            ProgressView()
                .scaleEffect(1.5)
                .tint(Color.accent)
            Text("building object model…")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text("this may take a few seconds")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(DS.textSecondary))
            Spacer()
        }
    }

    // MARK: Done (fallback — only shown if export failed)

    private var doneScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.white.opacity(0.4))

            Text("export failed")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                Button(action: { viewModel.reset() }) {
                    Text("scan again")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                }

                mainMenuButton
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: Shared

    private func dimensionsHUD(_ dims: SIMD3<Float>) -> some View {
        HStack(spacing: 16) {
            dimLabel("W", value: dims.x)
            dimLabel("H", value: dims.y)
            dimLabel("D", value: dims.z)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(white: 0.1), in: Capsule())
    }

    private func dimLabel(_ axis: String, value: Float) -> some View {
        HStack(spacing: 4) {
            Text(axis)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(String(format: "%.0f cm", value * 100))
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
        }
    }

    private var cropPlacementPrompt: some View {
        Text("tap the object center to place the crop box")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.1), in: Capsule())
    }

    private var mainMenuButton: some View {
        Button(action: {
            viewModel.cancelScan()
            dismiss()
        }) {
            Text("main menu")
                .font(.caption)
                .foregroundStyle(.white.opacity(DS.textSecondary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.12), in: Capsule())
        }
    }
}

// MARK: - ARView Container

struct ObjectCaptureVolume: Equatable {
    static let defaultExtent = SIMD3<Float>(0.24, 0.20, 0.24)
    static let baseInset: Float = 0.01

    let center: SIMD3<Float>
    let extent: SIMD3<Float>
    let transform: simd_float4x4

    var halfExtent: SIMD3<Float> { extent * 0.5 }
    var inverseTransform: simd_float4x4 { simd_inverse(transform) }

    static func fromRaycast(_ raycast: ARRaycastResult, extent: SIMD3<Float> = defaultExtent) -> ObjectCaptureVolume {
        let worldTransform = raycast.worldTransform
        let planePoint = SIMD3<Float>(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
        let up = simd_normalize(SIMD3<Float>(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z))
        let center = planePoint + up * (extent.y * 0.5)

        var transform = worldTransform
        transform.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        return ObjectCaptureVolume(center: center, extent: extent, transform: transform)
    }

    func contains(worldPoint: SIMD3<Float>, inverseTransform: simd_float4x4? = nil) -> Bool {
        let local4 = (inverseTransform ?? self.inverseTransform) * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        let local = SIMD3<Float>(local4.x, local4.y, local4.z)
        let half = halfExtent

        return abs(local.x) <= half.x
            && local.y >= (-half.y + Self.baseInset)
            && local.y <= half.y
            && abs(local.z) <= half.z
    }
}

struct ARObjectContainer: UIViewRepresentable {
    let viewModel: ObjectScanViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> ARView {
        let view = viewModel.arView
        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    final class Coordinator: NSObject {
        let viewModel: ObjectScanViewModel

        init(viewModel: ObjectScanViewModel) {
            self.viewModel = viewModel
        }

        @MainActor @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view else { return }

            let location = recognizer.location(in: view)
            Task { @MainActor in
                viewModel.placeCaptureVolume(at: location)
            }
        }
    }
}

// MARK: - Object Scan View Model

@MainActor
final class ObjectScanViewModel: ObservableObject {

    private struct CaptureMetrics {
        let dimensions: SIMD3<Float>
        let pointCount: Int
        let fillsCaptureVolume: Bool
    }

    enum Phase: Equatable { case idle, capturing, processing, done }

    let arView: ARView = {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        return v
    }()

    @Published var phase: Phase = .idle
    @Published var exportURL: URL?
    @Published var statusText: String = "tap the object center to place crop box"
    @Published var liveDimensions: SIMD3<Float>?
    @Published var finalDimensions: SIMD3<Float>?
    @Published var captureVolume: ObjectCaptureVolume?
    @Published var canFinishScan = false

    let isSupported = ScanCapability.objectScan.isSupported

    private var dimensionsTimer: Timer?
    private let minimumCoveragePointCount = 250
    private let volumeFillThreshold: Float = 0.92
    private let volumeAnchor = AnchorEntity(world: .zero)

    init() {
        arView.scene.addAnchor(volumeAnchor)
        volumeAnchor.isEnabled = false
    }

    func startScan() {
        guard isSupported else { return }
        clearCaptureState()
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.debugOptions = [.showSceneUnderstanding]
        phase = .capturing
        startDimensionsPolling()
    }

    func placeCaptureVolume(at screenPoint: CGPoint) {
        guard phase == .capturing else { return }

        let exactResults = arView.raycast(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .horizontal)
        let estimatedResults = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal)

        guard let raycast = exactResults.first ?? estimatedResults.first else {
            statusText = "move closer to a flat surface and try again"
            canFinishScan = false
            return
        }

        captureVolume = ObjectCaptureVolume.fromRaycast(raycast)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refreshCaptureState()
    }

    func finishScan() {
        guard phase == .capturing,
              canFinishScan,
              let volume = captureVolume,
              let metrics = computeCaptureMetrics(for: volume) else {
            statusText = captureVolume == nil
                ? "tap the object center to place crop box"
                : "keep rotating inside the crop box"
            return
        }

        dimensionsTimer?.invalidate()
        dimensionsTimer = nil
        finalDimensions = metrics.dimensions
        phase = .processing
        arView.session.pause()

        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []

        Task {
            let exportedURL = await Self.exportAnchors(anchors, within: volume)
            if let exportedURL,
               let record = try? ScanStore.shared.saveObject(exportURL: exportedURL) {
                exportURL = record.url
            } else {
                exportURL = nil
            }
            phase = .done
        }
    }

    func cancelScan() {
        dimensionsTimer?.invalidate()
        dimensionsTimer = nil
        arView.session.pause()
        clearCaptureState()
        phase = .idle
    }

    func reset() {
        exportURL = nil
        finalDimensions = nil
        clearCaptureState()
        phase = .idle
    }

    // MARK: - Dimensions

    private func startDimensionsPolling() {
        dimensionsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCaptureState()
            }
        }
    }

    private func clearCaptureState() {
        liveDimensions = nil
        captureVolume = nil
        canFinishScan = false
        statusText = "tap the object center to place crop box"
        updateCaptureVolumeVisualization()
    }

    private func refreshCaptureState() {
        guard let volume = captureVolume else {
            liveDimensions = nil
            canFinishScan = false
            statusText = "tap the object center to place crop box"
            updateCaptureVolumeVisualization()
            return
        }

        guard let metrics = computeCaptureMetrics(for: volume) else {
            liveDimensions = nil
            canFinishScan = false
            statusText = "keep rotating inside the crop box"
            updateCaptureVolumeVisualization()
            return
        }

        liveDimensions = metrics.dimensions

        if metrics.fillsCaptureVolume {
            canFinishScan = false
            statusText = "crop box is clipping background — tap to reposition"
        } else if metrics.pointCount < minimumCoveragePointCount {
            canFinishScan = false
            statusText = "keep rotating inside the crop box"
        } else {
            canFinishScan = true
            statusText = "coverage looks good · ready to export"
        }

        updateCaptureVolumeVisualization()
    }

    private func computeBoundingBox() -> SIMD3<Float>? {
        guard let volume = captureVolume else { return nil }
        return computeCaptureMetrics(for: volume)?.dimensions
    }

    private func computeCaptureMetrics(for volume: ObjectCaptureVolume) -> CaptureMetrics? {
        guard let frame = arView.session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        let inverseTransform = volume.inverseTransform
        var minX = Float.greatestFiniteMagnitude,  minY = Float.greatestFiniteMagnitude,  minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        var pointCount = 0

        for anchor in meshAnchors {
            let geo = anchor.geometry
            let ptr = geo.vertices.buffer.contents()
            let stride = geo.vertices.stride
            let offset = geo.vertices.offset
            for i in 0..<geo.vertices.count {
                let local: SIMD3<Float> = (ptr + offset + i * stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                guard volume.contains(worldPoint: world, inverseTransform: inverseTransform) else { continue }

                pointCount += 1
                minX = Swift.min(minX, world.x); maxX = Swift.max(maxX, world.x)
                minY = Swift.min(minY, world.y); maxY = Swift.max(maxY, world.y)
                minZ = Swift.min(minZ, world.z); maxZ = Swift.max(maxZ, world.z)
            }
        }

        guard pointCount > 0 else { return nil }
        let dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ
        guard dx > 0.001 && dy > 0.001 && dz > 0.001 else { return nil }

        let occupancy = SIMD3<Float>(dx / volume.extent.x, dy / volume.extent.y, dz / volume.extent.z)
        let fillsCaptureVolume = occupancy.x >= volumeFillThreshold
            || occupancy.y >= 0.95
            || occupancy.z >= volumeFillThreshold

        return CaptureMetrics(
            dimensions: SIMD3<Float>(dx, dy, dz),
            pointCount: pointCount,
            fillsCaptureVolume: fillsCaptureVolume
        )
    }

    private func updateCaptureVolumeVisualization() {
        for child in Array(volumeAnchor.children) {
            child.removeFromParent()
        }

        guard let volume = captureVolume else {
            volumeAnchor.isEnabled = false
            return
        }

        volumeAnchor.isEnabled = true

        let tint: UIColor
        if canFinishScan {
            tint = UIColor.systemGreen
        } else if statusText.contains("clipping background") {
            tint = UIColor.systemRed
        } else {
            tint = UIColor.systemTeal
        }

        let material = SimpleMaterial(color: tint.withAlphaComponent(0.16), roughness: 1, isMetallic: false)
        let box = ModelEntity(mesh: .generateBox(size: volume.extent), materials: [material])
        box.transform = Transform(matrix: volume.transform)
        volumeAnchor.addChild(box)
    }

    // MARK: - USDZ Export

    private static func exportAnchors(_ anchors: [ARMeshAnchor], within volume: ObjectCaptureVolume) async -> URL? {
        guard !anchors.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("TruDepthScans")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString)_object.usdz")

            let asset = MDLAsset()
            let allocator = MDLMeshBufferDataAllocator()
            let inverseTransform = volume.inverseTransform
            var meshCount = 0

            for anchor in anchors {
                let geo = anchor.geometry
                guard geo.vertices.count > 0, geo.faces.count > 0 else { continue }

                let srcPtr = geo.vertices.buffer.contents()
                let stride = geo.vertices.stride
                let vOffset = geo.vertices.offset
                var positions = [SIMD3<Float>]()
                positions.reserveCapacity(geo.vertices.count)
                var remap = Array(repeating: -1, count: geo.vertices.count)

                for i in 0..<geo.vertices.count {
                    let local: SIMD3<Float> = (srcPtr + vOffset + i * stride)
                        .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                    let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                    guard volume.contains(worldPoint: world, inverseTransform: inverseTransform) else { continue }

                    remap[i] = positions.count
                    positions.append(world)
                }

                guard positions.count >= 3 else { continue }

                let faceBuffer = geo.faces.buffer.contents()
                let bytesPerIndex = geo.faces.bytesPerIndex
                var remappedIndices = [UInt32]()
                remappedIndices.reserveCapacity(geo.faces.count * 3)

                for faceIndex in 0..<geo.faces.count {
                    let baseOffset = faceIndex * 3 * bytesPerIndex
                    let i0 = readIndex(from: faceBuffer, byteOffset: baseOffset, bytesPerIndex: bytesPerIndex)
                    let i1 = readIndex(from: faceBuffer, byteOffset: baseOffset + bytesPerIndex, bytesPerIndex: bytesPerIndex)
                    let i2 = readIndex(from: faceBuffer, byteOffset: baseOffset + (2 * bytesPerIndex), bytesPerIndex: bytesPerIndex)

                    let m0 = remap[i0]
                    let m1 = remap[i1]
                    let m2 = remap[i2]
                    guard m0 >= 0, m1 >= 0, m2 >= 0 else { continue }

                    remappedIndices.append(UInt32(m0))
                    remappedIndices.append(UInt32(m1))
                    remappedIndices.append(UInt32(m2))
                }

                guard remappedIndices.count >= 3 else { continue }

                let posData = positions.withUnsafeBytes { Data($0) }
                let vBuf = allocator.newBuffer(with: posData, type: .vertex)

                let indexData = remappedIndices.withUnsafeBytes { Data($0) }
                let iBuf = allocator.newBuffer(with: indexData, type: .index)

                let submesh = MDLSubmesh(
                    indexBuffer: iBuf,
                    indexCount: remappedIndices.count,
                    indexType: .uInt32,
                    geometryType: .triangles,
                    material: nil
                )

                let descriptor = MDLVertexDescriptor()
                descriptor.attributes[0] = MDLVertexAttribute(
                    name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
                descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)

                let mesh = MDLMesh(vertexBuffer: vBuf, vertexCount: positions.count,
                                   descriptor: descriptor, submeshes: [submesh])
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
                asset.add(mesh)
                meshCount += 1
            }

            guard meshCount > 0 else { return nil }

            do {
                try asset.export(to: url)
                return url
            } catch {
                return nil
            }
        }.value
    }

    nonisolated private static func readIndex(from buffer: UnsafeRawPointer, byteOffset: Int, bytesPerIndex: Int) -> Int {
        switch bytesPerIndex {
        case 2:
            return Int(buffer.load(fromByteOffset: byteOffset, as: UInt16.self))
        default:
            return Int(buffer.load(fromByteOffset: byteOffset, as: UInt32.self))
        }
    }
}
