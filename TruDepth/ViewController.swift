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
            switch viewModel.phase {
            case .idle:
                idleScreen
            case .scanning:
                ZStack {
                    RoomCaptureContainer(captureView: viewModel.captureView)
                        .ignoresSafeArea()
                    scanningOverlay
                }
            case .processing:
                processingScreen
            case .done(let room, let url):
                ModelViewerView(capturedRoom: room, exportURL: url, onNewScan: viewModel.reset)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(viewModel.phase == .scanning)
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
            VStack(spacing: 32) {
                Image(systemName: "house.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "30D158"), Color(hex: "0A84FF")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 10) {
                    Text("Room Scan")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("Walk around your room.\nTruDepth will capture walls, doors,\nwindows, and furniture.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.55))
                        .font(.subheadline)
                }

                VStack(spacing: 12) {
                    Button(action: viewModel.startScan) {
                        Text("Start Scanning")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Button(action: { dismiss() }) {
                        Text("Back")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding()
        }
    }

    // MARK: Scanning

    private var scanningOverlay: some View {
        VStack {
            HStack {
                Button(action: viewModel.cancelScan) {
                    Text("Cancel")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                }

                Spacer()

                Text(viewModel.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button(action: viewModel.finishScan) {
                    Text("Done")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(hex: "30D158").opacity(0.9), in: Capsule())
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
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(viewModel.wallCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                    Capsule()
                        .fill(Color(hex: "30D158"))
                        .frame(width: geo.size.width * min(1, CGFloat(viewModel.wallCount) / 8), height: 4)
                        .animation(.easeOut(duration: 0.3), value: viewModel.wallCount)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Processing

    private var processingScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Building 3D Model…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This may take a few seconds")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
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

    enum Phase: Equatable {
        case idle
        case scanning
        case processing
        case done(CapturedRoom, URL)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning), (.processing, .processing): true
            case (.done, .done): true
            default: false
            }
        }
    }

    let captureView = RoomCaptureView()

    @Published var phase: Phase = .idle
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
        session.stop()
        phase = .idle
    }

    func reset() {
        phase = .idle
        wallCount = 0
        statusText = "Point at walls to begin"
    }
}

extension RoomScanViewModel: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let walls = room.walls.count
        let objects = room.objects.count
        Task { @MainActor [weak self] in
            self?.wallCount = walls
            self?.statusText = walls < 4
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
                let url = try self.exportRoom(room)
                self.phase = .done(room, url)
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
                self.phase = .idle
            }
        }
    }

    private func exportRoom(_ room: CapturedRoom) throws -> URL {
        let filename = "TruDepth_\(Int(Date().timeIntervalSince1970)).usdz"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try room.export(to: url)
        return url
    }
}

// MARK: - 3D Model Viewer

struct ModelViewerView: View {
    let capturedRoom: CapturedRoom
    let exportURL: URL?
    let onNewScan: () -> Void

    @State private var quickLookURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)

                if let url = exportURL {
                    SceneKitModelView(url: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScreen.main.bounds.height * 0.52)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                roomStats
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                Spacer()

                actionButtons
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
            }
        }
        .navigationBarHidden(true)
        .quickLookPreview($quickLookURL)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Room Model")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Drag to orbit · Pinch to zoom")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var roomStats: some View {
        HStack(spacing: 10) {
            StatChip(icon: "square.split.bottomrightquarter.fill",
                     value: "\(capturedRoom.walls.count)",
                     label: "Walls")
            StatChip(icon: "door.left.hand.open",
                     value: "\(capturedRoom.doors.count)",
                     label: "Doors")
            StatChip(icon: "window.horizontal",
                     value: "\(capturedRoom.windows.count)",
                     label: "Windows")
            StatChip(icon: "chair.lounge.fill",
                     value: "\(capturedRoom.objects.count)",
                     label: "Objects")
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let url = exportURL {
                Button(action: { quickLookURL = url }) {
                    Label("View in AR / QuickLook", systemImage: "arkit")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
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
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                }
            }

            Button(action: onNewScan) {
                Text("Scan Again")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - SceneKit Viewer

struct SceneKitModelView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        if let scene = try? SCNScene(url: url) {
            view.scene = scene
            view.pointOfView = defaultCamera(for: scene)
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func defaultCamera(for scene: SCNScene) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 60
        camera.zFar = 100
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 3, 6)
        node.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(node)
        return node
    }
}

// MARK: - Stat Chip

struct StatChip: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.callout)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
