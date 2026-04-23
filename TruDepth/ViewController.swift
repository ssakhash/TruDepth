import SwiftUI
import RoomPlan
import SceneKit
import QuickLook

// MARK: - Room Scan Screen

struct RoomScanView: View {
    @StateObject private var viewModel = RoomScanViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.phase {
            case .idle:
                idleScreen
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
            case .scanning:
                ZStack {
                    RoomCaptureContainer(captureView: viewModel.captureView)
                        .ignoresSafeArea()
                    scanningOverlay
                }
                .transition(.opacity)
            case .processing:
                processingScreen
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .center)))
            case .done:
                if let room = viewModel.capturedRoom, let url = viewModel.exportURL {
                    ModelViewerView(capturedRoom: room, exportURL: url,
                                    depthImageURL: viewModel.depthImageURL,
                                    onNewScan: viewModel.reset)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.phase)
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: viewModel.phase == .scanning)
        .alert("Scan Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.reset() }
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    // MARK: Idle

    private var idleScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accent)
                    .shadow(color: Color.accent.opacity(0.35), radius: 12)

                VStack(spacing: 8) {
                    Text("scan room")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white)
                    Text("Walk around your room.\nTruDepth will capture walls, doors,\nwindows, and furniture.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(DS.textSecondary))
                        .font(.body)
                        .frame(maxWidth: 280)
                }
                .padding(.top, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        viewModel.startScan()
                    }) {
                        Text("start scanning")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accent, in: Capsule())
                    }

                    Button(action: { dismiss() }) {
                        Text("Back")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(DS.textTertiary))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: Scanning

    private var scanningOverlay: some View {
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

            captureDepthButton
                .padding(.bottom, 16)

            wallProgressBar
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
        }
    }

    private var captureDepthButton: some View {
        Button(action: { viewModel.captureDepthSnapshot() }) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(viewModel.depthCaptureConfirmed ? 0.9 : 0.4), lineWidth: 2)
                    .frame(width: 56, height: 56)
                if viewModel.depthCaptureConfirmed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.depthCaptureConfirmed)
        .disabled(viewModel.depthCaptureConfirmed)
    }

    private var wallProgressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Walls detected")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(DS.textTertiary))
                Spacer()
                Text("\(viewModel.wallCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(DS.borderSubtle)).frame(height: 3)
                    Capsule()
                        .fill(Color.accent)
                        .frame(width: geo.size.width * min(1, CGFloat(viewModel.wallCount) / 8), height: 3)
                        .animation(.easeOut(duration: 0.3), value: viewModel.wallCount)
                }
            }
            .frame(height: 3)
        }
        .padding(14)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Processing

    private var processingScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Color.accent)
                Text("building 3d model…")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text("this may take a few seconds")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(DS.textSecondary))
            }
        }
    }
}

// MARK: - RoomCapture UIViewRepresentable

struct RoomCaptureContainer: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

// MARK: - Room Scan View Model

@MainActor
final class RoomScanViewModel: ObservableObject {

    // Associated values removed so Phase is simply Equatable.
    enum Phase: Equatable { case idle, scanning, processing, done }

    let captureView = RoomCaptureView()

    @Published var phase: Phase = .idle
    @Published var capturedRoom: CapturedRoom?
    @Published var exportURL: URL?
    @Published var depthImageURL: URL?
    @Published var statusText: String = "Point at walls to begin"
    @Published var wallCount: Int = 0
    @Published var depthCaptureConfirmed: Bool = false
    @Published var showError = false
    @Published var errorMessage = ""

    private var session: RoomCaptureSession { captureView.captureSession }
    private var wantsDepthCapture: Bool = false

    func startScan() {
        session.delegate = self
        session.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
    }

    func finishScan() {
        phase = .processing
        session.stop()
    }

    func cancelScan() {
        session.delegate = nil  // prevent late callbacks
        session.stop()
        wantsDepthCapture = false
        depthCaptureConfirmed = false
        phase = .idle
    }

    func reset() {
        capturedRoom = nil
        exportURL = nil
        depthImageURL = nil
        wallCount = 0
        wantsDepthCapture = false
        depthCaptureConfirmed = false
        statusText = "Point at walls to begin"
        phase = .idle
    }

    func captureDepthSnapshot() {
        wantsDepthCapture = true
        depthCaptureConfirmed = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            depthCaptureConfirmed = false
        }
    }

    // Runs a brief ARSession (after RoomPlan session has stopped) to grab one depth frame.
    private func captureOneDepthFrame() async -> UIImage? {
        let arSession = ARSession()
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        arSession.run(config)
        defer { arSession.pause() }

        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if let depthMap = arSession.currentFrame?.sceneDepth?.depthMap {
                return Self.depthMapToImage(depthMap)
            }
        }
        return nil
    }

    // Converts a Float32 depth CVPixelBuffer to a jet-colormap UIImage (portrait oriented).
    static func depthMapToImage(_ depthMap: CVPixelBuffer, maxDepth: Float = 5.0) -> UIImage? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let ptr = base.assumingMemoryBound(to: Float32.self)

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let d = ptr[row * stride + col]
                let idx = (row * w + col) * 4
                if d > 0 && d <= maxDepth * 1.5 {
                    let t = min(max(d / maxDepth, 0), 1)
                    rgba[idx]     = UInt8(max(0, min(1, 1.5 - abs(4.0 * t - 3.0))) * 255)
                    rgba[idx + 1] = UInt8(max(0, min(1, 1.5 - abs(4.0 * t - 2.0))) * 255)
                    rgba[idx + 2] = UInt8(max(0, min(1, 1.5 - abs(4.0 * t - 1.0))) * 255)
                    rgba[idx + 3] = 255
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }

        // Rotate 90° CW so portrait screen matches landscape depth buffer.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: h, height: w))
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: CGFloat(h), y: 0)
            ctx.cgContext.rotate(by: .pi / 2)
            ctx.cgContext.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
}

extension RoomScanViewModel: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let walls = room.walls.count
        let objects = room.objects.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            wallCount = walls
            statusText = walls < 4
                ? "\(walls) wall\(walls == 1 ? "" : "s") found — keep scanning"
                : "\(walls) walls · \(objects) object\(objects == 1 ? "" : "s")"
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didEndWith data: CapturedRoomData,
                                    error: Error?) {
        if let error {
            Task { @MainActor [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
                self?.phase = .idle
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let builder = RoomBuilder(options: [.beautifyObjects])
                let room = try await builder.capturedRoom(from: data)

                var depthImage: UIImage?
                if wantsDepthCapture {
                    depthImage = await captureOneDepthFrame()
                    wantsDepthCapture = false
                }

                let record = try ScanStore.shared.save(room: room, depthImage: depthImage)
                capturedRoom = room
                exportURL = record.url
                depthImageURL = record.depthURL
                phase = .done
            } catch {
                errorMessage = error.localizedDescription
                showError = true
                phase = .idle
            }
        }
    }
}

// MARK: - 3D Model Viewer

struct ModelViewerView: View {
    let capturedRoom: CapturedRoom?   // nil when opened from scan history
    let exportURL: URL?
    var depthImageURL: URL? = nil
    let onNewScan: () -> Void

    @State private var quickLookURL: URL?
    @State private var depthImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            // Full-bleed SceneKit
            if let url = exportURL {
                SceneKitModelView(url: url)
                    .ignoresSafeArea()
            }

            // Top controls
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.12), in: Capsule())
                    }

                    Spacer()

                    Text("room model")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.12), in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Spacer()
            }

            // Frosted bottom sheet
            bottomSheet
        }
        .toolbar(.hidden, for: .navigationBar)
        .quickLookPreview($quickLookURL)
        .task {
            if let url = depthImageURL,
               let data = try? Data(contentsOf: url) {
                depthImage = UIImage(data: data)
            }
        }
    }

    private var bottomSheet: some View {
        VStack(spacing: 20) {
            if let capturedRoom {
                roomStats(for: capturedRoom)
            }
            if let img = depthImage {
                depthThumbnail(img)
            }
            actionButtons
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .background(
            Color.black,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 28, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 28,
                style: .continuous
            )
        )
    }

    private func depthThumbnail(_ img: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("depth snapshot")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text("raw lidar depth · jet colormap")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(12)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func roomStats(for room: CapturedRoom) -> some View {
        HStack(spacing: 0) {
            statItem(value: "\(room.walls.count)", label: "walls")
            statDivider
            statItem(value: "\(room.doors.count)", label: "doors")
            statDivider
            statItem(value: "\(room.windows.count)", label: "windows")
            statDivider
            statItem(value: "\(room.objects.count)", label: "objects")
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(DS.textTertiary))
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.white.opacity(DS.borderSubtle))
            .frame(width: 1, height: 32)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let url = exportURL {
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
                    subject: Text("Room Scan"),
                    message: Text("Scanned with TruDepth")
                ) {
                    Label("export usdz", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(white: 0.1), in: Capsule())
                }

                if let depthURL = depthImageURL {
                    ShareLink(item: depthURL,
                              subject: Text("Depth Snapshot"),
                              message: Text("LiDAR depth · Scanned with TruDepth")) {
                        Label("export depth png", systemImage: "camera.aperture")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(white: 0.1), in: Capsule())
                    }
                }
            }

            Button(action: onNewScan) {
                Text("scan again")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(DS.textTertiary))
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - SceneKit Viewer (async USDZ load)

struct SceneKitModelView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.defaultCameraController.interactionMode = .orbitTurntable

        let capturedURL = url
        Task.detached(priority: .userInitiated) {
            guard let scene = try? SCNScene(url: capturedURL) else { return }
            let cam = SCNCamera()
            cam.fieldOfView = 60
            cam.zFar = 100
            let camNode = SCNNode()
            camNode.camera = cam
            camNode.position = SCNVector3(0, 3, 6)
            camNode.look(at: SCNVector3(0, 0, 0))
            await MainActor.run {
                scene.rootNode.addChildNode(camNode)
                sceneView.scene = scene
                sceneView.pointOfView = camNode
            }
        }

        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - Scan History Store

final class ScanStore: ObservableObject {

    static let shared = ScanStore()

    @Published var scans: [ScanRecord] = []

    let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("TruDepthScans")
    }()

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([ScanRecord].self, from: data) else { return }
        // Remove stale entries whose files were deleted outside the app.
        scans = records.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func save(room: CapturedRoom, depthImage: UIImage? = nil) throws -> ScanRecord {
        let id = UUID()
        let filename = "\(id.uuidString).usdz"
        let url = directory.appendingPathComponent(filename)
        try room.export(to: url)

        var depthFilename: String?
        if let depthImage, let pngData = depthImage.pngData() {
            let df = "\(id.uuidString)_depth.png"
            try pngData.write(to: directory.appendingPathComponent(df), options: .atomic)
            depthFilename = df
        }

        let record = ScanRecord(id: id, date: Date(), filename: filename, depthFilename: depthFilename)
        DispatchQueue.main.async { self.scans.append(record) }
        try persist()
        return record
    }

    func saveObject(exportURL: URL) throws {
        let filename = exportURL.lastPathComponent
        let dest = directory.appendingPathComponent(filename)
        if exportURL != dest {
            try? FileManager.default.moveItem(at: exportURL, to: dest)
        }
        let record = ScanRecord(id: UUID(), date: Date(), filename: filename,
                                depthFilename: nil, scanType: .object)
        DispatchQueue.main.async { self.scans.append(record) }
        try persist()
    }

    func delete(_ record: ScanRecord) {
        try? FileManager.default.removeItem(at: record.url)
        if let depthURL = record.depthURL {
            try? FileManager.default.removeItem(at: depthURL)
        }
        scans.removeAll { $0.id == record.id }
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(scans)
        try data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Scan Type

enum ScanType: String, Codable { case room, object }

// MARK: - Scan Record

struct ScanRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let scanType: ScanType
    private let filename: String
    private let depthFilename: String?

    private static func scansDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("TruDepthScans")
    }

    // URLs are always derived from current Documents path — safe across reinstalls.
    var url: URL { Self.scansDirectory().appendingPathComponent(filename) }
    var depthURL: URL? { depthFilename.map { Self.scansDirectory().appendingPathComponent($0) } }

    var formattedDate: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    var fileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    init(id: UUID = UUID(), date: Date = Date(), filename: String,
         depthFilename: String? = nil, scanType: ScanType = .room) {
        self.id = id
        self.date = date
        self.filename = filename
        self.depthFilename = depthFilename
        self.scanType = scanType
    }

    // Backward-compatible decode: old records without scanType default to .room.
    enum CodingKeys: String, CodingKey { case id, date, filename, depthFilename, scanType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self, forKey: .id)
        date         = try c.decode(Date.self, forKey: .date)
        filename     = try c.decode(String.self, forKey: .filename)
        depthFilename = try c.decodeIfPresent(String.self, forKey: .depthFilename)
        scanType     = try c.decodeIfPresent(ScanType.self, forKey: .scanType) ?? .room
    }
}
