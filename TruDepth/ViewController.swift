/// MARK: - Import necessary frameworks
import ARKit         // Augmented Reality framework
import AVFoundation  // Framework for working with audio and video
import UIKit         // User interface kit for iOS apps

/// This ViewController handles the ARSession to display live camera feed and depth data.
class ViewController: UIViewController, ARSessionDelegate {
    
    // MARK: - Outlets
    /// ImageView to display the depth data.
    @IBOutlet weak var imageView: UIImageView!
    
    /// ImageView to display the live camera feed.
    @IBOutlet weak var liveFeedView: UIImageView!
    
    // MARK: - Variables
    /// Instance of ARSession to manage the augmented reality session.
    var session: ARSession!
    
    // MARK: - Life Cycle
    /// Set up AR session when the view loads.
    override func viewDidLoad() {
        super.viewDidLoad()
        setupARSession()
    }
    
    /// Configures and starts the ARSession with world tracking and scene depth.
    func setupARSession() {
        session = ARSession()
        session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        session.run(configuration)
    }
    
    /// ARSession delegate method called when the session updates.
    /// - Parameters:
    ///   - session: The current ARSession.
    ///   - frame: The current ARFrame.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateLiveFeedView(with: frame)  // Update the live feed view.
        updateImageView(with: frame)     // Update the depth data view.
    }
    
    /// Updates the liveFeedView with the camera feed.
    /// - Parameter frame: The current ARFrame.
    private func updateLiveFeedView(with frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let croppedImage = cropToSquare(image: ciImage)
        liveFeedView.image = UIImage(ciImage: croppedImage)
    }
    
    /// Updates the imageView with the depth data.
    /// - Parameter frame: The current ARFrame.
    private func updateImageView(with frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        let depthImage = CIImage(cvPixelBuffer: depthMap).oriented(.right)
        let croppedDepthImage = cropToSquare(image: depthImage)
        let gridPoints = generateGridPoints(for: croppedDepthImage.extent)
        let depthValues = self.depthValues(for: gridPoints, in: depthMap)
        let finalImage = drawPoints(on: UIImage(ciImage: croppedDepthImage), points: gridPoints, values: depthValues)
        imageView.image = finalImage
    }
    
    /// Crops the input image to form a square.
    /// - Parameter image: The image to crop.
    /// - Returns: Cropped square image.
    private func cropToSquare(image: CIImage) -> CIImage {
        let extent = image.extent
        let length = min(extent.width, extent.height)
        let origin = CGPoint(x: (extent.width - length) / 2, y: (extent.height - length) / 2)
        let squareExtent = CGRect(origin: origin, size: CGSize(width: length, height: length))

        return image.cropped(to: squareExtent)
    }
    
    /// Generates a grid of points within the given rectangle.
    /// - Parameter extent: The rectangle to generate grid points for.
    /// - Returns: Array of grid points.
    private func generateGridPoints(for extent: CGRect) -> [CGPoint] {
        var points = [CGPoint]()
        for i in 1...8 {
            for j in 1...8 {
                let point = CGPoint(x: CGFloat(j) / 9, y: 1 - CGFloat(i) / 9)
                points.append(point)
            }
        }
        return points
    }
    
    /// Gets the depth values for the given points from the pixel buffer.
    /// - Parameters:
    ///   - points: Array of grid points.
    ///   - pixelBuffer: The depth data pixel buffer.
    /// - Returns: Array of depth values.
    private func depthValues(for points: [CGPoint], in pixelBuffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var values = [Float]()

        let floatBuffer = unsafeBitCast(CVPixelBufferGetBaseAddress(pixelBuffer), to: UnsafeMutablePointer<Float>.self)

        for point in points {
            let x = Int(point.y * CGFloat(width))
            let y = Int((1 - point.x) * CGFloat(height))

            if x < width && y < height {
                let pixel = floatBuffer[y * width + x]
                values.append(pixel)
            } else {
                values.append(-1) // append -1 if index is out-of-bound.
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        return values
    }
    
    /// Draws the points and their corresponding depth values on the image.
    /// - Parameters:
    ///   - image: The base image to draw upon.
    ///   - points: Array of grid points.
    ///   - values: Array of depth values.
    /// - Returns: Image with drawn points and depth values.
    private func drawPoints(on image: UIImage, points: [CGPoint], values: [Float]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let newImage = renderer.image { (context) in
            image.draw(at: .zero)
            
            // Set up the text attributes
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 5),
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
                
                context.cgContext.addArc(center: CGPoint(x: x, y: y), radius: 1, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                context.cgContext.drawPath(using: .fill)
                
                // Draw the text
                let valueString = String(format: "%.2f m", values[index])
                let textPoint = CGPoint(x: x - 5, y: y - 10)
                valueString.draw(at: textPoint, withAttributes: textAttributes)
            }
        }
        return newImage
    }
}
