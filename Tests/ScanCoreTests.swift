import Foundation
import Testing
import simd
import CoreGraphics
import ImageIO
import ModelIO
@testable import TruDepthCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TruDepth-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class WriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var writesRemaining: Int?
    func set(_ flag: Bool) { lock.lock(); enabled = flag; lock.unlock() }
    func failAfter(writes: Int) { lock.lock(); writesRemaining = writes; lock.unlock() }
    func check() throws {
        lock.lock()
        let shouldFail = enabled || writesRemaining == 0
        if let remaining = writesRemaining, remaining > 0 { writesRemaining = remaining - 1 }
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
    }
}

private struct RoomArchiveFixture: Codable, Sendable {
    let readings: [Float]
    let payload: Data
    let name: String
}

private struct UnencodableRoomFixture: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue("fixture", .init(codingPath: encoder.codingPath,
            debugDescription: "Fixture raw archive encoding failed."))
    }
}

@Test func roomArchivesRoundTripExceptionalValuesAndLegacyJSON() throws {
    let original = RoomArchiveFixture(readings: [1.25, .infinity, -.infinity, .nan], payload: Data([0, 255]), name: "NaN")
    #expect(throws: EncodingError.self) { try JSONEncoder().encode(original) }
    let bytes = try RoomCaptureCoding.encode(original)
    _ = try JSONSerialization.jsonObject(with: bytes)
    let decoded = try RoomCaptureCoding.decode(RoomArchiveFixture.self, from: bytes)
    #expect(decoded.readings[0] == 1.25)
    #expect(decoded.readings[1] == .infinity)
    #expect(decoded.readings[2] == -.infinity)
    #expect(decoded.readings[3].isNaN)
    #expect(decoded.payload == original.payload)
    #expect(decoded.name == "NaN")
    let legacy = RoomArchiveFixture(readings: [2.5], payload: Data([9]), name: "Legacy")
    let restored = try RoomCaptureCoding.decode(RoomArchiveFixture.self, from: JSONEncoder().encode(legacy))
    #expect(restored.readings == legacy.readings)
    #expect(restored.payload == legacy.payload)
    var invalidMesh = triangle(); invalidMesh.positions[0] = .infinity
    #expect(throws: (any Error).self) { try invalidMesh.validated() }
}

@Test func rawRoomEncodingFailureStillSavesProcessedRoom() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    let warning = try await RoomSourceSaver.save(UnencodableRoomFixture(), id: draft.id, number: 1, repository: repository) { _ in
        RoomArchiveFixture(readings: [3.5], payload: Data([1]), name: "Built room")
    }
    #expect(warning?.contains("Saving raw room capture") == true)
    #expect(warning?.contains("Fixture raw archive encoding failed") == true)
    let folder = await repository.directory(for: draft.id).appendingPathComponent("Sources")
    let restored = try RoomCaptureCoding.decode(RoomArchiveFixture.self, from: Data(contentsOf: folder.appendingPathComponent("room-001.json")))
    #expect(restored.readings == [3.5])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("capture-001.json").path))
}

@Test func roomBuildFailureRetainsRawInputForRetry() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    let raw = RoomArchiveFixture(readings: [.infinity], payload: Data([5]), name: "Raw")
    do {
        _ = try await RoomSourceSaver.save(raw, id: draft.id, number: 1, repository: repository) { _ -> RoomArchiveFixture in
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        Issue.record("Expected a reconstruction failure")
    } catch {
        #expect(error.localizedDescription.contains("Building the captured room"))
    }
    let folder = await repository.directory(for: draft.id).appendingPathComponent("Sources")
    let bytes = try Data(contentsOf: folder.appendingPathComponent("capture-001.json"))
    #expect(try RoomCaptureCoding.decode(RoomArchiveFixture.self, from: bytes).readings[0] == .infinity)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("room-001.json").path))
    let warning = try await RoomSourceSaver.save(raw, id: draft.id, number: 1, repository: repository) { $0 }
    #expect(warning == nil)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("room-001.json").path))
}

@Test func roomDiskFailureCanRetryWithoutChangingCompletedRooms() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let failure = WriteFailure()
    let repository = ScanRepository(root: root, legacy: nil, beforeWrite: { try failure.check() })
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    let raw = RoomArchiveFixture(readings: [2], payload: Data([3]), name: "Room")
    _ = try await RoomSourceSaver.save(raw, id: draft.id, number: 1, repository: repository) { $0 }
    let folder = await repository.directory(for: draft.id).appendingPathComponent("Sources")
    let first = try Data(contentsOf: folder.appendingPathComponent("room-001.json"))
    failure.set(true)
    do {
        _ = try await RoomSourceSaver.save(raw, id: draft.id, number: 2, repository: repository) { $0 }
        Issue.record("Expected a disk-full failure")
    } catch {
        #expect(error.localizedDescription.contains("Saving the processed room"))
        #expect(error.localizedDescription.contains("Saving raw room capture"))
    }
    #expect(try Data(contentsOf: folder.appendingPathComponent("room-001.json")) == first)
    failure.set(false)
    _ = try await RoomSourceSaver.save(raw, id: draft.id, number: 2, repository: repository) { $0 }
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("room-002.json").path))
}

@Test func roomArchiveCancellationDoesNotRunReconstruction() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    struct CancelledCapture: Encodable, Sendable {
        func encode(to encoder: any Encoder) throws { throw CancellationError() }
    }
    await #expect(throws: CancellationError.self) {
        _ = try await RoomSourceSaver.save(CancelledCapture(), id: draft.id, number: 1, repository: repository) { _ -> RoomArchiveFixture in
            Issue.record("Cancelled source save must not start reconstruction")
            return RoomArchiveFixture(readings: [1], payload: Data(), name: "Unexpected")
        }
    }
    let folder = await repository.directory(for: draft.id).appendingPathComponent("Sources")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
}

@Test func roomFailureDetailsSurviveLeavingAndRelaunch() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    let failure = "Saving raw room capture: fixture error"
    _ = try await repository.update(draft.id, state: .failed, failure: failure)
    _ = try await repository.update(draft.id, state: .interrupted)
    _ = try await repository.update(draft.id, name: "Recoverable room")
    let reloaded = try await ScanRepository(root: root, legacy: nil).load()
    #expect(reloaded.first?.failure == failure)
    let retrying = try await repository.update(draft.id, state: .processing)
    #expect(retrying.failure == nil)
}

@Test func roomSourceLimitationsSurviveFinalizationAndClearOnlyWhenRestored() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Room", device: "Test", operatingSystem: "27")
    _ = try await RoomSourceSaver.save(UnencodableRoomFixture(), id: draft.id, number: 1, repository: repository) { _ in
        RoomArchiveFixture(readings: [3], payload: Data([7]), name: "Room")
    }
    _ = try await repository.update(draft.id, state: .processing)
    let ready = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([1]))], model: "model.usdz", thumbnail: nil)
    #expect(ready.state == .ready)
    #expect(ready.failure == nil)
    #expect(ready.sourceWarnings?["capture-001.json"]?.contains("Fixture raw archive encoding failed") == true)
    _ = try await repository.update(draft.id, name: "Saved room")
    let reloaded = try await ScanRepository(root: root, legacy: nil).load()
    #expect(reloaded.first?.sourceWarnings == ready.sourceWarnings)
    let raw = RoomArchiveFixture(readings: [3], payload: Data([7]), name: "Room")
    _ = try await RoomSourceSaver.save(raw, id: draft.id, number: 1, repository: repository) { $0 }
    #expect(try await repository.read(draft.id).sourceWarnings == nil)
}

@Test func olderProcessedOnlyRoomsAreNotReportedAsDamaged() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .room, name: "Legacy room", device: "Test", operatingSystem: "27")
    try await repository.saveSources(draft.id, files: ["room-001.json": .data(Data("{}".utf8))])
    let ready = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([2]))], model: "model.usdz", thumbnail: nil)
    let folder = await repository.directory(for: draft.id)
    var legacyManifest = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as? [String: Any])
    legacyManifest.removeValue(forKey: "sourceWarnings")
    try JSONSerialization.data(withJSONObject: legacyManifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    let reloaded = try await ScanRepository(root: root, legacy: nil).load()
    let inferred = try #require(reloaded.first)
    #expect(inferred.id == draft.id)
    #expect(inferred.state == .ready)
    #expect(inferred.sourceWarnings?["capture-001.json"] != nil)
    #expect(inferred.modelPath == ready.modelPath)
    let stripped = try await repository.removeSources(draft.id)
    #expect(stripped.sourceWarnings == nil)
    #expect(!stripped.sourceAvailable)
    #expect(stripped.modelPath == ready.modelPath)
}

@Test func committedProjectSurvivesRelaunchAndSourceRemoval() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .quickObject, name: "Fixture", device: "Test", operatingSystem: "17")
    try await repository.saveSources(draft.id, files: ["mesh.json": .data(Data("source".utf8))])
    let saved = try await repository.commit(draft.id, files: ["model.usdz": .data(Data("model".utf8))], model: "model.usdz", thumbnail: nil)
    let reloaded = try await ScanRepository(root: root, legacy: nil).load()
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.state == .ready)
    #expect(reloaded.first?.id == saved.id)
    let stripped = try await repository.removeSources(saved.id)
    #expect(!stripped.sourceAvailable)
    let folder = await repository.directory(for: saved.id)
    #expect(try Data(contentsOf: ScanPaths.resolve(saved.modelPath!, in: folder)) == Data("model".utf8))
    try await repository.delete(saved.id)
    #expect(try await repository.list().isEmpty)
}

@Test func failedCommitAndDeletePreservePreviousModel() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let failure = WriteFailure()
    let repository = ScanRepository(root: root, legacy: nil, beforeWrite: { try failure.check() })
    let draft = try await repository.create(method: .quickObject, name: "Stable", device: "Test", operatingSystem: "27")
    let previous = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([1, 2, 3]))], model: "model.usdz", thumbnail: nil)
    failure.failAfter(writes: 1)
    await #expect(throws: (any Error).self) {
        _ = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([4]))], model: "model.usdz", thumbnail: nil)
    }
    await #expect(throws: (any Error).self) { try await repository.delete(draft.id) }
    let after = try await repository.read(draft.id)
    #expect(after.modelPath == previous.modelPath)
    #expect(after.state == .ready)
}

@Test func corruptLegacyIndexDoesNotHideNewScans() async throws {
    let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let legacy = base.appendingPathComponent("old")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("corrupt".utf8).write(to: legacy.appendingPathComponent("index.json"))
    let repository = ScanRepository(root: base.appendingPathComponent("new"), legacy: legacy)
    let record = try await repository.create(method: .quickObject, name: "New", device: "Test", operatingSystem: "17")
    let loaded = try await repository.load()
    #expect(loaded.contains { $0.id == record.id })
    #expect(await repository.recoveryWarning != nil)
}

@Test func cancellationCannotDowngradeDurableModel() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .quickObject, name: "Saved", device: "Test", operatingSystem: "17")
    _ = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([1]))], model: "model.usdz", thumbnail: nil)
    _ = try await repository.update(draft.id, state: .processing)
    let interrupted = try await repository.update(draft.id, state: .interrupted)
    #expect(interrupted.state == .ready)
}

@Test func interruptedDraftAndMissingAssetRemainDiscoverable() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .detailedObject, name: "Interrupted", device: "Test", operatingSystem: "17")
    try await repository.saveSources(draft.id, files: ["Images/one.jpg": .data(Data([1]))])
    let interrupted = try await ScanRepository(root: root, legacy: nil).load()
    #expect(interrupted.first?.state == .interrupted)
    let saved = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([2]))], model: "model.usdz", thumbnail: nil)
    let folder = await repository.directory(for: saved.id)
    try FileManager.default.removeItem(at: ScanPaths.resolve(saved.modelPath!, in: folder))
    let damaged = try await ScanRepository(root: root, legacy: nil).load()
    #expect(damaged.first?.state == .damaged)
}

@Test func migrationPreservesIdentityAndIsRepeatable() async throws {
    struct Legacy: Encodable { let id: UUID; let date: Date; let filename: String; let depthFilename: String?; let scanType: String? }
    let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("new"), old = base.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let valid = Legacy(id: UUID(), date: Date(timeIntervalSince1970: 100), filename: "old.usdz", depthFilename: "depth.png", scanType: "object")
    let missing = Legacy(id: UUID(), date: Date(timeIntervalSince1970: 200), filename: "missing.usdz", depthFilename: nil, scanType: nil)
    try Data([3, 2, 1]).write(to: old.appendingPathComponent("old.usdz"))
    try Data([4]).write(to: old.appendingPathComponent("depth.png"))
    try JSONEncoder().encode([valid, missing]).write(to: old.appendingPathComponent("index.json"))
    let repository = ScanRepository(root: root, legacy: old)
    let first = try await repository.load()
    #expect(first.count == 2)
    #expect(first.first { $0.id == valid.id }?.date == valid.date)
    #expect(first.first { $0.id == missing.id }?.state == .damaged)
    let second = try await ScanRepository(root: root, legacy: old).load()
    #expect(second.count == 2)
    #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("old.usdz").path))
    #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("depth.png").path))
}

@Test func fileReferencesCannotEscapeProject() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try ScanPaths.resolve("../outside", in: root) }
    #expect(throws: (any Error).self) { try ScanPaths.resolve("/etc/passwd", in: root) }
}

private func triangle() -> MeshSnapshot {
    MeshSnapshot(name: "Triangle", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], texcoords: [0, 0, 1, 0, 0, 1], indices: [0, 1, 2])
}

@Test func cropAndBoundsUseIdenticalReferencedGeometry() throws {
    var transform = matrix_identity_float4x4
    transform.columns.3 = SIMD4(10, 2, -4, 1)
    let volume = ObjectCaptureVolume(transform: transform, extent: SIMD3(2, 2, 2), baseInset: 0)
    let mesh = MeshSnapshot(name: "Inside", positions: [0, 0, 0, 0.5, 0, 0, 0, 0.5, 0, 99, 99, 99], indices: [0, 1, 2])
    let croppedValue = try volume.crop(mesh, anchorTransform: transform)
    let cropped = try #require(croppedValue)
    #expect(cropped.vertexCount == 3)
    let dims = try ScanAsset(meshes: [cropped]).validated().dimensions
    #expect(dims == ScanDimensions(width: 0.5, height: 0.5, depth: 0))
    var invalid = triangle(); invalid.indices = [0, 1, 999]
    #expect(throws: (any Error).self) { try invalid.validated() }
}

@Test func readinessRequiresFourTrackedAzimuths() {
    var coverage = ViewpointCoverage()
    for i in 0..<8 {
        let angle = Float(i) * .pi / 4 + 0.1
        coverage.observe(camera: SIMD3(sin(angle), 0, cos(angle)), center: .zero, trackingNormal: false)
    }
    #expect(!coverage.sufficient)
    for angle: Float in [0.1, 1.0, 2.0, 3.0] {
        coverage.observe(camera: SIMD3(sin(angle), 0, cos(angle)), center: .zero, trackingNormal: true)
    }
    #expect(coverage.sufficient)
}

@Test func glbHasValidLengthsBoundsAndMaterialAssignments() throws {
    var second = triangle(); second.name = "Second"; second.material = 1
    var material = ScanMaterial(name: "Textured", color: [1, 1, 1, 1])
    material.baseColorPNG = try checkerboardPNG()
    let asset = ScanAsset(meshes: [triangle(), second], materials: [ScanMaterial(), material])
    let data = try GLBWriter.encode(asset)
    func word(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    #expect(word(0) == 0x46546c67)
    #expect(Int(word(8)) == data.count)
    let length = Int(word(12))
    #expect(length % 4 == 0)
    let json = try #require(JSONSerialization.jsonObject(with: data[20..<20+length]) as? [String: Any])
    let meshes = try #require(json["meshes"] as? [[String: Any]])
    #expect(meshes.count == 2)
    #expect((json["images"] as? [Any])?.count == 1)
    let fixtures = URL(fileURLWithPath: "/private/tmp/TruDepth-fixtures")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    try data.write(to: fixtures.appendingPathComponent("textured.glb"))
    try ModelIOCodec.write(asset, to: fixtures.appendingPathComponent("model.obj"))
    try ModelIOCodec.write(asset, to: fixtures.appendingPathComponent("model.usdz"))
    let roundtrip = try ModelIOCodec.load(fixtures.appendingPathComponent("model.usdz"))
    #expect(abs(roundtrip.dimensions.width - 1) < 0.001)
    #expect(abs(roundtrip.dimensions.height - 1) < 0.001)
    #expect(roundtrip.materials.contains { $0.baseColorPNG != nil })
    let texture = try #require(roundtrip.materials.compactMap(\.baseColorPNG).first)
    let decodedSource = try #require(CGImageSourceCreateWithData(texture as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
    #expect(decoded.width == 2 && decoded.height == 2)
    #expect(Set(rgbaPixels(decoded).stridePixels).count == 4)
    try GLBWriter.encode(roundtrip).write(to: fixtures.appendingPathComponent("roundtrip.glb"))
}

private func rgbaPixels(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}
private extension Array where Element == UInt8 {
    var stridePixels: [[UInt8]] { stride(from: 0, to: count, by: 4).map { Array(self[$0..<$0+4]) } }
}

private func checkerboardPNG() throws -> Data {
    let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return try ModelIOCodec.encodePNG(image)
}

@Test func depthPointCloudUsesCalibrationConfidenceAndMeters() throws {
    let snapshot = DepthSnapshot(width: 2, height: 2, cameraWidth: 2, cameraHeight: 2, timestamp: 10,
        intrinsics: [1, 0, 0, 0, 1, 0, 0, 0, 1], cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        depth: [Float(1), 1, 1, 1].binaryData, confidence: Data([2, 0, 2, 2]), cameraJPEG: try checkerboardPNG())
    let ply = try snapshot.ply()
    let marker = Data("end_header\n".utf8)
    let start = try #require(ply.range(of: marker)).upperBound
    #expect(ply.count - start == 3 * 15)
    let x = ply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: Float.self) }
    let z = ply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start + 8, as: Float.self) }
    #expect(x == 0)
    #expect(z == -1)
    #expect(Array(ply[start+12..<start+15]) == [255, 0, 0])
    #expect(Array(ply[start+27..<start+30]) == [0, 0, 255])
    let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
    for (name, source) in try snapshot.sourceFiles() { if case .data(let data) = source { try data.write(to: folder.appendingPathComponent(name)) } }
    let loaded = try DepthSnapshot.load(from: folder)
    #expect(loaded.depth == snapshot.depth)
    #expect(loaded.confidence == snapshot.confidence)
    let fixtures = URL(fileURLWithPath: "/private/tmp/TruDepth-fixtures")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    try ply.write(to: fixtures.appendingPathComponent("depth.ply"))
    try snapshot.preview().write(to: fixtures.appendingPathComponent("depth.png"))
}

@Test func interruptedDeletionAndSourceRemovalRestoreUncommittedData() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = ScanRepository(root: root, legacy: nil)
    let draft = try await repository.create(method: .quickObject, name: "Recover", device: "Test", operatingSystem: "17")
    try await repository.saveSources(draft.id, files: ["mesh.json": .data(Data([9]))])
    _ = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([1]))], model: "model.usdz", thumbnail: nil)
    let folder = await repository.directory(for: draft.id)
    try FileManager.default.moveItem(at: folder.appendingPathComponent("Sources"), to: folder.appendingPathComponent(".sources-removed"))
    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent(".deleted-\(draft.id)"))
    let loaded = try await ScanRepository(root: root, legacy: nil).load()
    #expect(loaded.first?.state == .ready)
    #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/mesh.json")) == Data([9]))
}

@Test func sourceRemovalManifestFailureRestoresSources() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let failure = WriteFailure()
    let repository = ScanRepository(root: root, legacy: nil, beforeWrite: { try failure.check() })
    let draft = try await repository.create(method: .quickObject, name: "Keep sources", device: "Test", operatingSystem: "17")
    try await repository.saveSources(draft.id, files: ["mesh.json": .data(Data([7]))])
    _ = try await repository.commit(draft.id, files: ["model.usdz": .data(Data([1]))], model: "model.usdz", thumbnail: nil)
    failure.set(true)
    await #expect(throws: (any Error).self) { _ = try await repository.removeSources(draft.id) }
    let folder = await repository.directory(for: draft.id)
    #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/mesh.json")) == Data([7]))
    #expect(try await repository.read(draft.id).sourceAvailable)
}

@Test func rotatedCropExcludesBoundaryAndSupportingPlane() throws {
    var transform = simd_float4x4(simd_quatf(angle: .pi/3, axis: SIMD3(0, 1, 0)))
    transform.columns.3 = SIMD4(3, 1, -2, 1)
    let volume = ObjectCaptureVolume(transform: transform, extent: SIMD3(1, 1, 1))
    let local = MeshSnapshot(name: "Fixture", positions: [-0.2, 0, 0, 0.2, 0, 0, 0, 0.2, 0,
        -0.3, -0.5, 0, 0.3, -0.5, 0, 0, -0.5, 0.3, 2, 0, 0], indices: [0, 1, 2, 3, 4, 5, 0, 1, 6])
    let result = try volume.crop(local, anchorTransform: transform)
    let crop = try #require(result)
    #expect(crop.indices.count == 3)
    #expect(abs(ScanAsset(meshes: [crop]).dimensions.width - 0.4) < 0.001)
    let edge = MeshSnapshot(name: "Edge", positions: [0.49, 0.4, 0, 0.48, 0.5, 0, 0.4, 0.4, 0], indices: [0, 1, 2])
    #expect(volume.touchesBoundary(ScanAsset(meshes: [edge])))
}

@Test func modelIOReadsPackedVerticesAndBakesTransforms() throws {
    let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
    let allocator = MDLMeshBufferDataAllocator()
    let descriptor = MDLVertexDescriptor()
    descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
    descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
    let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: [UInt32(0), 1, 2].binaryData, type: .index),
        indexCount: 3, indexType: .uInt32, geometryType: .triangles, material: nil)
    let mesh = MDLMesh(vertexBuffer: allocator.newBuffer(with: triangle().positions.binaryData, type: .vertex), vertexCount: 3, descriptor: descriptor, submeshes: [submesh])
    var transform = matrix_identity_float4x4
    transform.columns.0.x = 2; transform.columns.1.y = 3; transform.columns.3 = SIMD4(10, 4, -2, 1)
    mesh.transform = MDLTransform(matrix: transform)
    let asset = MDLAsset(); asset.add(mesh)
    let url = folder.appendingPathComponent("packed.usda")
    try asset.export(to: url)
    let result = try ModelIOCodec.load(url)
    #expect(abs(result.dimensions.width - 2) < 0.001)
    #expect(abs(result.dimensions.height - 3) < 0.001)
    #expect(result.meshes[0].positions[0] == 10)
}

@Test func malformedDepthCannotReadOutOfBounds() throws {
    let invalid = DepthSnapshot(width: 2, height: 2, cameraWidth: 0, cameraHeight: 0, timestamp: 0,
        intrinsics: [], cameraTransform: [], depth: Data(), confidence: Data(), cameraJPEG: Data())
    #expect(throws: (any Error).self) { try invalid.ply() }
    #expect(throws: (any Error).self) { try invalid.preview() }
}

@Test func depthPreviewMatchesClockwisePortraitTransform() throws {
    let snapshot = DepthSnapshot(width: 2, height: 1, cameraWidth: 2, cameraHeight: 1, timestamp: 0,
        intrinsics: [1, 0, 0, 0, 1, 0, 0, 0, 1], cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        depth: [Float(0.1), 4.9].binaryData, confidence: Data([2, 2]), cameraJPEG: Data())
    let data = try snapshot.preview()
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 1 && image.height == 2)
    let pixels = rgbaPixels(image)
    #expect(pixels[2] > pixels[0])
    #expect(pixels[4] > pixels[6])
}

@Test func materialTextureChannelsSurviveUSDZConversion() throws {
    let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
    var material = ScanMaterial(name: "PBR", color: [1, 1, 1, 1], metallic: 1, roughness: 1)
    material.baseColorPNG = try checkerboardPNG()
    material.metallicRoughnessPNG = try checkerboardPNG()
    let asset = ScanAsset(meshes: [triangle()], materials: [material])
    let url = folder.appendingPathComponent("pbr.usdz")
    try ModelIOCodec.write(asset, to: url)
    let restored = try ModelIOCodec.load(url)
    #expect(restored.materials.first?.metallicRoughnessPNG != nil)
}

@Test func vertexSnapshotsHonorPackedStrideAndOffset() throws {
    let packed: [Float] = [99, 1, 2, 3, 4, 5, 6]
    let copy = try packed.binaryData.withUnsafeBytes { try MeshSnapshot.copyPositions(from: $0, count: 2, stride: 12, offset: 4) }
    #expect(copy == [1, 2, 3, 4, 5, 6])
    let padded: [Float] = [1, 2, 3, 99, 4, 5, 6, 99]
    let second = try padded.binaryData.withUnsafeBytes { try MeshSnapshot.copyPositions(from: $0, count: 2, stride: 16, offset: 0) }
    #expect(second == copy)
    #expect(throws: (any Error).self) {
        try packed.binaryData.withUnsafeBytes { try MeshSnapshot.copyPositions(from: $0, count: 999, stride: 12, offset: 4) }
    }
}

@Test func failedMigrationCanRetryWithoutLosingLegacyAssets() async throws {
    struct Legacy: Encodable { let id: UUID; let date: Date; let filename: String }
    let base = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: base) }
    let old = base.appendingPathComponent("old"), root = base.appendingPathComponent("new")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let record = Legacy(id: UUID(), date: Date(timeIntervalSince1970: 123), filename: "room.usdz")
    try JSONEncoder().encode([record]).write(to: old.appendingPathComponent("index.json"))
    try Data([1, 2, 3]).write(to: old.appendingPathComponent(record.filename))
    let failure = WriteFailure(); failure.set(true)
    let repository = ScanRepository(root: root, legacy: old, beforeWrite: { try failure.check() })
    _ = try await repository.load()
    #expect(await repository.recoveryWarning != nil)
    #expect(try Data(contentsOf: old.appendingPathComponent(record.filename)) == Data([1, 2, 3]))
    failure.set(false)
    let migrated = try await repository.load()
    #expect(migrated.count == 1)
    #expect(migrated[0].id == record.id && migrated[0].date == record.date)
    #expect(migrated[0].state == .ready)
}
