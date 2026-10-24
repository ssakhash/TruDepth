import SwiftUI
import RealityKit
import Combine

struct RealityModelView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.renderOptions = [.disableHDR, .disableMotionBlur, .disableDepthOfField]
        view.environment.background = .color(.init(white: 0.04, alpha: 1))
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        context.coordinator.load(url, in: view)
        return view
    }
    func updateUIView(_ view: ARView, context: Context) { if context.coordinator.url != url { context.coordinator.load(url, in: view) } }
    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.subscription?.cancel(); coordinator.task?.cancel(); view.scene.anchors.removeAll()
    }
    @MainActor final class Coordinator: NSObject {
        var url: URL?
        var subscription: AnyCancellable?
        var task: Task<Void, Never>?
        weak var view: ARView?
        let camera = PerspectiveCamera()
        var center = SIMD3<Float>.zero
        var radius: Float = 1
        var yaw: Float = 0.6
        var pitch: Float = 0.35
        func load(_ url: URL, in view: ARView) {
            self.url = url; self.view = view
            subscription?.cancel(); task?.cancel(); view.scene.anchors.removeAll()
            view.subviews.filter { $0 is UILabel }.forEach { $0.removeFromSuperview() }
            let root = AnchorEntity(world: .zero)
            root.addChild(camera)
            let light = DirectionalLight(); light.light.intensity = 3000
            light.look(at: .zero, from: SIMD3(2, 4, 3), relativeTo: nil)
            root.addChild(light); view.scene.addAnchor(root)
            if #available(iOS 18, *) {
                task = Task {
                    do {
                        let entity = try await Entity(contentsOf: url)
                        try Task.checkCancellation()
                        install(entity, root: root)
                    } catch { if !Task.isCancelled { showError(error) } }
                }
            } else {
                subscription = Entity.loadAsync(contentsOf: url).receive(on: DispatchQueue.main).sink { [weak self] completion in
                    if case .failure(let error) = completion { self?.showError(error) }
                } receiveValue: { [weak self] entity in self?.install(entity, root: root) }
            }
        }
        func showError(_ error: Error) {
            guard let view else { return }
            let label = UILabel(frame: view.bounds); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.text = error.localizedDescription; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
            view.addSubview(label)
        }
        func install(_ entity: Entity, root: AnchorEntity) {
            root.addChild(entity)
            let bounds = entity.visualBounds(relativeTo: nil)
            center = bounds.center; radius = max(simd_length(bounds.extents) * 1.2, 0.1)
            camera.camera.near = max(radius / 1000, 0.001); camera.camera.far = max(radius * 20, 100)
            updateCamera()
        }
        func updateCamera() {
            let offset = SIMD3<Float>(sin(yaw)*cos(pitch), sin(pitch), cos(yaw)*cos(pitch))*radius
            camera.look(at: center, from: center + offset, relativeTo: nil)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: view); gesture.setTranslation(.zero, in: view)
            if gesture.numberOfTouches >= 2 {
                let right = camera.transform.matrix.columns.0
                center -= SIMD3(right.x, right.y, right.z)*Float(delta.x)*radius/500
                center.y += Float(delta.y)*radius/500
            } else { yaw -= Float(delta.x)*0.008; pitch = min(1.4, max(-1.4, pitch + Float(delta.y)*0.008)) }
            updateCamera()
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            radius = min(1000, max(0.01, radius / Float(gesture.scale))); gesture.scale = 1; updateCamera()
        }
    }
}
