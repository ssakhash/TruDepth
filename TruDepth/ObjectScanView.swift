import SwiftUI
import ARKit
import RealityKit
import ModelIO
import simd

// MARK: - Object Scan Screen

struct ObjectScanView: View {
    @StateObject private var viewModel = ObjectScanViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var quickLookURL: URL?

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
                doneScreen
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.phase)
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: viewModel.phase == .capturing)
        .quickLookPreview($quickLookURL)
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
                    Text("back")
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
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if let dims = viewModel.liveDimensions {
                dimensionsHUD(dims)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: viewModel.liveDimensions != nil)
    }

    // MARK: Processing

    private var processingScreen: some View {
        VStack(spacing: 16) {
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

    // MARK: Done

    private var doneScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.accent)

            if let dims = viewModel.finalDimensions {
                VStack(spacing: 8) {
                    Text("scan complete")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.white)
                        .padding(.top, 16)
                    dimensionsHUD(dims)
                        .padding(.top, 4)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                if let url = viewModel.exportURL {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        quickLookURL = url
                    }) {
                        Label("view in ar / quicklook", systemImage: "arkit")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accent, in: Capsule())
                    }

                    ShareLink(
                        item: url,
                        subject: Text("Object Scan"),
                        message: Text("Scanned with TruDepth")
                    ) {
                        Label("export usdz", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(white: 0.1), in: Capsule())
                    }
                }

                Button(action: {
                    viewModel.reset()
                }) {
                    Text("scan again")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
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
}

// MARK: - ARView Container

struct ARObjectContainer: UIViewRepresentable {
    let viewModel: ObjectScanViewModel

    func makeUIView(context: Context) -> ARView { viewModel.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Object Scan View Model

@MainActor
final class ObjectScanViewModel: ObservableObject {

    enum Phase: Equatable { case idle, capturing, processing, done }

    let arView: ARView = {
        let v = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        v.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        return v
    }()

    @Published var phase: Phase = .idle
    @Published var exportURL: URL?
    @Published var statusText: String = "slowly rotate the object"
    @Published var liveDimensions: SIMD3<Float>?
    @Published var finalDimensions: SIMD3<Float>?

    let isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private var dimensionsTimer: Timer?

    func startScan() {
        guard isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.planeDetection = [.horizontal]
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.debugOptions = [.showSceneUnderstanding]
        phase = .capturing
        startDimensionsPolling()
    }

    func finishScan() {
        dimensionsTimer?.invalidate()
        finalDimensions = computeBoundingBox()
        phase = .processing
        arView.session.pause()

        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let dims = finalDimensions

        Task {
            let url = await Self.exportAnchors(anchors)
            if let url {
                try? ScanStore.shared.saveObject(exportURL: url)
            }
            exportURL = url
            phase = .done
        }
    }

    func cancelScan() {
        dimensionsTimer?.invalidate()
        arView.session.pause()
        phase = .idle
    }

    func reset() {
        exportURL = nil
        liveDimensions = nil
        finalDimensions = nil
        statusText = "slowly rotate the object"
        phase = .idle
    }

    // MARK: - Dimensions

    private func startDimensionsPolling() {
        dimensionsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.liveDimensions = self?.computeBoundingBox()
                if let count = self?.arView.session.currentFrame?.anchors
                    .compactMap({ $0 as? ARMeshAnchor }).count, count > 0 {
                    self?.statusText = "rotate to expose all sides"
                }
            }
        }
    }

    private func computeBoundingBox() -> SIMD3<Float>? {
        guard let frame = arView.session.currentFrame else { return nil }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        var minX = Float.greatestFiniteMagnitude,  minY = Float.greatestFiniteMagnitude,  minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude

        for anchor in meshAnchors {
            let geo = anchor.geometry
            let ptr = geo.vertices.buffer.contents()
            let stride = geo.vertices.stride
            let offset = geo.vertices.offset
            for i in 0..<geo.vertices.count {
                let local: SIMD3<Float> = (ptr + offset + i * stride)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                minX = Swift.min(minX, world4.x); maxX = Swift.max(maxX, world4.x)
                minY = Swift.min(minY, world4.y); maxY = Swift.max(maxY, world4.y)
                minZ = Swift.min(minZ, world4.z); maxZ = Swift.max(maxZ, world4.z)
            }
        }

        let dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ
        guard dx > 0.001 && dy > 0.001 && dz > 0.001 else { return nil }
        return SIMD3<Float>(dx, dy, dz)
    }

    // MARK: - USDZ Export

    private static func exportAnchors(_ anchors: [ARMeshAnchor]) async -> URL? {
        guard !anchors.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("TruDepthScans")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString)_object.usdz")

            let asset = MDLAsset()
            let allocator = MDLMeshBufferDataAllocator()

            for anchor in anchors {
                let geo = anchor.geometry
                guard geo.vertices.count > 0, geo.faces.count > 0 else { continue }

                // World-space vertex positions
                let srcPtr = geo.vertices.buffer.contents()
                let stride = geo.vertices.stride
                let vOffset = geo.vertices.offset
                var positions = [SIMD3<Float>]()
                positions.reserveCapacity(geo.vertices.count)
                for i in 0..<geo.vertices.count {
                    let local: SIMD3<Float> = (srcPtr + vOffset + i * stride)
                        .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let w = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                    positions.append(SIMD3<Float>(w.x, w.y, w.z))
                }

                let posData = positions.withUnsafeBytes { Data($0) }
                let vBuf = allocator.newBuffer(with: posData, type: .vertex)

                // Index data
                let faceBytes = geo.faces.count * 3 * geo.faces.bytesPerIndex
                let faceData = Data(bytes: geo.faces.buffer.contents(), count: faceBytes)
                let iBuf = allocator.newBuffer(with: faceData, type: .index)
                let idxType: MDLIndexBitDepth = geo.faces.bytesPerIndex == 4 ? .uInt32 : .uInt16

                let submesh = MDLSubmesh(indexBuffer: iBuf, indexCount: geo.faces.count * 3,
                                        indexType: idxType, geometryType: .triangles, material: nil)

                let descriptor = MDLVertexDescriptor()
                descriptor.attributes[0] = MDLVertexAttribute(
                    name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
                descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)

                let mesh = MDLMesh(vertexBuffer: vBuf, vertexCount: positions.count,
                                   descriptor: descriptor, submeshes: [submesh])
                asset.add(mesh)
            }

            do {
                try asset.export(to: url)
                return url
            } catch {
                return nil
            }
        }.value
    }
}
