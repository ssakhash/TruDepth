import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import ImageIO
import UniformTypeIdentifiers
import simd

enum ModelIOCodec {
    static func load(_ url: URL) throws -> ScanAsset {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else {
            throw ScanFailure.unsupportedAsset("This model format cannot be read on this device.")
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        var meshes: [MeshSnapshot] = [], materials: [ScanMaterial] = []
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            guard let vertices = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
            let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let rotation = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            let normalTransform = simd_transpose(simd_inverse(rotation))
            var positions: [Float] = [], normalValues: [Float] = [], texcoords: [Float] = []
            for i in 0..<mesh.vertexCount {
                let p = read3(vertices.dataStart + i * vertices.stride)
                let q = transform * SIMD4(p.x, p.y, p.z, 1)
                positions += [q.x, q.y, q.z]
                if let normals {
                    let n = normalTransform * read3(normals.dataStart + i * normals.stride)
                    let safe = simd_length_squared(n) > 1e-14 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
                    normalValues += [safe.x, safe.y, safe.z]
                }
                if let uv {
                    let ptr = uv.dataStart + i * uv.stride
                    texcoords += [ptr.loadUnaligned(as: Float.self), 1 - ptr.loadUnaligned(fromByteOffset: 4, as: Float.self)]
                }
            }
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                guard submesh.geometryType == .triangles else {
                    throw ScanFailure.unsupportedAsset("The model contains unsupported non-triangle geometry.")
                }
                let indexBytes = submesh.indexBuffer.map().bytes
                let stride: Int
                switch submesh.indexType {
                case .uInt8: stride = 1
                case .uInt16: stride = 2
                case .uInt32: stride = 4
                default: throw ScanFailure.invalidGeometry
                }
                guard submesh.indexCount * stride <= submesh.indexBuffer.length else { throw ScanFailure.invalidGeometry }
                var indices = (0..<submesh.indexCount).map { i -> UInt32 in
                    switch stride {
                    case 1: UInt32(indexBytes.loadUnaligned(fromByteOffset: i, as: UInt8.self))
                    case 2: UInt32(indexBytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    default: indexBytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    }
                }
                guard indices.count % 3 == 0 else { throw ScanFailure.invalidGeometry }
                if simd_determinant(rotation) < 0 {
                    for i in Swift.stride(from: 0, to: indices.count, by: 3) { indices.swapAt(i + 1, i + 2) }
                }
                let material = try readMaterial(submesh.material)
                meshes.append(MeshSnapshot(name: mesh.name, positions: positions, normals: normalValues,
                    texcoords: texcoords, indices: indices, material: materials.count))
                materials.append(material)
            }
        }
        return try ScanAsset(meshes: meshes, materials: materials).validated()
    }

    static func write(_ input: ScanAsset, to url: URL) throws {
        let input = try input.validated()
        guard url.pathExtension == "usdz" || MDLAsset.canExportFileExtension(url.pathExtension) else {
            throw ScanFailure.unsupportedAsset("\(url.pathExtension.uppercased()) export is unavailable on this device.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let asset = MDLAsset()
        let allocator = MDLMeshBufferDataAllocator()
        for source in input.meshes {
            var interleaved: [Float] = []
            for i in 0..<source.vertexCount {
                interleaved += Array(source.positions[i*3..<i*3+3])
                interleaved += Array(source.normals[i*3..<i*3+3])
                interleaved += source.texcoords.isEmpty ? [0, 0] : [source.texcoords[i*2], 1 - source.texcoords[i*2+1]]
            }
            let descriptor = MDLVertexDescriptor()
            descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
            descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
            descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
            descriptor.layouts[0] = MDLVertexBufferLayout(stride: 32)
            let material = input.materials[source.material]
            let mdlMaterial = MDLMaterial(name: material.name, scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
            mdlMaterial.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float4: SIMD4(material.color[0], material.color[1], material.color[2], material.color[3])))
            mdlMaterial.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: material.roughness))
            mdlMaterial.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, float: material.metallic))
            if let png = material.baseColorPNG {
                let tinted = try transformTexture(png) { pixel in
                    (0..<4).map { UInt8(Float(pixel[$0]) * material.color[$0]) }
                }
                try setTexture(tinted, name: "baseColor-\(source.material)", semantic: .baseColor, material: mdlMaterial, directory: url.deletingLastPathComponent())
            }
            if let png = material.normalPNG {
                try setTexture(png, name: "normal-\(source.material)", semantic: .tangentSpaceNormal, material: mdlMaterial, directory: url.deletingLastPathComponent())
            }
            if let png = material.metallicRoughnessPNG {
                for (channel, factor, semantic, label) in [(1, material.roughness, MDLMaterialSemantic.roughness, "roughness"), (2, material.metallic, MDLMaterialSemantic.metallic, "metallic")] {
                    let gray = try transformTexture(png) { pixel in
                        let value = UInt8(Float(pixel[channel]) * factor)
                        return [value, value, value, 255]
                    }
                    try setTexture(gray, name: "\(label)-\(source.material)", semantic: semantic, material: mdlMaterial, directory: url.deletingLastPathComponent())
                }
            }
            let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: source.indices.binaryData, type: .index),
                indexCount: source.indices.count, indexType: .uInt32, geometryType: .triangles, material: mdlMaterial)
            let mesh = MDLMesh(vertexBuffer: allocator.newBuffer(with: interleaved.binaryData, type: .vertex), vertexCount: source.vertexCount,
                descriptor: descriptor, submeshes: [submesh])
            mesh.name = source.name
            asset.add(mesh)
        }
        if url.pathExtension == "usdz" {
            // Model I/O does not provide a USDZ writer. SceneKit's native packager
            // accepts the MDL asset; rendering and interaction use RealityKit.
            asset.loadTextures()
            guard SCNScene(mdlAsset: asset).write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
                throw ScanFailure.unsupportedAsset("The model could not be packaged as USDZ.")
            }
        } else {
            try asset.export(to: url)
        }
    }

    private static func read3(_ ptr: UnsafeMutableRawPointer) -> SIMD3<Float> {
        SIMD3(ptr.loadUnaligned(as: Float.self), ptr.loadUnaligned(fromByteOffset: 4, as: Float.self), ptr.loadUnaligned(fromByteOffset: 8, as: Float.self))
    }
    private static func transformTexture(_ data: Data, pixel: ([UInt8]) -> [UInt8]) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScanFailure.invalidGeometry }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.replaceSubrange(i..<i+4, with: pixel(Array(bytes[i..<i+4]))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let output = CGImage(width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScanFailure.invalidGeometry }
        return try encodePNG(output)
    }
    private static func setTexture(_ data: Data, name: String, semantic: MDLMaterialSemantic, material: MDLMaterial, directory: URL) throws {
        let url = directory.appendingPathComponent(name + ".png")
        try data.write(to: url, options: .atomic)
        let sampler = MDLTextureSampler()
        sampler.texture = MDLURLTexture(url: url, name: name)
        material.setProperty(MDLMaterialProperty(name: name, semantic: semantic, textureSampler: sampler))
    }
    private static func readMaterial(_ input: MDLMaterial?) throws -> ScanMaterial {
        guard let input else { return ScanMaterial() }
        var material = ScanMaterial(name: input.name)
        if let color = input.property(with: .baseColor) {
            switch color.type {
            case .float3: let c = color.float3Value; material.color = [c.x, c.y, c.z, 1]
            case .float4: let c = color.float4Value; material.color = [c.x, c.y, c.z, c.w]
            case .color:
                if let converted = color.color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil), let c = converted.components, c.count == 4 {
                    material.color = c.map(Float.init)
                }
            default: material.color = [1, 1, 1, 1]
            }
            material.baseColorPNG = try png(color)
        }
        if let value = input.property(with: .metallic), value.type == .float { material.metallic = value.floatValue }
        if let value = input.property(with: .roughness), value.type == .float { material.roughness = value.floatValue }
        if let value = input.property(with: .opacity), value.type == .float { material.color[3] *= value.floatValue }
        material.normalPNG = try input.property(with: .tangentSpaceNormal).flatMap(png)
        if input.property(with: .metallic)?.type == .texture { material.metallic = 1 }
        if input.property(with: .roughness)?.type == .texture { material.roughness = 1 }
        material.metallicRoughnessPNG = try packMetallicRoughness(input)
        return material
    }
    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ScanFailure.invalidGeometry }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ScanFailure.invalidGeometry }
        return data as Data
    }
    private static func png(_ property: MDLMaterialProperty) throws -> Data? {
        guard let texture = property.textureSamplerValue?.texture, let image = texture.imageFromTexture()?.takeUnretainedValue() else { return nil }
        return try encodePNG(image)
    }
    private static func packMetallicRoughness(_ material: MDLMaterial) throws -> Data? {
        let metal = material.property(with: .metallic)?.textureSamplerValue?.texture?.imageFromTexture()?.takeUnretainedValue()
        let rough = material.property(with: .roughness)?.textureSamplerValue?.texture?.imageFromTexture()?.takeUnretainedValue()
        guard let reference = metal ?? rough else { return nil }
        let w = reference.width, h = reference.height
        func pixels(_ image: CGImage?) -> [UInt8]? {
            guard let image else { return nil }
            var bytes = [UInt8](repeating: 0, count: w*h*4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return bytes
        }
        let m = pixels(metal), r = pixels(rough)
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        for i in 0..<w*h { bytes[i*4+1] = r?[i*4] ?? 255; bytes[i*4+2] = m?[i*4] ?? 255 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        guard let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ScanFailure.invalidGeometry }
        return try encodePNG(image)
    }
}
