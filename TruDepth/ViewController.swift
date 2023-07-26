import ARKit
import AVFoundation
import UIKit

class ViewController: UIViewController, ARSessionDelegate {
    //MARK: - Outlets
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var liveFeedView: UIImageView!
    
    //MARK: - Variables
    var session: ARSession!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupARSession()
    }
    
    // MARK: - Setup ARSession
    func setupARSession() {
        session = ARSession()
        session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.run(configuration)
    }
    
    // MARK: - ARSession Delegate Methods
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update live feed view with camera feed
        updateLiveFeedView(with: frame)
        
        // Update image view with depth data
        updateImageView(with: frame)
    }
    
    private func updateLiveFeedView(with frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let croppedImage = cropToSquare(image: ciImage)
        liveFeedView.image = UIImage(ciImage: croppedImage)
    }

    private func updateImageView(with frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        let depthImage = CIImage(cvPixelBuffer: depthMap).oriented(.right)
        let croppedDepthImage = cropToSquare(image: depthImage)
        let gridPoints = generateGridPoints(for: croppedDepthImage.extent)
        let depthValues = self.depthValues(for: gridPoints, in: depthMap)
        print(depthValues) // print depth values for debugging
        let finalImage = drawPoints(on: UIImage(ciImage: croppedDepthImage), points: gridPoints, values: depthValues)
        imageView.image = finalImage
    }

    private func cropToSquare(image: CIImage) -> CIImage {
        let extent = image.extent
        let length = min(extent.width, extent.height)
        let origin = CGPoint(x: (extent.width - length) / 2, y: (extent.height - length) / 2)
        let squareExtent = CGRect(origin: origin, size: CGSize(width: length, height: length))

        return image.cropped(to: squareExtent)
    }

    private func generateGridPoints(for extent: CGRect) -> [CGPoint] {
        var points = [CGPoint]()
        for i in 1...5 {
            for j in 1...5 {
                let point = CGPoint(x: CGFloat(j) / 6, y: 1 - CGFloat(i) / 6) // Mirrored points
                points.append(point)
            }
        }
        return points
    }

    private func depthValues(for points: [CGPoint], in pixelBuffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var values = [Float]()

        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(pixelBuffer), to: UnsafeMutablePointer<Float>.self)

        for point in points {
            let x = Int(point.y * CGFloat(width)) // Adjusted x
            let y = Int((1 - point.x) * CGFloat(height)) // Adjusted y, now mirrored

            if x < width && y < height {
                let pixel = floatBuffer[y * width + x]
                values.append(pixel)
            } else {
                values.append(-1) // if there's no value or the index is out-of-bound, append -1
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        return values
    }


    private func drawPoints(on image: UIImage, points: [CGPoint], values: [Float]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let newImage = renderer.image { (context) in
            image.draw(at: .zero)
            context.cgContext.setFillColor(UIColor.red.cgColor)

            // Set up the text attributes
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 7),
                .foregroundColor: UIColor.black,
            ]
            
            for (index, point) in points.enumerated() {
                let x = point.x * image.size.width
                let y = point.y * image.size.height
                context.cgContext.addArc(center: CGPoint(x: x, y: y), radius: 2, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                context.cgContext.drawPath(using: .fill)
                
                // Draw the text
                let valueString = String(format: "%.2f", values[index])
                let textPoint = CGPoint(x: x, y: y - 10)  // adjust the y value as needed
                valueString.draw(at: textPoint, withAttributes: textAttributes)
            }
        }
        return newImage
    }
}
