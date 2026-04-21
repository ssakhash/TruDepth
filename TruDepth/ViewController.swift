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
                    ModelViewerView(capturedRoom: room, exportURL: url, onNewScan: viewModel.reset)
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
                    Text("Scan Room")
                        .font(.system(size: 22, weight: .semibold))
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
                        Text("Start Scanning")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                }

                Spacer()

                Text(viewModel.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(.white.opacity(DS.textSecondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.finishScan()
                }) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.accent, in: Capsule())
                        .shadow(color: Color.accent.opacity(0.35), radius: 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            wallProgressBar
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
        }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }

    // MARK: Processing

    private var processingScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Color.accent)
                Text("Building 3D Model…")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text("This may take a few seconds")
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
    @Published var statusText: String = "Point at walls to begin"
    @Published var wallCount: Int = 0
    @Published var showError = false
    @Published var errorMessage = ""

    private var session: RoomCaptureSession { captureView.captureSession }

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
        phase = .idle
    }

    func reset() {
        capturedRoom = nil
        exportURL = nil
        wallCount = 0
        statusText = "Point at walls to begin"
        phase = .idle
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
                let record = try ScanStore.shared.save(room: room)
                capturedRoom = room
                exportURL = record.url
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
    let onNewScan: () -> Void

    @State private var quickLookURL: URL?
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
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    }

                    Spacer()

                    Text("Room Model")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
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
    }

    private var bottomSheet: some View {
        VStack(spacing: 20) {
            if let capturedRoom {
                roomStats(for: capturedRoom)
            }
            actionButtons
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .background(
            .regularMaterial,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 28, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 28,
                style: .continuous
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 28, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 28,
                style: .continuous
            )
            .strokeBorder(.white.opacity(DS.borderSubtle), lineWidth: 1)
        )
    }

    private func roomStats(for room: CapturedRoom) -> some View {
        HStack(spacing: 0) {
            statItem(value: "\(room.walls.count)", label: "Walls")
            statDivider
            statItem(value: "\(room.doors.count)", label: "Doors")
            statDivider
            statItem(value: "\(room.windows.count)", label: "Windows")
            statDivider
            statItem(value: "\(room.objects.count)", label: "Objects")
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
                    Label("View in AR / QuickLook", systemImage: "arkit")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                ShareLink(
                    item: url,
                    subject: Text("Room Scan"),
                    message: Text("Scanned with TruDepth")
                ) {
                    Label("Export USDZ", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(DS.borderDefault), lineWidth: 1)
                        )
                }
            }

            Button(action: onNewScan) {
                Text("Scan Again")
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

    func save(room: CapturedRoom) throws -> ScanRecord {
        let id = UUID()
        let filename = "\(id.uuidString).usdz"
        let url = directory.appendingPathComponent(filename)
        try room.export(to: url)
        let record = ScanRecord(id: id, date: Date(), filename: filename)
        DispatchQueue.main.async { self.scans.append(record) }
        try persist()
        return record
    }

    func delete(_ record: ScanRecord) {
        try? FileManager.default.removeItem(at: record.url)
        scans.removeAll { $0.id == record.id }
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(scans)
        try data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Scan Record

struct ScanRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    private let filename: String

    // URL is always derived from current Documents path — safe across reinstalls.
    var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("TruDepthScans").appendingPathComponent(filename)
    }

    var formattedDate: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    var fileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    init(id: UUID = UUID(), date: Date = Date(), filename: String) {
        self.id = id
        self.date = date
        self.filename = filename
    }
}
