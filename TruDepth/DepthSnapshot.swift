import Foundation
import CoreImage
import simd
#if os(iOS)
import ARKit
#endif

struct DepthSnapshot: Codable, Sendable {
    var width: Int
    var height: Int
    var cameraWidth: Int
    var cameraHeight: Int
    var timestamp: TimeInterval
    var intrinsics: [Float]
    var cameraTransform: [Float]
    var depth: Data
    var confidence: Data
    var cameraJPEG: Data

    #if os(iOS)
    static func capture(_ frame: ARFrame) throws -> DepthSnapshot {
        guard let data = frame.sceneDepth ?? frame.smoothedSceneDepth else {
            throw ScanFailure.unsupportedAsset("Depth is not ready. Keep the camera steady and try again.")
        }
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { throw ScanFailure.invalidGeometry }
        var depth = Data()
        for row in 0..<h { depth.append(Data(bytes: base + row * CVPixelBufferGetBytesPerRow(map), count: w * 4)) }
        var confidence = Data(repeating: 0, count: w*h)
        if let buffer = data.confidenceMap {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let pointer = CVPixelBufferGetBaseAddress(buffer) {
                confidence = Data()
                for row in 0..<h { confidence.append(Data(bytes: pointer + row * CVPixelBufferGetBytesPerRow(buffer), count: w)) }
            }
        }
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else { throw ScanFailure.invalidGeometry }
        let k = frame.camera.intrinsics
        let t = frame.camera.transform
        return DepthSnapshot(width: w, height: h, cameraWidth: CVPixelBufferGetWidth(frame.capturedImage),
            cameraHeight: CVPixelBufferGetHeight(frame.capturedImage), timestamp: frame.timestamp,
            intrinsics: [k[0][0], k[0][1], k[0][2], k[1][0], k[1][1], k[1][2], k[2][0], k[2][1], k[2][2]],
            cameraTransform: (0..<4).flatMap { c in (0..<4).map { t[c][$0] } }, depth: depth, confidence: confidence, cameraJPEG: jpeg)
    }

    #endif
    func sourceFiles() throws -> [String: ScanFile] {
        var metadata = self
        metadata.depth = Data(); metadata.confidence = Data(); metadata.cameraJPEG = Data()
        return ["depth.json": .data(try JSONEncoder().encode(metadata)), "depth.f32": .data(depth),
                "confidence.u8": .data(confidence), "camera.jpg": .data(cameraJPEG),
                "README.txt": .data(Data("Depth: row-major Float32 little-endian meters. Confidence: UInt8 ARConfidenceLevel (0 low, 1 medium, 2 high). Intrinsics and pose: column-major matrices. Camera image and depth are in sensor orientation. PLY uses ARKit world coordinates: meters, Y up, camera looks down -Z. Timestamp is ARFrame monotonic seconds; the scan manifest records capture date.\n".utf8))]
    }
    static func load(from folder: URL) throws -> DepthSnapshot {
        var result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("depth.json")))
        result.depth = try Data(contentsOf: folder.appendingPathComponent("depth.f32"))
        result.confidence = try Data(contentsOf: folder.appendingPathComponent("confidence.u8"))
        result.cameraJPEG = try Data(contentsOf: folder.appendingPathComponent("camera.jpg"))
        try result.validate()
        return result
    }
    private func validate() throws {
        guard width > 0, height > 0, width < 16384, height < 16384, cameraWidth > 0, cameraHeight > 0,
              depth.count == width * height * 4, confidence.count == width * height,
              intrinsics.count == 9, cameraTransform.count == 16,
              intrinsics.allSatisfy(\.isFinite), cameraTransform.allSatisfy(\.isFinite),
              intrinsics[0] > 0, intrinsics[4] > 0 else { throw ScanFailure.invalidGeometry }
    }
    func value(_ index: Int) -> Float { depth.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index*4, as: UInt32.self))) } }
    func preview() throws -> Data {
        try validate()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width*height {
            let d = value(i)
            guard d.isFinite, d > 0, d <= 7.5, confidence[i] >= 1 else { continue }
            let t = min(d/5, 1)
            pixels[i*4] = UInt8(max(0, min(1, 1.5-abs(4*t-3))) * 255)
            pixels[i*4+1] = UInt8(max(0, min(1, 1.5-abs(4*t-2))) * 255)
            pixels[i*4+2] = UInt8(max(0, min(1, 1.5-abs(4*t-1))) * 255)
            pixels[i*4+3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScanFailure.invalidGeometry }
        // Match the portrait heatmap's existing 90-degree transform plus 180-degree correction.
        let oriented = CIImage(cgImage: image).oriented(.right)
        guard let output = CIContext().createCGImage(oriented, from: oriented.extent) else { throw ScanFailure.invalidGeometry }
        return try ModelIOCodec.encodePNG(output)
    }
    func ply() throws -> Data {
        try validate()
        guard let source = CGImageSourceCreateWithData(cameraJPEG as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScanFailure.invalidGeometry }
        var rgba = [UInt8](repeating: 0, count: width*height*4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let sx = Float(width)/Float(cameraWidth), sy = Float(height)/Float(cameraHeight)
        let fx = intrinsics[0]*sx, fy = intrinsics[4]*sy, cx = intrinsics[6]*sx, cy = intrinsics[7]*sy
        guard fx > 0, fy > 0 else { throw ScanFailure.invalidGeometry }
        let t = simd_float4x4(columns: (SIMD4(cameraTransform[0], cameraTransform[1], cameraTransform[2], cameraTransform[3]),
            SIMD4(cameraTransform[4], cameraTransform[5], cameraTransform[6], cameraTransform[7]),
            SIMD4(cameraTransform[8], cameraTransform[9], cameraTransform[10], cameraTransform[11]),
            SIMD4(cameraTransform[12], cameraTransform[13], cameraTransform[14], cameraTransform[15])))
        var points = Data(), count = 0
        for y in 0..<height { for x in 0..<width {
            let i = y*width+x, z = value(i)
            guard z.isFinite, z > 0, z <= 7.5, confidence[i] >= 1 else { continue }
            let p = t * SIMD4((Float(x)-cx)*z/fx, -(Float(y)-cy)*z/fy, -z, 1)
            points.append([p.x, p.y, p.z].binaryData)
            points.append(contentsOf: rgba[i*4..<i*4+3]); count += 1
        } }
        guard count > 0 else { throw ScanFailure.invalidGeometry }
        let header = "ply\nformat binary_little_endian 1.0\ncomment TruDepth meters, Y up\nelement vertex \(count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        return Data(header.utf8) + points
    }
}
