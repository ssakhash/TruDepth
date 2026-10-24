import SwiftUI
import RealityKit
import QuickLook

struct ScanHistoryView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var query = ""
    @State private var deleting: ScanRecord?
    var body: some View {
        List {
            if !store.scans.isEmpty {
                Text("\(store.scans.count) scans · \(ByteCountFormatter.string(fromByteCount: store.scans.reduce(0) { $0 + $1.byteCount }, countStyle: .file)) on this iPhone")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.scans.isEmpty {
                ContentUnavailableView("No scans yet", systemImage: "cube", description: Text("Your scans and their source data are stored on this iPhone."))
            }
            ForEach(store.scans.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { record in
                NavigationLink(value: AppRoute.scan(record.id)) {
                    HStack(spacing: 14) {
                        if let url = store.url(record, path: record.thumbnailPath), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else { Image(systemName: record.method.symbol).frame(width: 64, height: 64).foregroundStyle(Color.accent) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.name).lineLimit(2)
                            Text("\(record.method.title) · \(record.formattedDate)").font(.caption).foregroundStyle(.secondary)
                            Text("\(record.state.rawValue.capitalized) · \(record.fileSize)").font(.caption).foregroundStyle(record.state == .ready ? Color.secondary : .orange)
                        }
                    }
                }.swipeActions { Button("Delete", role: .destructive) { deleting = record } }
            }
        }.searchable(text: $query, prompt: "Find scans").scanNavigation("history")
        .confirmationDialog("Delete this scan and all retained source data?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Scan", role: .destructive) { if let deleting { Task { await store.delete(deleting) } }; deleting = nil }
        }
    }
}

struct ScanDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: ScanStore
    @AppStorage("displayInches") private var inches = false
    @State private var ticket: ExportTicket?
    @State private var exportToClean: ExportTicket?
    @State private var quickLook: URL?
    @State private var busy = false
    @State private var progress: Double = 0
    @State private var message: String?
    @State private var rename = false
    @State private var name = ""
    @State private var removeSources = false
    @State private var job: Task<Void, Never>?
    private var record: ScanRecord? { store.scans.first { $0.id == id } }
    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let url = store.url(record, path: record.modelPath) {
                            RealityModelView(url: url).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 16))
                        } else if let url = store.url(record, path: record.thumbnailPath), let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 340)
                        }
                        Text(record.name).font(.title2)
                        Text("\(record.method.title) · \(record.formattedDate)").foregroundStyle(.secondary)
                        if let dimensions = record.dimensions {
                            Text(dimensions.formatted(inches: inches)).font(.system(.title3, design: .monospaced))
                            Toggle("Display inches", isOn: $inches)
                            Text("Dimensions are estimates. All 3D exports use meters.").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(record.device) · iOS \(record.operatingSystem)\n\(record.fileSize) stored locally").font(.caption).foregroundStyle(.secondary)
                        if let failure = record.failure { Text(failure).foregroundStyle(.orange) }
                        if let warnings = record.sourceWarnings, !warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Some raw room archives are unavailable", systemImage: "info.circle")
                                Text("The saved model and processed room data remain available. Raw sensor reprocessing is unavailable for the rooms listed below.")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Source details") {
                                    ForEach(warnings.keys.sorted(), id: \.self) { key in
                                        Text("\(key): \(warnings[key] ?? "")").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        if busy { ProgressView(value: progress); Button("Cancel") { job?.cancel() } }
                        if record.state == .ready {
                            exportMenu(record).buttonStyle(.borderedProminent).disabled(busy)
                            if let url = store.url(record, path: record.modelPath) { Button("View in AR") { quickLook = url }.buttonStyle(.bordered) }
                        }
                        if record.sourceAvailable && record.state != .capturing && record.state != .processing {
                            Button(record.state == .ready ? "Rebuild from source data" : "Retry processing") { retry(record) }.disabled(busy)
                        }
                        Button("Rename") { name = record.name; rename = true }
                        if record.sourceAvailable && record.state == .ready && record.method != .depth {
                            Button("Remove Source Data", role: .destructive) { removeSources = true }.disabled(busy)
                        }
                    }.padding()
                }
            } else { ContentUnavailableView("Scan unavailable", systemImage: "exclamationmark.triangle") }
        }.scanNavigation("scan").quickLookPreview($quickLook)
        .awakeDuringScan(busy)
        .sheet(item: $ticket, onDismiss: {
            if let exportToClean { Task { await ScanExportService.shared.remove(exportToClean) } }
            exportToClean = nil
        }) { export in
            FilesExportPicker(ticket: export) { ticket = nil }
        }
        .alert("Rename scan", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Save") { if let record { Task { await store.rename(record, to: name) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove photos and reconstruction inputs? The completed model and its textures remain available.", isPresented: $removeSources) {
            Button("Remove Source Data", role: .destructive) { if let record { Task { await store.removeSources(record) } } }
        }
        .alert("Scan", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .onDisappear { job?.cancel() }
    }
    private func exportMenu(_ record: ScanRecord) -> some View {
        Menu("Export to Files") {
            ForEach(record.method == .depth ? [.ply, .png, .sources] as [ScanExportFormat] : [.glb, .obj, .usdz]) { format in
                Button(format.title) { export(record, format: format) }
            }
            if record.method != .depth && record.sourceAvailable { Button("Source data folder") { export(record, format: .sources) } }
            if record.method != .depth && record.thumbnailPath != nil { Button("PNG preview") { export(record, format: .png) } }
            if record.method == .room && record.roomCount > 0 && record.sourceAvailable {
                ForEach(1...record.roomCount, id: \.self) { room in
                    Menu("Room \(room)") {
                        ForEach([ScanExportFormat.glb, .obj, .usdz]) { format in Button(format.title) { export(record, format: format, room: room) } }
                    }
                }
            }
        }
    }
    private func export(_ record: ScanRecord, format: ScanExportFormat, room: Int? = nil) {
        busy = true; progress = 0
        job = Task {
            defer { busy = false }
            do {
                let export = try await ScanExportService.shared.prepare(record, format: format, room: room)
                if Task.isCancelled { await ScanExportService.shared.remove(export) } else { exportToClean = export; ticket = export }
            } catch { message = error.localizedDescription }
        }
    }
    private func retry(_ record: ScanRecord) {
        busy = true; progress = 0
        job = Task {
            defer { busy = false }
            do { _ = try await store.retry(record) { value in await MainActor.run { progress = value } } }
            catch { message = error.localizedDescription }
        }
    }
}

struct FilesExportPicker: UIViewControllerRepresentable {
    let ticket: ExportTicket
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [ticket.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
    }
}
