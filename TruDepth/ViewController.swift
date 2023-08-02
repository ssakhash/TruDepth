//MARK: - Import necessary frameworks
import ARKit
import AVFoundation
import UIKit

// MARK: - ViewController class definition
class ViewController: UIViewController, ARSessionDelegate {
    
    //MARK: - Outlets
    //MARK: ImageView to display depth data
    @IBOutlet weak var imageView: UIImageView!
    //MARK: ImageView to display live camera feed
    @IBOutlet weak var liveFeedView: UIImageView!
    
    //MARK: - Variables
    //MARK: Instance of ARSession
    var session: ARSession!
    
    //MARK: - Life Cycle
    // Set up AR session when view loads
    override func viewDidLoad() {
        super.viewDidLoad()
        setupARSession()
    }
    
    // MARK: - Setup ARSession
    // Set up ARSession with world tracking and scene depth configuration
    func setupARSession() {
        session = ARSession()
        session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.run(configuration)
    }
    
    // MARK: - ARSession Delegate Methods
    // When ARSession updates, get camera feed and depth data
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update live feed view with camera feed
        updateLiveFeedView(with: frame)
        
        // Update image view with depth data
        updateImageView(with: frame)
    }
    
    // Display the camera feed on the liveFeedView
    private func updateLiveFeedView(with frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let croppedImage = cropToSquare(image: ciImage)
        liveFeedView.image = UIImage(ciImage: croppedImage)
    }

    // Display the depth data on the imageView
    private func updateImageView(with frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        let depthImage = CIImage(cvPixelBuffer: depthMap).oriented(.right)
        let croppedDepthImage = cropToSquare(image: depthImage)
        let gridPoints = generateGridPoints(for: croppedDepthImage.extent)
        let depthValues = self.depthValues(for: gridPoints, in: depthMap)
        let finalImage = drawPoints(on: UIImage(ciImage: croppedDepthImage), points: gridPoints, values: depthValues)
        imageView.image = finalImage
    }

    // Crop the input image to a square
    private func cropToSquare(image: CIImage) -> CIImage {
        let extent = image.extent
        let length = min(extent.width, extent.height)
        let origin = CGPoint(x: (extent.width - length) / 2, y: (extent.height - length) / 2)
        let squareExtent = CGRect(origin: origin, size: CGSize(width: length, height: length))

        return image.cropped(to: squareExtent)
    }

    // Generate a grid of points within the given rectangle
    private func generateGridPoints(for extent: CGRect) -> [CGPoint] {
        var points = [CGPoint]()
        for i in 1...7 {
            for j in 1...7 {
                let point = CGPoint(x: CGFloat(j) / 8, y: 1 - CGFloat(i) / 8) // Mirrored points
                points.append(point)
            }
        }
        return points
    }


    // Get the depth values for the given points from the pixel buffer
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

    // Draw the points and values on the image
    private func drawPoints(on image: UIImage, points: [CGPoint], values: [Float]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let newImage = renderer.image { (context) in
            image.draw(at: .zero)
            
            // Set up the text attributes
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 6),
                .foregroundColor: UIColor.black,
            ]
            
            for (index, point) in points.enumerated() {
                let x = point.x * image.size.width
                let y = point.y * image.size.height
                
                // Check if the distance is within 5 meters
                if values[index] <= 5 {
                    // If within 5 meters, set the color to green
                    context.cgContext.setFillColor(UIColor.green.cgColor)
                } else {
                    // If beyond 5 meters, set the color to red
                    context.cgContext.setFillColor(UIColor.red.cgColor)
                }
                
                context.cgContext.addArc(center: CGPoint(x: x, y: y), radius: 1.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                context.cgContext.drawPath(using: .fill)
                
                // Draw the text
                let valueString = String(format: "%.2f m", values[index])
                let textPoint = CGPoint(x: x - 5, y: y - 10)  // adjust the y value as needed
                valueString.draw(at: textPoint, withAttributes: textAttributes)
            }
        }
        return newImage
    }
}
