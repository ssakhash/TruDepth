import SwiftUI
import UIKit
import ARKit
import RoomPlan
import RealityKit
import AVFoundation

@MainActor
final class ScanStore: ObservableObject {
    static let shared = ScanStore()
    let repository = ScanRepository()
    @Published private(set) var scans: [ScanRecord] = []
    @Published var error: String?
    private var initialized = false

    func load() async {
        guard !initialized else { return }
        initialized = true
        do {
            scans = try await repository.load(); error = await repository.recoveryWarning
            await ScanExportService.shared.cleanExpired()
        }
        catch { self.error = error.localizedDescription; initialized = false }
    }
    func publish(_ record: ScanRecord) {
        scans.removeAll { $0.id == record.id }
        scans.append(record)
        scans.sort { $0.date > $1.date }
    }
    func create(_ method: CaptureMethod) async throws -> ScanRecord {
        let device = UIDevice.current
        let record = try await repository.create(method: method, name: "\(method.title) \(Date().formatted(date: .abbreviated, time: .shortened))",
            device: device.model + " (" + Self.hardwareIdentifier + ")", operatingSystem: device.systemVersion)
        publish(record)
        return record
    }
    func mark(_ id: UUID, state: ScanState, failure: String? = nil, roomCount: Int? = nil) async {
        do { publish(try await repository.update(id, state: state, failure: failure, roomCount: roomCount)) }
        catch { self.error = error.localizedDescription }
    }
    func rename(_ record: ScanRecord, to name: String) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { publish(try await repository.update(record.id, name: name)) }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ record: ScanRecord) async {
        do { try await repository.delete(record.id); scans.removeAll { $0.id == record.id } }
        catch { self.error = error.localizedDescription }
    }
    func removeSources(_ record: ScanRecord) async {
        do { publish(try await repository.removeSources(record.id)) }
        catch { self.error = error.localizedDescription }
    }
    func retry(_ record: ScanRecord, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> ScanRecord {
        do {
            publish(try await repository.update(record.id, state: .processing))
            let result = try await ScanProcessing.shared.rebuild(record, repository: repository, progress: progress)
            publish(result)
            return result
        } catch {
            await mark(record.id, state: .failed, failure: error.localizedDescription)
            throw error
        }
    }
    func saveDepth(_ snapshot: DepthSnapshot) async throws -> ScanRecord {
        let record = try await create(.depth)
        do {
            try await repository.saveSources(record.id, files: snapshot.sourceFiles())
            let ready = try await retry(record)
            return ready
        } catch {
            await mark(record.id, state: .failed, failure: error.localizedDescription)
            throw error
        }
    }
    func url(_ record: ScanRecord, path: String?) -> URL? {
        guard let path else { return nil }
        return try? ScanPaths.resolve(path, in: ScanPaths.root.appendingPathComponent(record.id.uuidString))
    }
    private static var hardwareIdentifier: String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

actor ScanProcessing {
    static let shared = ScanProcessing()
    private var photogrammetry: PhotogrammetrySession?
    private var photoOwner: UUID?

    private func cancel(_ owner: UUID) { if photoOwner == owner { photogrammetry?.cancel() } }

    // A raw-archive failure must not discard an otherwise usable room model.
    // Encoding and reconstruction stay off the main actor.
    func saveRoom(_ data: CapturedRoomData, id: UUID, number: Int,
                  repository: ScanRepository) async throws -> String? {
        try await RoomSourceSaver.save(data, id: id, number: number, repository: repository) { raw in
            try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: raw)
        }
    }

    func rebuild(_ record: ScanRecord, repository: ScanRepository,
                 progress: @escaping @Sendable (Double) async -> Void) async throws -> ScanRecord {
        let folder = await repository.directory(for: record.id)
        let sources = folder.appendingPathComponent("Sources")
        let work = ScanPaths.exports.appendingPathComponent("build-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let model = work.appendingPathComponent("model.usdz")
        let asset: ScanAsset
        try Task.checkCancellation()
        switch record.method {
        case .quickObject:
            asset = try JSONDecoder().decode(ScanAsset.self, from: Data(contentsOf: sources.appendingPathComponent("mesh.json"))).validated()
            try ModelIOCodec.write(asset, to: model)
        case .detailedObject:
            guard PhotogrammetrySession.isSupported else { throw ScanFailure.unsupportedAsset("On-device photo reconstruction is unavailable on this device.") }
            guard photogrammetry == nil else { throw ScanFailure.unsupportedAsset("Another photo reconstruction is already running.") }
            var configuration = PhotogrammetrySession.Configuration()
            configuration.isObjectMaskingEnabled = true
            configuration.checkpointDirectory = sources.appendingPathComponent("Checkpoints")
            let session = try PhotogrammetrySession(input: sources.appendingPathComponent("Images"), configuration: configuration)
            let owner = UUID()
            photogrammetry = session
            photoOwner = owner
            defer { session.cancel(); photogrammetry = nil; photoOwner = nil }
            try await withTaskCancellationHandler {
                try session.process(requests: [.modelFile(url: model, detail: .reduced)])
                outputs: for try await output in session.outputs {
                    try Task.checkCancellation()
                    switch output {
                    case .requestProgress(_, let value): await progress(value)
                    case .requestError(_, let error): throw error
                    case .processingCancelled: throw CancellationError()
                    case .processingComplete: break outputs
                    default: break
                    }
                }
            } onCancel: { Task { await self.cancel(owner) } }
            asset = try ModelIOCodec.load(model)
        case .room:
            let captures = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "json" }
            for capture in captures {
                let name = capture.lastPathComponent.replacingOccurrences(of: "capture-", with: "room-")
                if !FileManager.default.fileExists(atPath: sources.appendingPathComponent(name).path) {
                    let data = try RoomCaptureCoding.decode(CapturedRoomData.self, from: Data(contentsOf: capture))
                    let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                    try Task.checkCancellation()
                    try await repository.saveSources(record.id, files: [name: .data(try RoomCaptureCoding.encode(room))])
                }
            }
            let urls = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("room-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let rooms = try urls.map { try RoomCaptureCoding.decode(CapturedRoom.self, from: Data(contentsOf: $0)) }
            guard !rooms.isEmpty else {
                throw ScanFailure.unsupportedAsset("No room source files were saved for this project. Use Retry Room Save if the capture screen is still open; otherwise, scan the room again.")
            }
            _ = try await repository.update(record.id, roomCount: rooms.count)
            if rooms.count == 1 { try rooms[0].export(to: model, exportOptions: .mesh) }
            else {
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                try Task.checkCancellation()
                try structure.export(to: model, exportOptions: .mesh)
            }
            asset = try ModelIOCodec.load(model)
        case .depth:
            let snapshot = try DepthSnapshot.load(from: sources)
            let png = try snapshot.preview()
            try Task.checkCancellation()
            return try await repository.commit(record.id, files: ["depth.png": .data(png), "depth.ply": .data(try snapshot.ply())],
                model: nil, thumbnail: "depth.png")
        }
        try Task.checkCancellation()
        let thumbnail = try Self.thumbnail(asset)
        return try await repository.commit(record.id, files: ["model.usdz": .file(model), "thumbnail.png": .data(thumbnail)],
            model: "model.usdz", thumbnail: "thumbnail.png", dimensions: asset.dimensions)
    }

    private static func thumbnail(_ asset: ScanAsset) throws -> Data {
        let size = 512
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScanFailure.invalidGeometry }
        context.setFillColor(CGColor(gray: 0.04, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2((p.x-p.z)*0.707, p.y*0.82-(p.x+p.z)*0.4) }
        let points = asset.meshes.flatMap { mesh in mesh.indices.map { project(mesh.point(Int($0))) } }
        guard let first = points.first else { throw ScanFailure.invalidGeometry }
        let low = points.reduce(first, simd_min), high = points.reduce(first, simd_max)
        let scale = 440 / max(high.x-low.x, high.y-low.y, 0.001)
        let center = (high+low)*0.5
        context.setStrokeColor(CGColor(red: 0.25, green: 0.85, blue: 0.8, alpha: 0.8)); context.setLineWidth(0.6)
        let step = max(1, points.count / 60000) * 3
        for i in stride(from: 0, to: points.count-2, by: step) {
            for j in 0..<3 {
                let p = (points[i+j]-center)*scale
                let point = CGPoint(x: CGFloat(p.x)+256, y: CGFloat(p.y)+256)
                if j == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.closePath()
        }
        context.strokePath()
        guard let image = context.makeImage() else { throw ScanFailure.invalidGeometry }
        return try ModelIOCodec.encodePNG(image)
    }
}

enum ScanExportFormat: String, CaseIterable, Identifiable, Sendable {
    case glb, obj, usdz, ply, png, sources
    var id: Self { self }
    var title: String {
        switch self {
        case .obj: "OBJ folder (materials and textures)"
        case .sources: "Source data folder"
        default: rawValue.uppercased()
        }
    }
}

struct ExportTicket: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let url: URL
}

actor ScanExportService {
    static let shared = ScanExportService()
    func cleanExpired() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: ScanPaths.exports, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            if let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-86400) { try? fm.removeItem(at: folder) }
        }
    }
    func prepare(_ record: ScanRecord, format: ScanExportFormat, room: Int? = nil) throws -> ExportTicket {
        try Task.checkCancellation()
        let fm = FileManager.default
        let project = ScanPaths.root.appendingPathComponent(record.id.uuidString)
        let work = ScanPaths.exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let stem = String(record.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(80))
            var source = try record.modelPath.map { try ScanPaths.resolve($0, in: project) }
            if let room {
                let input = project.appendingPathComponent(String(format: "Sources/room-%03d.json", room))
                let data = try RoomCaptureCoding.decode(CapturedRoom.self, from: Data(contentsOf: input))
                let roomURL = work.appendingPathComponent("room.usdz")
                try data.export(to: roomURL, exportOptions: .mesh)
                source = roomURL
            }
            let output: URL
            switch format {
            case .sources:
                output = work.appendingPathComponent(stem + "_sources", isDirectory: true)
                try fm.copyItem(at: project.appendingPathComponent("Sources"), to: output)
                if let warnings = record.sourceWarnings, !warnings.isEmpty {
                    let note = "Raw RoomPlan archive limitations\n\n" + warnings.keys.sorted().map {
                        "\($0): \(warnings[$0] ?? "")"
                    }.joined(separator: "\n") + "\n\nProcessed room JSON is retained for rebuilding and export.\n"
                    try Data(note.utf8).write(to: output.appendingPathComponent("SOURCE_AVAILABILITY.txt"), options: .atomic)
                }
            case .png:
                guard let thumbnail = record.thumbnailPath else { throw ScanFailure.missingSources }
                output = work.appendingPathComponent(stem + ".png")
                try fm.copyItem(at: ScanPaths.resolve(thumbnail, in: project), to: output)
            case .ply:
                guard let path = record.thumbnailPath else { throw ScanFailure.missingSources }
                output = work.appendingPathComponent(stem + ".ply")
                let input = try ScanPaths.resolve(path, in: project).deletingLastPathComponent().appendingPathComponent("depth.ply")
                try fm.copyItem(at: input, to: output)
            case .usdz:
                guard let source else { throw ScanFailure.missingSources }
                output = work.appendingPathComponent(stem + ".usdz")
                try fm.copyItem(at: source, to: output)
            case .glb:
                guard let source else { throw ScanFailure.missingSources }
                output = work.appendingPathComponent(stem + ".glb")
                try GLBWriter.encode(ModelIOCodec.load(source)).write(to: output, options: .atomic)
            case .obj:
                guard let source else { throw ScanFailure.missingSources }
                output = work.appendingPathComponent(stem + "_OBJ", isDirectory: true)
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                try ModelIOCodec.write(ModelIOCodec.load(source), to: output.appendingPathComponent(stem + ".obj"))
                try Data("Geometry units: meters. Keep the OBJ, MTL, and texture files together.\n".utf8).write(to: output.appendingPathComponent("README.txt"))
            }
            try Task.checkCancellation()
            return ExportTicket(directory: work, url: output)
        } catch { try? fm.removeItem(at: work); throw error }
    }
    func remove(_ ticket: ExportTicket) { try? FileManager.default.removeItem(at: ticket.directory) }
}

@MainActor
enum CameraAccess {
    static func require() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
            fallthrough
        default: throw ScanFailure.unsupportedAsset("Allow camera access in Settings to use scanning.")
        }
    }
}
