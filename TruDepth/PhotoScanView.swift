import SwiftUI
import RealityKit

struct PhotoScanView: View {
    @StateObject private var model = PhotoScanModel()
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack(alignment: .bottom) {
            if let session = model.session { ObjectCaptureView(session: session).ignoresSafeArea(edges: .bottom) }
            VStack(spacing: 12) {
                Text(model.status).multilineTextAlignment(.center)
                if model.processing {
                    ProgressView(value: model.progress)
                    Text("Keep TruDepth open while reconstructing. Sources and checkpoints are retained.").font(.caption)
                    Button("Cancel Processing") { model.stop() }
                } else if let session = model.session {
                    if session.isPaused { Button("Resume capture") { session.resume() } }
                    switch session.state {
                    case .ready: Button("Detect Object") { _ = session.startDetecting() }.buttonStyle(.borderedProminent)
                    case .detecting: Button("Start Capture") { session.startCapturing() }.buttonStyle(.borderedProminent)
                    case .capturing:
                        Text("\(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages) images").font(.caption)
                        if session.userCompletedScanPass {
                            Button("Another pass") { session.beginNewScanPass() }
                            Button("Flip object for underside") { session.beginNewScanPassAfterFlip() }
                        }
                        Button("Build Model") { session.finish() }.buttonStyle(.borderedProminent)
                            .disabled((!session.userCompletedScanPass && session.numberOfShotsTaken < session.maximumNumberOfInputImages) || session.numberOfShotsTaken < 20)
                    case .initializing, .finishing: ProgressView()
                    case .completed: ProgressView("Preparing reconstruction...")
                    case .failed: Button("Start New Capture") { model.start() }
                    @unknown default: EmptyView()
                    }
                } else if model.starting { ProgressView("Preparing capture...") }
                else { Button("Start Photo Scan") { model.start() }.buttonStyle(.borderedProminent) }
            }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
        }.scanNavigation("detailed item scan")
        .awakeDuringScan(model.session != nil || model.processing)
        .onChange(of: model.result?.id) { if let result = model.result { router.result(result) } }
        .onChange(of: scenePhase) { if scenePhase == .background { model.suspend() } }
        .onDisappear { model.stop() }
        .alert("Photo scan", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@MainActor final class PhotoScanModel: ObservableObject {
    @Published var session: ObjectCaptureSession?
    @Published var processing = false
    @Published var starting = false
    @Published var progress: Double = 0
    @Published var status = "Choose a well-lit, textured object. Keep it still and walk around it."
    @Published var error: String?
    @Published var result: ScanRecord?
    private var record: ScanRecord?
    private var job: Task<Void, Never>?
    private var feedbackJob: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        guard !starting else { return }
        guard ScanCapability.photoScan.isSupported else { error = "Guided photo capture and on-device reconstruction are unavailable on this device."; return }
        stop(); generation = UUID(); let token = generation
        result = nil; progress = 0; starting = true
        job = Task {
            defer { if token == generation { starting = false } }
            var captureRecord: ScanRecord?
            do {
                try await CameraAccess.require(); try Task.checkCancellation()
                let record = try await ScanStore.shared.create(.detailedObject)
                captureRecord = record
                try Task.checkCancellation()
                guard token == generation else { return }
                self.record = record
                let sources = await ScanStore.shared.repository.directory(for: record.id).appendingPathComponent("Sources")
                try Task.checkCancellation()
                let session = ObjectCaptureSession()
                var config = ObjectCaptureSession.Configuration()
                config.checkpointDirectory = sources.appendingPathComponent("Checkpoints")
                config.isOverCaptureEnabled = false
                self.session = session
                starting = false
                session.start(imagesDirectory: sources.appendingPathComponent("Images"), configuration: config)
                feedbackJob = Task {
                    for await feedback in session.feedbackUpdates {
                        guard token == generation else { return }
                        status = Self.message(feedback)
                    }
                }
                for await state in session.stateUpdates {
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    if case .failed(let failure) = state { throw failure }
                    if case .completed = state {
                        processing = true; status = "Reconstructing on this iPhone..."
                        feedbackJob?.cancel()
                        let ready = try await ScanStore.shared.retry(record) { value in
                            await MainActor.run { self.progress = value }
                        }
                        guard token == generation else { return }
                        result = ready; processing = false
                        return
                    }
                }
            } catch {
                if let captureRecord { await ScanStore.shared.mark(captureRecord.id, state: .failed, failure: error.localizedDescription) }
                if token == generation { self.error = error.localizedDescription; processing = false }
            }
        }
    }
    func suspend() {
        if processing || starting { stop(); status = "Processing interrupted. Retry from history to reuse saved sources and checkpoints." }
        else { session?.pause() }
    }
    func stop() {
        generation = UUID(); job?.cancel(); feedbackJob?.cancel()
        session?.cancel(); session = nil; processing = false; starting = false
        if let record, result == nil { Task { await ScanStore.shared.mark(record.id, state: .interrupted) } }
        record = nil
    }
    private static func message(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String {
        if feedback.contains(.environmentTooDark) || feedback.contains(.environmentLowLight) { return "More light will improve your model." }
        if feedback.contains(.movingTooFast) { return "Move more slowly around the object." }
        if feedback.contains(.objectTooClose) { return "Move farther from the object." }
        if feedback.contains(.objectTooFar) { return "Move closer to the object." }
        if feedback.contains(.outOfFieldOfView) { return "Keep the whole object in view." }
        if feedback.contains(.overCapturing) { return "Enough photos captured. Finish this pass." }
        return "Walk around the object, following the capture guide."
    }
}
