import UIKit
import ARKit

class ViewController: UIViewController, ARSessionDelegate {
    
    @IBOutlet weak var imageView: UIImageView!

    let session = ARSession()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.delegate = self
        session.run(configuration)
        imageView.contentMode = .scaleAspectFill
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthData = frame.sceneDepth else { return }
        
        if let depthImage = depthDataToUIImage(from: depthData) {
            DispatchQueue.main.async {
                self.imageView.image = depthImage
            }
        }
    }
    
    func depthDataToUIImage(from depthData: ARDepthData) -> UIImage? {
        let depthMap: CVPixelBuffer = depthData.depthMap
        var ciImage = CIImage(cvPixelBuffer: depthMap)
        
        // Crop the image to the center with the desired size
        let desiredSize = CGSize(width: 400, height: 400)
        ciImage = cropToCenter(image: ciImage, size: desiredSize)
        
        let scaledImage = ciImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 1/3, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1/3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 1/3, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

        // Create a new UIImage from the CGImage, rotated by 90 degrees
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    
    func cropToCenter(image: CIImage, size: CGSize) -> CIImage {
        let originX = (image.extent.size.width - size.width) / 2
        let originY = (image.extent.size.height - size.height) / 2
        let cropRect = CGRect(x: originX, y: originY, width: size.width, height: size.height)
        return image.cropped(to: cropRect)
    }
}
