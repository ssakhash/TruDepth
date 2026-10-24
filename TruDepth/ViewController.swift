import SwiftUI
import RoomPlan
import ARKit

struct RoomScanView: View {
    @StateObject private var model = RoomScanModel()
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack(alignment: .bottom) {
            if let captureView = model.captureView {
                RoomCaptureContainer(view: captureView).ignoresSafeArea(edges: .bottom)
            } else { Color.black.ignoresSafeArea(edges: .bottom) }
            VStack(spacing: 12) {
                Text(model.status).multilineTextAlignment(.center)
                if let notice = model.sourceNotice {
                    Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if model.busy { ProgressView("Saving room locally...") }
                else if model.scanning {
                    HStack {
                        Button("Depth snapshot") { model.snapshot() }.disabled(model.snapshotBusy)
                        Button("Finish Room") { model.finishRoom() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    if model.hasPendingRoom {
                        Button("Retry Room Save") { model.retryRoomSave() }.buttonStyle(.borderedProminent)
                        Text("Keep this screen open until the room is saved.").font(.caption)
                    }
                    if model.roomCount > 0 {
                        Text("\(model.roomCount) room(s) saved on this iPhone").font(.caption).foregroundStyle(.secondary)
                        Button("Finish Project") { model.finishProject() }.buttonStyle(.borderedProminent).disabled(model.hasPendingRoom)
                    }
                    if !model.coordinateFrameLost && !model.hasPendingRoom {
                        Button(model.roomCount == 0 ? "Start Room Scan" : "Add Connected Room") { model.startRoom() }.buttonStyle(.bordered)
                    }
                }
            }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
        }.scanNavigation("scan rooms", hasUnsavedChanges: model.hasPendingRoom)
        .awakeDuringScan(model.scanning || model.busy || (model.roomCount > 0 && !model.coordinateFrameLost))
        .onChange(of: model.result?.id) { if let result = model.result { router.result(result) } }
        .onChange(of: scenePhase) { if scenePhase == .background { model.interrupt() } }
        .onDisappear { model.stop() }
        .alert("Room scan", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ view: RoomCaptureView, context: Context) {}
}

// The app owns room processing and its result viewer; do not create another
// RealityKit model preview inside RoomCaptureView when capture stops.
@objc(TruDepthRoomCapturePresentation)
private final class RoomCapturePresentation: NSObject, RoomCaptureViewDelegate {
    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { false }
}

@MainActor final class RoomScanModel: NSObject, ObservableObject, RoomCaptureSessionDelegate {
    @Published private(set) var captureView: RoomCaptureView?
    private let presentation = RoomCapturePresentation()
    @Published var scanning = false
    @Published var busy = false
    @Published var snapshotBusy = false
    @Published var roomCount = 0
    @Published var coordinateFrameLost = false
    @Published var status = "Scan connected rooms in one session. Completed rooms are saved immediately."
    @Published var error: String?
    @Published var sourceNotice: String?
    @Published var result: ScanRecord?
    @Published private(set) var hasPendingRoom = false
    private var pendingRoom: CapturedRoomData?
    private var record: ScanRecord?
    private var job: Task<Void, Never>?
    private var depthJob: Task<Void, Never>?
    private var generation = UUID()
    private var expectingResult = false

    func startRoom() {
        guard ScanCapability.roomScan.isSupported else { error = "RoomPlan requires a supported LiDAR device."; return }
        guard !coordinateFrameLost, !scanning, !busy, !hasPendingRoom else { return }
        if roomCount > 0, captureView?.captureSession.arSession.currentFrame?.camera.trackingState != .normal {
            interrupt()
            return
        }
        busy = true; let token = generation
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                try await CameraAccess.require(); try Task.checkCancellation()
                if record == nil { record = try await ScanStore.shared.create(.room) }
                guard token == generation else { return }
                if captureView == nil {
                    let view = RoomCaptureView(frame: .zero, arSession: ARSession())
                    view.isModelEnabled = false
                    view.delegate = presentation
                    captureView = view
                }
                guard let captureView else { return }
                captureView.captureSession.delegate = self
                captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
                scanning = true; status = "Walk slowly through this room. Keep walls and openings in view."
            } catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    func finishRoom() {
        guard scanning else { return }
        scanning = false; busy = true; expectingResult = true
        captureView?.captureSession.stop(pauseARSession: false)
    }
    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self] in self?.updated(room) }
    }
    private func updated(_ room: CapturedRoom) {
        guard scanning else { return }
        status = "\(room.walls.count) walls · \(room.objects.count) objects"
    }
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let message: String
        switch instruction {
        case .moveCloseToWall: message = "Move closer to the wall."
        case .moveAwayFromWall: message = "Move farther from the wall."
        case .slowDown: message = "Move more slowly."
        case .turnOnLight: message = "More light will improve tracking."
        case .lowTexture: message = "Point toward textured surfaces and room edges to improve tracking."
        case .normal: return
        @unknown default: return
        }
        Task { @MainActor [weak self] in if self?.scanning == true { self?.status = message } }
    }
    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor [weak self] in self?.ended(data, error: error) }
    }
    private func ended(_ data: CapturedRoomData, error: Error?) {
        guard expectingResult || scanning else { return }
        expectingResult = false; scanning = false
        if let error {
            self.error = ScanOperationFailure("Finishing room capture", error: error).message
            coordinateFrameLost = true; busy = false
            status = "Tracking ended. Finish the saved rooms or start a new project."
            return
        }
        pendingRoom = data; hasPendingRoom = true
        busy = false
        retryRoomSave()
    }
    func retryRoomSave() {
        guard !busy, let data = pendingRoom, let record else { return }
        busy = true; error = nil
        let token = generation
        let next = roomCount + 1
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                let warning = try await ScanProcessing.shared.saveRoom(data, id: record.id, number: next,
                    repository: ScanStore.shared.repository)
                // Reflect durable success even if the screen was closed during the write.
                await ScanStore.shared.mark(record.id, state: .capturing, roomCount: next)
                guard token == generation else { return }
                roomCount = next; pendingRoom = nil; hasPendingRoom = false
                status = coordinateFrameLost ? "Room saved. Finish this project; start a new project to capture more." :
                    "Room saved. Walk to the next connected room or finish this project."
                sourceNotice = warning == nil ? nil : "Room saved with processed source data only. Raw sensor archive unavailable; details are in History."
            } catch is CancellationError {
                // The pending capture remains available if the screen is still open.
            } catch {
                await ScanStore.shared.mark(record.id, state: .failed, failure: error.localizedDescription, roomCount: next - 1)
                guard token == generation else { return }
                self.error = error.localizedDescription
                coordinateFrameLost = true
                status = "Room save failed. The capture is still in memory; keep this screen open and tap Retry Room Save."
            }
        }
    }
    func snapshot() {
        guard !snapshotBusy, let frame = captureView?.captureSession.arSession.currentFrame else { return }
        do {
            let snapshot = try DepthSnapshot.capture(frame)
            snapshotBusy = true
            depthJob = Task {
                defer { snapshotBusy = false }
                do { _ = try await ScanStore.shared.saveDepth(snapshot); status = "Depth snapshot saved to history." }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func finishProject() {
        guard let record, roomCount > 0, !busy, !hasPendingRoom else { return }
        busy = true; captureView?.captureSession.arSession.pause()
        let token = generation
        job = Task {
            defer { if token == generation { busy = false } }
            do {
                let ready = try await ScanStore.shared.retry(record)
                if token == generation { result = ready }
            } catch { self.error = error.localizedDescription }
        }
    }
    func interrupt() {
        guard record != nil else { stop(); return }
        coordinateFrameLost = true
        status = "Session interrupted. Saved rooms can be finalized; start a new project to capture more."
        stop()
    }
    func stop() {
        generation = UUID(); expectingResult = false
        if record != nil { coordinateFrameLost = true }
        job?.cancel(); job = nil
        captureView?.captureSession.delegate = nil
        captureView?.captureSession.stop(pauseARSession: true)
        captureView?.delegate = nil
        captureView = nil
        scanning = false; busy = false
        if let record, result == nil {
            Task { await ScanStore.shared.mark(record.id, state: .interrupted, roomCount: roomCount) }
        }
    }
}
