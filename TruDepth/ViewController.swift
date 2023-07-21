import UIKit
import ARKit

class ViewController: UIViewController, ARSessionDelegate {
    
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var liveFeedView: UIImageView!
    
    let session = ARSession()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.delegate = self
        session.run(configuration)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthData = frame.sceneDepth else { return }
        
        let depthValues = depthValuesForPoints(from: depthData.depthMap)
        
        if let depthImage = depthDataToUIImage(from: depthData),
           let markedImage = drawPointsAndDistances(on: depthImage, depthValues: depthValues) {
            DispatchQueue.main.async {
                self.imageView.image = markedImage
            }
        }
        
        // Get the camera image from the ARFrame
        let pixelBuffer = frame.capturedImage
        if let image = UIImage(pixelBuffer: pixelBuffer) {
            DispatchQueue.main.async {
                self.liveFeedView.image = image
            }
        }
    }
    
    func drawPointsAndDistances(on image: UIImage, depthValues: [Float]) -> UIImage? {
        let scale = UIScreen.main.scale
        UIGraphicsBeginImageContextWithOptions(image.size, false, scale)
        
        image.draw(at: .zero)
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5),
            .foregroundColor: UIColor.white
        ]
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        context.setFillColor(UIColor.red.cgColor)
        context.setLineWidth(1.0)
        
        let pointSize: CGFloat = 2.0
        
        let gridDimensions = 5
        for i in 0..<depthValues.count {
            let col = gridDimensions - 1 - i / gridDimensions
            let row = i % gridDimensions
            let squareWidth = image.size.width / CGFloat(gridDimensions + 1)
            let squareHeight = image.size.height / CGFloat(gridDimensions + 1)
            let x = (CGFloat(col) + 1) * squareWidth
            let y = (CGFloat(row) + 1) * squareHeight
            let point = CGRect(x: x - pointSize / 2, y: y - pointSize / 2, width: pointSize, height: pointSize)
            
            context.fillEllipse(in: point)
            
            let depthInMeters = depthValues[i]
            let depthString = String(format: "%.2f m", depthInMeters)
            let textPoint = CGPoint(x: x-10, y: y - pointSize / 2 - 15)
            depthString.draw(at: textPoint, withAttributes: attributes)
        }
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        
        UIGraphicsEndImageContext()
        
        return newImage
    }


    func depthDataToUIImage(from depthData: ARDepthData) -> UIImage? {
        let depthMap: CVPixelBuffer = depthData.depthMap
        var ciImage = CIImage(cvPixelBuffer: depthMap)
        
        // adjustment for the intensity scale
        let maxDepth: CGFloat = 5.0 // maximum depth to be considered
        ciImage = ciImage.applyingFilter("CIColorControls", parameters: ["inputBrightness": 0, "inputContrast": 1, "inputSaturation": 0])
        ciImage = ciImage.applyingFilter("CILinearToSRGBToneCurve")
        ciImage = ciImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1/maxDepth, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1/maxDepth, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1/maxDepth, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    func depthValuesForPoints(from depthMap: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 0))
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        let squareWidth = width / 6
        let squareHeight = height / 6

        var depthValues: [Float] = []
        
        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthMap), to: UnsafeMutablePointer<Float>.self)
        
        for y in 1...5 {
            for x in 1...5 {
                let pixelPosition = ((y * squareHeight) * width) + (x * squareWidth)
                let depthValue = floatBuffer[pixelPosition]
                depthValues.append(depthValue)
            }
        }
        
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 0))

        return depthValues
    }
}

extension UIImage {
    convenience init?(pixelBuffer: CVPixelBuffer) {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Create a rotation transform (90 degrees in radians)
        let rotationDegrees = -90.0
        let rotationRadians = CGFloat(rotationDegrees * (Double.pi / 180.0))
        let rotationTransform = CGAffineTransform(rotationAngle: rotationRadians)

        // Apply the rotation
        ciImage = ciImage.transformed(by: rotationTransform)
        
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        self.init(cgImage: cgImage)
    }
}
