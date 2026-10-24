import Foundation

enum CaptureMethod: String, Codable, CaseIterable, Sendable {
    case room, quickObject, detailedObject, depth
    var title: String {
        switch self {
        case .room: "Room layout"
        case .quickObject: "LiDAR item"
        case .detailedObject: "Photo item"
        case .depth: "Depth snapshot"
        }
    }
    var symbol: String {
        switch self {
        case .room: "square.split.bottomrightquarter"
        case .quickObject: "cube.transparent"
        case .detailedObject: "camera.aperture"
        case .depth: "viewfinder"
        }
    }
}

enum ScanState: String, Codable, Sendable {
    case capturing, processing, ready, failed, interrupted, damaged
}

struct ScanDimensions: Codable, Equatable, Sendable {
    var width: Float
    var height: Float
    var depth: Float
    func formatted(inches: Bool) -> String {
        let scale: Float = inches ? 39.37007874 : 100
        return String(format: "%.1f × %.1f × %.1f %@", width * scale, height * scale, depth * scale, inches ? "in" : "cm")
    }
}

struct ScanRecord: Identifiable, Codable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var date: Date
    var name: String
    var method: CaptureMethod
    var state: ScanState
    var device: String
    var operatingSystem: String
    var modelPath: String?
    var thumbnailPath: String?
    var dimensions: ScanDimensions?
    var sourceAvailable = true
    var roomCount = 0
    var failure: String?
    var byteCount: Int64 = 0
    var sourceWarnings: [String: String]?

    var formattedDate: String { date.formatted(date: .abbreviated, time: .shortened) }
    var fileSize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}

enum ScanFailure: LocalizedError {
    case invalidPath, missingProject, invalidGeometry, missingSources, unsupportedAsset(String)
    var errorDescription: String? {
        switch self {
        case .invalidPath: "The scan contains an invalid file reference."
        case .missingProject: "The scan could not be found."
        case .invalidGeometry: "No valid geometry was captured. Scan more of the object and try again."
        case .missingSources: "The source data needed to rebuild this scan is unavailable."
        case .unsupportedAsset(let message): message
        }
    }
}

// RoomPlan's opaque source data may contain IEEE 754 sentinel values. Keep them
// losslessly in its archive; mesh/export validation remains strictly finite.
enum RoomCaptureCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(type, from: data)
    }
}

struct ScanOperationFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(_ operation: String, error: Error) {
        let detail: String
        if case EncodingError.invalidValue(_, let context) = error {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            detail = context.debugDescription + (path.isEmpty ? "" : " (field: \(path))")
        } else {
            let underlying = error as NSError
            detail = "\(error.localizedDescription) [\(underlying.domain):\(underlying.code)]"
        }
        message = "\(operation): \(detail)"
    }
}

enum RoomSourceSaver {
    static func save<Raw: Encodable & Sendable, Room: Encodable & Sendable>(
        _ data: Raw, id: UUID, number: Int, repository: ScanRepository,
        build: @Sendable (Raw) async throws -> Room
    ) async throws -> String? {
        var rawFailure: String?
        do {
            let encoded = try RoomCaptureCoding.encode(data)
            try await repository.saveSources(id, files: [String(format: "capture-%03d.json", number): .data(encoded)])
        } catch is CancellationError { throw CancellationError() }
        catch { rawFailure = ScanOperationFailure("Saving raw room capture", error: error).message }

        var operation = "Building the captured room"
        do {
            try Task.checkCancellation()
            let room = try await build(data)
            try Task.checkCancellation()
            operation = "Encoding the processed room"
            let encoded = try RoomCaptureCoding.encode(room)
            operation = "Saving the processed room"
            try await repository.saveSources(id, files: [String(format: "room-%03d.json", number): .data(encoded)])
            operation = "Recording room source availability"
            return try await repository.recordRoomSourceWarning(id, number: number, warning: rawFailure)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = ScanOperationFailure(operation, error: error)
            if let rawFailure {
                throw ScanFailure.unsupportedAsset("\(failure.message)\n\(rawFailure)")
            }
            throw failure
        }
    }
}

enum ScanFile: Sendable {
    case data(Data)
    case file(URL)
}

enum ScanPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TruDepth/Scans", isDirectory: true)
    }
    static var legacy: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TruDepthScans", isDirectory: true)
    }
    static var exports: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TruDepth/Exports", isDirectory: true)
    }
    static func resolve(_ relative: String, in directory: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { throw ScanFailure.invalidPath }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let result = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(base.path + "/") else { throw ScanFailure.invalidPath }
        return result
    }
}

actor ScanRepository {
    let root: URL
    private let legacy: URL?
    private let fm = FileManager.default
    private(set) var recoveryWarning: String?
    // Injectable before durable writes so failure paths can be tested without filling a device.
    private let beforeWrite: @Sendable () throws -> Void

    init(root: URL = ScanPaths.root, legacy: URL? = ScanPaths.legacy,
         beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        self.root = root
        self.legacy = legacy
        self.beforeWrite = beforeWrite
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func load() throws -> [ScanRecord] {
        try prepare()
        recoveryWarning = nil
        do { try recoverTransactions() }
        catch { recoveryWarning = "Some interrupted file operations need recovery: \(error.localizedDescription). Existing projects are still available." }
        do { try migrateLegacy() }
        catch { recoveryWarning = "Some legacy scans could not be migrated: \(error.localizedDescription). Original files were retained." }
        var records: [ScanRecord] = []
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                var record = try read(id)
                if record.state == .capturing || record.state == .processing {
                    record.state = hasCompletedAsset(record) ? .ready : .interrupted
                    record.failure = record.failure ?? "Capture or processing was interrupted. Any source files that were saved are retained."
                    try writeManifest(record, in: folder)
                }
                if let path = record.modelPath, !fm.fileExists(atPath: try ScanPaths.resolve(path, in: folder).path) {
                    record.state = .damaged
                    record.failure = "The original model is missing. Retained source data may allow recovery."
                }
                record.byteCount = try size(of: folder)
                records.append(record)
            } catch {
                records.append(ScanRecord(id: id, date: .distantPast, name: "Recoverable scan files", method: .room,
                    state: .damaged, device: "Unknown", operatingSystem: "Unknown", failure: error.localizedDescription))
            }
        }
        return records.sorted { $0.date > $1.date }
    }

    func list() throws -> [ScanRecord] {
        try prepare()
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { url -> ScanRecord? in
                guard let id = UUID(uuidString: url.lastPathComponent), var record = try? read(id) else { return nil }
                record.byteCount = try size(of: url)
                return record
            }.sorted { $0.date > $1.date }
    }

    func create(method: CaptureMethod, name: String, device: String, operatingSystem: String) throws -> ScanRecord {
        try Task.checkCancellation()
        try prepare()
        let record = ScanRecord(id: UUID(), date: Date(), name: name, method: method, state: .capturing,
                                device: device, operatingSystem: operatingSystem)
        let staging = root.appendingPathComponent(".staging-\(record.id)")
        try fm.createDirectory(at: staging.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        do {
            try writeManifest(record, in: staging)
            try Task.checkCancellation()
            try beforeWrite()
            try fm.moveItem(at: staging, to: directory(for: record.id))
            return record
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func read(_ id: UUID) throws -> ScanRecord {
        let data = try Data(contentsOf: directory(for: id).appendingPathComponent("manifest.json"))
        var record = try JSONDecoder().decode(ScanRecord.self, from: data)
        guard record.id == id, record.schemaVersion == 1 else { throw ScanFailure.invalidPath }
        for path in [record.modelPath, record.thumbnailPath].compactMap({ $0 }) {
            _ = try ScanPaths.resolve(path, in: directory(for: id))
        }
        refreshRoomSourceWarnings(&record)
        return record
    }

    // Older projects did not record raw-archive failures. Infer availability
    // from retained files without treating a usable processed room as damaged.
    private func refreshRoomSourceWarnings(_ record: inout ScanRecord) {
        guard record.method == .room, record.sourceAvailable else { record.sourceWarnings = nil; return }
        let sources = directory(for: record.id).appendingPathComponent("Sources")
        guard let files = try? fm.contentsOfDirectory(atPath: sources.path) else { return }
        var warnings = record.sourceWarnings ?? [:]
        for name in files where name.hasPrefix("room-") && name.hasSuffix(".json") {
            let digits = String(name.dropFirst(5).dropLast(5))
            guard let number = Int(digits), number > 0 else { continue }
            let raw = String(format: "capture-%03d.json", number)
            if files.contains(raw) { warnings.removeValue(forKey: raw) }
            else if warnings[raw] == nil {
                warnings[raw] = "Room \(number): raw sensor archive is unavailable. The processed room data is retained for project rebuilding and export."
            }
        }
        record.sourceWarnings = warnings.isEmpty ? nil : warnings
    }

    func recordRoomSourceWarning(_ id: UUID, number: Int, warning: String?) throws -> String? {
        var record = try read(id)
        let key = String(format: "capture-%03d.json", number)
        if record.sourceWarnings?[key] != nil, let warning { record.sourceWarnings?[key] = warning }
        record.roomCount = max(record.roomCount, number)
        try writeManifest(record, in: directory(for: id))
        return record.sourceWarnings?[key]
    }

    func saveSources(_ id: UUID, files: [String: ScanFile]) throws {
        _ = try read(id)
        let folder = directory(for: id).appendingPathComponent("Sources", isDirectory: true)
        for (path, file) in files { try write(file, to: ScanPaths.resolve(path, in: folder)) }
    }

    func update(_ id: UUID, state: ScanState? = nil, failure: String? = nil,
                name: String? = nil, roomCount: Int? = nil) throws -> ScanRecord {
        var record = try read(id)
        if let state {
            record.state = hasCompletedAsset(record) && (state == .interrupted || state == .failed) ? .ready : state
        }
        if let name { record.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
        if let roomCount { record.roomCount = roomCount }
        if let failure { record.failure = failure }
        else if state == .capturing || state == .processing || state == .ready { record.failure = nil }
        record.byteCount = (try? size(of: directory(for: id))) ?? record.byteCount
        try writeManifest(record, in: directory(for: id))
        return record
    }

    func commit(_ id: UUID, files: [String: ScanFile], model: String?, thumbnail: String?,
                dimensions: ScanDimensions? = nil) throws -> ScanRecord {
        var record = try read(id)
        let project = directory(for: id)
        let oldAssets = record.modelPath ?? record.thumbnailPath
        let revision = "Assets/\(UUID().uuidString)"
        let assets = project.appendingPathComponent(revision, isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        do {
            for (path, file) in files { try write(file, to: ScanPaths.resolve(path, in: assets)) }
            for path in [model, thumbnail].compactMap({ $0 }) {
                guard fm.fileExists(atPath: try ScanPaths.resolve(path, in: assets).path) else { throw ScanFailure.missingProject }
            }
            record.modelPath = model.map { revision + "/" + $0 }
            record.thumbnailPath = thumbnail.map { revision + "/" + $0 }
            record.dimensions = dimensions
            record.state = .ready
            record.failure = nil
            record.byteCount = try size(of: project)
            try Task.checkCancellation()
            try writeManifest(record, in: project)
        } catch {
            // The old manifest still references the previous complete revision.
            try? fm.removeItem(at: assets)
            throw error
        }
        // The manifest is now committed. Cleanup must never roll back its assets.
        if let oldAssets {
            let components = oldAssets.split(separator: "/")
            if components.count >= 3, components[0] == "Assets", UUID(uuidString: String(components[1])) != nil {
                try? fm.removeItem(at: project.appendingPathComponent("Assets/\(components[1])"))
            }
        }
        record.byteCount = (try? size(of: project)) ?? record.byteCount
        return record
    }

    func removeSources(_ id: UUID) throws -> ScanRecord {
        var record = try read(id)
        guard record.state == .ready, record.method != .depth else { throw ScanFailure.missingSources }
        let source = directory(for: id).appendingPathComponent("Sources")
        let trash = directory(for: id).appendingPathComponent(".sources-removed")
        if fm.fileExists(atPath: trash.path) { try fm.removeItem(at: trash) }
        if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: trash) }
        do {
            record.sourceAvailable = false
            record.sourceWarnings = nil
            try writeManifest(record, in: directory(for: id))
        } catch {
            if fm.fileExists(atPath: trash.path) { try? fm.moveItem(at: trash, to: source) }
            throw error
        }
        if fm.fileExists(atPath: trash.path) { try fm.removeItem(at: trash) }
        record.byteCount = try size(of: directory(for: id))
        return record
    }

    func delete(_ id: UUID) throws {
        let source = directory(for: id)
        let trash = root.appendingPathComponent(".deleted-\(id)")
        try beforeWrite()
        if fm.fileExists(atPath: trash.path) { try fm.removeItem(at: trash) }
        try fm.moveItem(at: source, to: trash)
        do { try fm.removeItem(at: trash) }
        catch { try? fm.moveItem(at: trash, to: source); throw error }
    }

    private func prepare() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
    }

    private func hasCompletedAsset(_ record: ScanRecord) -> Bool {
        guard let path = record.modelPath ?? record.thumbnailPath,
              let url = try? ScanPaths.resolve(path, in: directory(for: record.id)) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    private func recoverTransactions() throws {
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for folder in folders {
            let name = folder.lastPathComponent
            if name.hasPrefix(".deleted-"), let id = UUID(uuidString: String(name.dropFirst(9))),
               !fm.fileExists(atPath: directory(for: id).path) {
                // A deletion interrupted before completion is recoverable, not silently lost.
                try fm.moveItem(at: folder, to: directory(for: id))
            } else if name.hasPrefix(".staging-") || name.hasPrefix(".migration-") {
                if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                   let record = try? JSONDecoder().decode(ScanRecord.self, from: data),
                   !fm.fileExists(atPath: directory(for: record.id).path) {
                    try fm.moveItem(at: folder, to: directory(for: record.id))
                }
            }
        }
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard let id = UUID(uuidString: folder.lastPathComponent), let record = try? read(id) else { continue }
            let trash = folder.appendingPathComponent(".sources-removed")
            guard fm.fileExists(atPath: trash.path) else { continue }
            if record.sourceAvailable {
                let source = folder.appendingPathComponent("Sources")
                if !fm.fileExists(atPath: source.path) { try fm.moveItem(at: trash, to: source) }
            } else { try fm.removeItem(at: trash) }
        }
    }

    private func writeManifest(_ record: ScanRecord, in folder: URL) throws {
        try beforeWrite()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func write(_ file: ScanFile, to url: URL) throws {
        try Task.checkCancellation()
        try beforeWrite()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch file {
        case .data(let data): try data.write(to: url, options: .atomic)
        case .file(let source):
            let temp = url.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID())")
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: source, to: temp)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: url) }
        }
    }

    private func size(of url: URL) throws -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private struct LegacyRecord: Decodable {
        let id: UUID
        let date: Date
        let filename: String
        let depthFilename: String?
        let scanType: String?
    }

    private func migrateLegacy() throws {
        guard let legacy, fm.fileExists(atPath: legacy.appendingPathComponent("index.json").path) else { return }
        let records = try JSONDecoder().decode([LegacyRecord].self, from: Data(contentsOf: legacy.appendingPathComponent("index.json")))
        for old in records {
            let destination = directory(for: old.id)
            // Never overwrite a migrated project, including later user edits.
            if fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) {
                continue
            }
            let staging = root.appendingPathComponent(".migration-\(old.id)")
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            var record = ScanRecord(id: old.id, date: old.date, name: "Imported \(old.scanType == "object" ? "item" : "room")",
                method: old.scanType == "object" ? .quickObject : .room, state: .ready, device: "Unknown", operatingSystem: "Unknown", sourceAvailable: false)
            do {
                let source = try ScanPaths.resolve(old.filename, in: legacy)
                if fm.fileExists(atPath: source.path) {
                    let data = try Data(contentsOf: source)
                    try write(.data(data), to: staging.appendingPathComponent("Assets/model.usdz"))
                    guard try Data(contentsOf: staging.appendingPathComponent("Assets/model.usdz")) == data else { throw ScanFailure.missingProject }
                    record.modelPath = "Assets/model.usdz"
                } else {
                    record.state = .damaged
                    record.failure = "The legacy model was missing. Its history record has been preserved."
                }
                if let depth = old.depthFilename {
                    let source = try ScanPaths.resolve(depth, in: legacy)
                    if fm.fileExists(atPath: source.path) {
                        try write(.file(source), to: staging.appendingPathComponent("Assets/depth.png"))
                        guard try Data(contentsOf: source) == Data(contentsOf: staging.appendingPathComponent("Assets/depth.png")) else { throw ScanFailure.missingProject }
                        record.thumbnailPath = "Assets/depth.png"
                    }
                }
                try writeManifest(record, in: staging)
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
        for old in records { try removeVerifiedLegacyCopies(old, legacy: legacy) }
        // Keep the old index for diagnostics; only byte-verified duplicate assets are removed.
        let archived = legacy.appendingPathComponent("index.migrated.json")
        if fm.fileExists(atPath: archived.path) { try fm.removeItem(at: archived) }
        try fm.moveItem(at: legacy.appendingPathComponent("index.json"), to: archived)
    }

    private func removeVerifiedLegacyCopies(_ old: LegacyRecord, legacy: URL) throws {
        let record = try read(old.id)
        guard record.state == .ready else { return }
        for (original, migrated) in [(Optional(old.filename), record.modelPath), (old.depthFilename, record.thumbnailPath)] {
            guard let original, let migrated else { continue }
            let source = try ScanPaths.resolve(original, in: legacy)
            guard fm.fileExists(atPath: source.path) else { continue }
            let copy = try ScanPaths.resolve(migrated, in: directory(for: old.id))
            if try Data(contentsOf: source) == Data(contentsOf: copy) { try fm.removeItem(at: source) }
        }
    }
}
