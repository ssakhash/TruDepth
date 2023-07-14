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
        
        let depthValues = depthValuesForNinePoints(from: depthData.depthMap)
        
        if let depthImage = depthDataToUIImage(from: depthData),
           let markedImage = drawPointsAndDistances(on: depthImage, depthValues: depthValues) {
            DispatchQueue.main.async {
                self.imageView.image = markedImage
            }
        }
    }
    
    func drawPointsAndDistances(on image: UIImage, depthValues: [Float]) -> UIImage? {
        UIGraphicsBeginImageContext(image.size)
        
        image.draw(at: .zero)
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.red,
            .strokeWidth: -1.0,
            .strokeColor: UIColor.white
        ]
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        context.setFillColor(UIColor.cyan.cgColor) // Vibrant color
        context.setStrokeColor(UIColor.black.cgColor) // Border color
        context.setLineWidth(2.0) // Border width
        
        let pointSize: CGFloat = 6.0
        
        let gridDimensions = 3
        for i in 0..<depthValues.count {
            let row = i / gridDimensions
            let col = i % gridDimensions
            let squareWidth = image.size.width / CGFloat(gridDimensions + 1)
            let squareHeight = image.size.height / CGFloat(gridDimensions + 1)
            let x = (CGFloat(col) + 1) * squareWidth
            let y = (CGFloat(row) + 1) * squareHeight
            let point = CGRect(x: x - pointSize / 2, y: y - pointSize / 2, width: pointSize, height: pointSize)
            
            context.fillEllipse(in: point)
            context.strokeEllipse(in: point) // Draw the border
            
            let depthInMeters = depthValues[i]
            let depthString = String(format: "%.2f m", depthInMeters)
            let textPoint = CGPoint(x: x, y: y - pointSize / 2 - 20)
            depthString.draw(at: textPoint, withAttributes: attributes)
        }
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        
        UIGraphicsEndImageContext()
        
        return newImage
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

    func depthValuesForNinePoints(from depthMap: CVPixelBuffer) -> [Float] {
        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 0))
        
        // Get the width and height of the buffer
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Determine the dimensions of the squares
        let squareWidth = width / 4
        let squareHeight = height / 4

        // Create an array to store the depth values
        var depthValues: [Float] = []
        
        // Get the pointer to the pixel values
        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(depthMap), to: UnsafeMutablePointer<Float>.self)
        
        // Get the depth values for the 9 points
        for y in 1...3 {
            for x in 1...3 {
                let pixelPosition = ((y * squareHeight) * width) + (x * squareWidth)
                let depthValue = floatBuffer[pixelPosition]
                depthValues.append(depthValue)
            }
        }
        
        // Unlock the base address of the pixel buffer
        CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 0))

        return depthValues
    }
    
    func cropToCenter(image: CIImage, size: CGSize) -> CIImage {
        let originX = (image.extent.size.width - size.width) / 2
        let originY = (image.extent.size.height - size.height) / 2
        let cropRect = CGRect(x: originX, y: originY, width: size.width, height: size.height)
        return image.cropped(to: cropRect)
    }
}
