//
//  ViewController.swift
//  TruDepth
//
//  Created by Akhash Subramanian Shunmugam on 5/13/23.
//

import ARKit
import AVFoundation
import UIKit

// MARK: - ViewController
// This class handles AR functionality, including the AR Session and AR Frame updates. It also processes depth data.
class ViewController: UIViewController, ARSessionDelegate {
    
    //MARK: - Outlets
    // ImageView for showing depth data
    @IBOutlet weak var imageView: UIImageView!
    // ImageView for live camera feed
    @IBOutlet weak var liveFeedView: UIImageView!
        
    //MARK: - Variables
    // AR Session for managing AR experience
    var session: ARSession!
        
    // Function triggered when the view loads
    override func viewDidLoad() {
        super.viewDidLoad()
        // Sets up the AR Session
        setupARSession()
    }
        
    // MARK: - Setup ARSession
    // This function initializes ARSession and configures it for world tracking and depth data
    func setupARSession() {
        session = ARSession()
        session.delegate = self
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable depth data
        configuration.frameSemantics.insert(.sceneDepth)
        
        // Run the view's session
        session.run(configuration)
    }
        
    // MARK: - ARSession Delegate Methods
    // This function is called every time ARFrame updates
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update imageView with depth data
        if let depthMap = frame.sceneDepth?.depthMap {
            var ciImage = CIImage(cvPixelBuffer: depthMap)
            ciImage = ciImage.oriented(.right)
            if let uiImage = cropToCenter(image: ciImage) {
                let depthValues = depthValuesForPoints(from: depthMap)
                imageView.image = drawPointsAndDistances(on: uiImage, depthValues: depthValues)
            }
        }
            
        // Update liveFeedView with camera feed
        let pixelBuffer = frame.capturedImage
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciImage = ciImage.oriented(.right)
        liveFeedView.image = cropToCenter(image: ciImage)
    }
    
    // Function for drawing points and distances on an image
    func drawPointsAndDistances(on image: UIImage, depthValues: [Float]) -> UIImage? {
        let scale = UIScreen.main.scale
        UIGraphicsBeginImageContextWithOptions(image.size, false, scale)
        
        image.draw(at: .zero)
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5),
            .foregroundColor: UIColor.green
        ]
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        let pointSize: CGFloat = 1.5
        
        let gridDimensions = 5
        for i in 0..<depthValues.count {
            let col = gridDimensions - 1 - i / gridDimensions
            let row = i % gridDimensions
            let squareWidth = image.size.width / CGFloat(gridDimensions + 1)
            let squareHeight = image.size.height / CGFloat(gridDimensions + 1)
            let x = (CGFloat(col) + 1) * squareWidth
            let y = (CGFloat(row) + 1) * squareHeight
            let point = CGRect(x: x - pointSize / 2, y: y - pointSize / 2, width: pointSize, height: pointSize)
            
            let depthInMeters = depthValues[i]
            if depthInMeters <= 5.0 {
                context.setFillColor(UIColor.green.cgColor)
                let depthString = String(format: "%.2f m", depthInMeters)
                let textPoint = CGPoint(x: x-10, y: y - pointSize / 2 - 15)
                depthString.draw(at: textPoint, withAttributes: attributes)
            } else {
                context.setFillColor(UIColor.red.cgColor)
            }
            
            context.fillEllipse(in: point)
        }
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        
        UIGraphicsEndImageContext()
        
        return newImage
    }
    
    // Function for obtaining depth values from a depth map
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
    
    // MARK: - Crop to Center
    // This function crops the input image to the center, converting a 4:3 aspect ratio to 1:1
    func cropToCenter(image: CIImage) -> UIImage? {
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        let contextSize: CGSize = uiImage.size
        var posX: CGFloat = 0.0
        var posY: CGFloat = 0.0
        var cgwidth: CGFloat = 0.0
        var cgheight: CGFloat = 0.0
        
        // See what size is longer and create the center off of that
        if contextSize.width > contextSize.height {
            posX = ((contextSize.width - contextSize.height) / 2)
            posY = 0
            cgwidth = contextSize.height
            cgheight = contextSize.height
        } else {
            posX = 0
            posY = ((contextSize.height - contextSize.width) / 2)
            cgwidth = contextSize.width
            cgheight = contextSize.width
        }
        
        let rect: CGRect = CGRect(x: posX, y: posY, width: cgwidth, height: cgheight)
        
        // Create bitmap image from context using the rect
        guard let imageRef: CGImage = cgImage.cropping(to: rect) else { return nil }
        
        // Create a new image based on the imageRef and rotate back to the original orientation
        let croppedImage: UIImage = UIImage(cgImage: imageRef, scale: uiImage.scale, orientation: uiImage.imageOrientation)
        
        return croppedImage
    }
}
