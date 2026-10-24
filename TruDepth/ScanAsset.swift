import Foundation
import simd

struct ScanMaterial: Codable, Sendable {
    var name = "Surface"
    var color: [Float] = [0.7, 0.75, 0.8, 1]
    var metallic: Float = 0
    var roughness: Float = 0.8
    var baseColorPNG: Data?
    var normalPNG: Data?
    var metallicRoughnessPNG: Data?
}

struct MeshSnapshot: Codable, Sendable {
    var name: String
    var positions: [Float]
    var normals: [Float] = []
    var texcoords: [Float] = []
    var indices: [UInt32]
    var material: Int = 0

    var vertexCount: Int { positions.count / 3 }
    static func copyPositions(from bytes: UnsafeRawBufferPointer, count: Int, stride: Int, offset: Int) throws -> [Float] {
        guard count > 0, stride >= 12, offset >= 0, offset <= bytes.count,
              bytes.count - offset >= 12, count <= (bytes.count - offset - 12) / stride + 1 else { throw ScanFailure.invalidGeometry }
        var positions: [Float] = []
        positions.reserveCapacity(count * 3)
        for i in 0..<count {
            let start = offset + i * stride
            positions.append(bytes.loadUnaligned(fromByteOffset: start, as: Float.self))
            positions.append(bytes.loadUnaligned(fromByteOffset: start + 4, as: Float.self))
            positions.append(bytes.loadUnaligned(fromByteOffset: start + 8, as: Float.self))
        }
        guard positions.allSatisfy(\.isFinite) else { throw ScanFailure.invalidGeometry }
        return positions
    }
    func validated() throws -> MeshSnapshot {
        guard positions.count >= 9, positions.count % 3 == 0,
              positions.allSatisfy(\.isFinite), !indices.isEmpty, indices.count % 3 == 0,
              indices.allSatisfy({ Int($0) < vertexCount }),
              (normals.isEmpty || normals.count == positions.count), normals.allSatisfy(\.isFinite),
              (texcoords.isEmpty || texcoords.count == vertexCount * 2), texcoords.allSatisfy(\.isFinite)
        else { throw ScanFailure.invalidGeometry }
        var mesh = self
        mesh.indices = stride(from: 0, to: indices.count, by: 3).flatMap { i -> [UInt32] in
            let a = point(Int(indices[i])), b = point(Int(indices[i+1])), c = point(Int(indices[i+2]))
            return simd_length_squared(simd_cross(b-a, c-a)) > 1e-14 ? Array(indices[i...i+2]) : []
        }
        guard !mesh.indices.isEmpty else { throw ScanFailure.invalidGeometry }
        if mesh.normals.isEmpty { mesh.generateNormals() }
        else {
            for i in 0..<mesh.vertexCount {
                let n = SIMD3(mesh.normals[i*3], mesh.normals[i*3+1], mesh.normals[i*3+2])
                let normalized = simd_length_squared(n) > 1e-14 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
                mesh.normals.replaceSubrange(i*3..<i*3+3, with: [normalized.x, normalized.y, normalized.z])
            }
        }
        return mesh
    }
    func point(_ i: Int) -> SIMD3<Float> { SIMD3(positions[i*3], positions[i*3+1], positions[i*3+2]) }
    mutating func generateNormals() {
        var sums = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i+1]), c = Int(indices[i+2])
            let n = simd_cross(point(b)-point(a), point(c)-point(a))
            sums[a] += n; sums[b] += n; sums[c] += n
        }
        normals = sums.flatMap { n in
            let normal = simd_length_squared(n) > 1e-14 ? simd_normalize(n) : SIMD3<Float>(0, 1, 0)
            return [normal.x, normal.y, normal.z]
        }
    }
}

struct ScanAsset: Codable, Sendable {
    var meshes: [MeshSnapshot]
    var materials: [ScanMaterial] = [ScanMaterial()]
    func validated() throws -> ScanAsset {
        guard !meshes.isEmpty, !materials.isEmpty else { throw ScanFailure.invalidGeometry }
        for material in materials {
            guard material.color.count == 4, material.color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  material.roughness.isFinite, (0...1).contains(material.roughness),
                  material.metallic.isFinite, (0...1).contains(material.metallic) else { throw ScanFailure.invalidGeometry }
        }
        return try ScanAsset(meshes: meshes.map {
            guard materials.indices.contains($0.material) else { throw ScanFailure.invalidGeometry }
            let material = materials[$0.material]
            if material.baseColorPNG != nil || material.normalPNG != nil || material.metallicRoughnessPNG != nil {
                guard !$0.texcoords.isEmpty else { throw ScanFailure.unsupportedAsset("A textured mesh is missing UV coordinates.") }
            }
            return try $0.validated()
        }, materials: materials)
    }
    var dimensions: ScanDimensions {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for mesh in meshes {
            for index in Set(mesh.indices) {
                lo = simd_min(lo, mesh.point(Int(index)))
                hi = simd_max(hi, mesh.point(Int(index)))
            }
        }
        let size = simd_max(hi - lo, .zero)
        return ScanDimensions(width: size.x, height: size.y, depth: size.z)
    }
}

struct ObjectCaptureVolume: Sendable {
    var transform: simd_float4x4
    var extent = SIMD3<Float>(0.24, 0.20, 0.24)
    var baseInset: Float = 0.005
    var inverseTransform: simd_float4x4 { simd_inverse(transform) }
    func contains(_ local: SIMD3<Float>) -> Bool {
        let half = extent * 0.5
        return abs(local.x) <= half.x && abs(local.z) <= half.z && local.y >= -half.y + baseInset && local.y <= half.y
    }
    func touchesBoundary(_ asset: ScanAsset) -> Bool {
        let margin = min(extent.x, extent.y, extent.z) * 0.02
        return asset.meshes.contains { mesh in
            mesh.indices.contains { index in
                let p = mesh.point(Int(index))
                return abs(p.x) >= extent.x * 0.5 - margin || abs(p.z) >= extent.z * 0.5 - margin ||
                    p.y >= extent.y - margin || p.y <= baseInset + margin
            }
        }
    }
    func crop(_ mesh: MeshSnapshot, anchorTransform: simd_float4x4) throws -> MeshSnapshot? {
        guard mesh.positions.count % 3 == 0, mesh.positions.allSatisfy(\.isFinite),
              extent.x > 0, extent.y > 0, extent.z > 0 else { throw ScanFailure.invalidGeometry }
        let matrix = inverseTransform * anchorTransform
        let points = (0..<mesh.vertexCount).map { index -> SIMD3<Float> in
            let p = mesh.point(index)
            let q = matrix * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD3(q.x, q.y, q.z)
        }
        guard mesh.indices.count % 3 == 0, mesh.indices.allSatisfy({ Int($0) < points.count }) else { throw ScanFailure.invalidGeometry }
        var indices: [UInt32] = [], positions: [Float] = []
        var remap: [UInt32: UInt32] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let face = Array(mesh.indices[i...i+2])
            guard face.allSatisfy({ contains(points[Int($0)]) }) else { continue }
            for old in face {
                if remap[old] == nil {
                    remap[old] = UInt32(positions.count / 3)
                    let p = points[Int(old)]
                    positions += [p.x, p.y + extent.y * 0.5, p.z]
                }
                indices.append(remap[old]!)
            }
        }
        guard !indices.isEmpty else { return nil }
        return try MeshSnapshot(name: mesh.name, positions: positions, indices: indices).validated()
    }
}

struct ViewpointCoverage: Sendable {
    private(set) var sectors: Set<Int> = []
    mutating func observe(camera: SIMD3<Float>, center: SIMD3<Float>, trackingNormal: Bool) {
        guard trackingNormal, simd_length(camera - center) > 0.1 else { return }
        let angle = atan2(camera.x - center.x, camera.z - center.z) + .pi
        sectors.insert(min(7, Int(angle / (.pi / 4))))
    }
    var sufficient: Bool { sectors.count >= 4 }
}

enum GLBWriter {
    static func encode(_ input: ScanAsset) throws -> Data {
        let asset = try input.validated()
        var binary = Data()
        var views: [[String: Any]] = [], accessors: [[String: Any]] = []
        var images: [[String: Any]] = [], textures: [[String: Any]] = []
        func append(_ data: Data, target: Int? = nil) -> Int {
            while binary.count % 4 != 0 { binary.append(0) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": binary.count, "byteLength": data.count]
            if let target { view["target"] = target }
            binary.append(data)
            views.append(view)
            return views.count - 1
        }
        func floats(_ values: [Float], type: String, components: Int, bounds: Bool = false) -> Int {
            let view = append(values.binaryData, target: 34962)
            var accessor: [String: Any] = ["bufferView": view, "componentType": 5126, "count": values.count / components, "type": type]
            if bounds {
                accessor["min"] = (0..<components).map { offset in stride(from: offset, to: values.count, by: components).map { values[$0] }.min()! }
                accessor["max"] = (0..<components).map { offset in stride(from: offset, to: values.count, by: components).map { values[$0] }.max()! }
            }
            accessors.append(accessor)
            return accessors.count - 1
        }
        func texture(_ data: Data) -> [String: Int] {
            images.append(["bufferView": append(data), "mimeType": "image/png"])
            textures.append(["source": images.count - 1])
            return ["index": textures.count - 1]
        }
        let materials: [[String: Any]] = asset.materials.map { material in
            var pbr: [String: Any] = ["baseColorFactor": material.color, "metallicFactor": material.metallic, "roughnessFactor": material.roughness]
            if let data = material.baseColorPNG { pbr["baseColorTexture"] = texture(data) }
            if let data = material.metallicRoughnessPNG { pbr["metallicRoughnessTexture"] = texture(data) }
            var result: [String: Any] = ["name": material.name, "pbrMetallicRoughness": pbr, "doubleSided": true]
            if let data = material.normalPNG { result["normalTexture"] = texture(data) }
            if material.color[3] < 1 { result["alphaMode"] = "BLEND" }
            return result
        }
        var meshes: [[String: Any]] = []
        for mesh in asset.meshes {
            var attrs = ["POSITION": floats(mesh.positions, type: "VEC3", components: 3, bounds: true),
                         "NORMAL": floats(mesh.normals, type: "VEC3", components: 3)]
            if !mesh.texcoords.isEmpty { attrs["TEXCOORD_0"] = floats(mesh.texcoords, type: "VEC2", components: 2) }
            let view = append(mesh.indices.binaryData, target: 34963)
            accessors.append(["bufferView": view, "componentType": 5125, "count": mesh.indices.count, "type": "SCALAR"])
            meshes.append(["name": mesh.name, "primitives": [["attributes": attrs, "indices": accessors.count - 1, "material": mesh.material, "mode": 4]]])
        }
        var json: [String: Any] = ["asset": ["version": "2.0", "generator": "TruDepth"], "scene": 0,
            "scenes": [["nodes": Array(meshes.indices)]], "nodes": meshes.indices.map { ["mesh": $0] },
            "meshes": meshes, "materials": materials, "accessors": accessors, "bufferViews": views,
            "buffers": [["byteLength": binary.count]]]
        if !images.isEmpty { json["images"] = images; json["textures"] = textures }
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while binary.count % 4 != 0 { binary.append(0) }
        let length = 12 + 8 + jsonData.count + 8 + binary.count
        guard length <= Int(UInt32.max) else { throw ScanFailure.unsupportedAsset("This model exceeds the GLB size limit.") }
        var result = [UInt32(0x46546c67), 2, UInt32(length), UInt32(jsonData.count), 0x4e4f534a].binaryData
        result.append(jsonData)
        result.append([UInt32(binary.count), 0x004e4942].binaryData)
        result.append(binary)
        return result
    }
}

extension Array where Element == Float {
    var binaryData: Data { map(\.bitPattern).binaryData }
}
extension Array where Element == UInt32 {
    var binaryData: Data {
        let littleEndian = map(\.littleEndian)
        return littleEndian.withUnsafeBytes { Data($0) }
    }
}
