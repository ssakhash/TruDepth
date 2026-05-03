import SwiftUI
import ARKit
import RoomPlan

// MARK: - Entry Point

@main
struct TruDepthApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - Root

struct RootView: View {
    var body: some View {
        HomeView()
            .preferredColorScheme(.dark)
    }
}

// MARK: - Shared Capability Gating

enum ScanCapability: String, Identifiable {
    case liveDepth
    case roomScan
    case objectScan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveDepth: "Live Depth"
        case .roomScan: "Room Scan"
        case .objectScan: "Item Scan"
        }
    }

    var unsupportedMessage: String {
        switch self {
        case .liveDepth:
            "This feature requires a LiDAR-equipped iPhone with scene reconstruction and depth sensing."
        case .roomScan:
            "Room scanning requires a LiDAR-equipped iPhone that supports RoomPlan."
        case .objectScan:
            "Item scanning requires a LiDAR-equipped iPhone with mesh reconstruction."
        }
    }

    var isSupported: Bool {
        switch self {
        case .liveDepth:
            return ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        case .roomScan:
            return RoomCaptureSession.isSupported
        case .objectScan:
            return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @State private var showDepth = false
    @State private var showRoom = false
    @State private var showItem = false
    @State private var showHistory = false
    @State private var unsupportedFeature: ScanCapability?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text("trudepth")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.leading, 32)

                Spacer().frame(height: 72)

                navItem("live depth") { present(.liveDepth) { showDepth = true } }
                navItem("scan room")  { present(.roomScan) { showRoom = true } }
                navItem("scan item")  { present(.objectScan) { showItem = true } }
                navItem("history")    { showHistory = true }

                Spacer()
            }
        }
        .fullScreenCover(isPresented: $showDepth) { LiveMeshView() }
        .fullScreenCover(isPresented: $showRoom) { RoomScanView() }
        .fullScreenCover(isPresented: $showItem) { ObjectScanView() }
        .fullScreenCover(isPresented: $showHistory) {
            NavigationStack { ScanHistoryView() }
        }
        .alert(item: $unsupportedFeature) { feature in
            Alert(
                title: Text("\(feature.title) Unavailable"),
                message: Text(feature.unsupportedMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func navItem(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 72)
                .padding(.leading, 32)
        }
        .buttonStyle(.plain)
    }

    private func present(_ feature: ScanCapability, action: () -> Void) {
        guard feature.isSupported else {
            unsupportedFeature = feature
            return
        }
        action()
    }
}

// MARK: - Scan History View

struct ScanHistoryView: View {
    @State private var showScanSheet = false
    @ObservedObject private var scanStore = ScanStore.shared
    @State private var unsupportedFeature: ScanCapability?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                titleBar
                Divider()
                    .overlay(.white.opacity(DS.borderSubtle))
                if scanStore.scans.isEmpty {
                    emptyState
                } else {
                    scanList
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showScanSheet) {
            RoomScanView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert(item: $unsupportedFeature) { feature in
            Alert(
                title: Text("\(feature.title) Unavailable"),
                message: Text(feature.unsupportedMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var titleBar: some View {
        HStack {
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
            }
            Spacer()
            Text("history")
                .font(.system(size: 28, weight: .thin))
                .tracking(0.5)
                .foregroundStyle(.white)
            Spacer()
            Button(action: {
                presentRoomScan()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Color(white: 0.1), in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var scanList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(scanStore.scans.reversed()) { scan in
                    NavigationLink(
                        destination: ModelViewerView(capturedRoom: nil, exportURL: scan.url, depthImageURL: scan.depthURL, dismissLabel: "back", onNewScan: {})
                    ) {
                        ScanRow(record: scan)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            withAnimation { scanStore.delete(scan) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        ShareLink(item: scan.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(Color.accent)
                    }
                    Divider()
                        .overlay(.white.opacity(DS.separator))
                        .padding(.horizontal, 20)
                }
                Spacer(minLength: 120)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.white.opacity(DS.textTertiary))
            Text("No scans yet")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text("Scan a room to capture a 3D model.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(DS.textTertiary))
                .multilineTextAlignment(.center)
            Button("Start Scanning") {
                presentRoomScan()
            }
            .font(.system(size: 16))
            .foregroundStyle(Color.accent)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func presentRoomScan() {
        guard ScanCapability.roomScan.isSupported else {
            unsupportedFeature = .roomScan
            return
        }
        showScanSheet = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Feature Card

struct FeatureCard<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let destination: (() -> Destination)?
    var action: (() -> Void)?

    init(icon: String, title: String, subtitle: String,
         destination: (() -> Destination)?,
         action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
        self.action = action
    }

    var body: some View {
        Group {
            if let destination {
                NavigationLink(destination: destination()) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                Button(action: action ?? {}) {
                    cardContent
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cardContent: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title.lowercased())
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white)
                Text(subtitle.lowercased())
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(20)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// Convenience init when there's no navigation destination
extension FeatureCard where Destination == EmptyView {
    init(icon: String, title: String, subtitle: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, subtitle: subtitle, destination: nil, action: action)
    }
}

// MARK: - Scan Row

struct ScanRow: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: record.scanType == .object ? "cube.transparent" : "house")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.formattedDate)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                if !record.fileSize.isEmpty {
                    Text(record.fileSize)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                }
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(DS.textTertiary))
        }
    }
}

// MARK: - Design System Tokens

enum DS {
    // Opacity constants
    static let textSecondary: Double = 0.5
    static let textTertiary: Double  = 0.25
    static let borderSubtle: Double  = 0.08
    static let borderDefault: Double = 0.14
    static let separator: Double     = 0.06
}

// MARK: - Search History View

struct SearchHistoryView: View {
    @State private var query = ""
    @ObservedObject private var store = ScanStore.shared
    @Environment(\.dismiss) private var dismiss

    private var results: [ScanRecord] {
        let all = Array(store.scans.reversed())
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.formattedDate.localizedCaseInsensitiveContains(query) ||
            $0.scanType.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    TextField("search scans", text: $query)
                        .font(.system(size: 22, weight: .thin))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 56)
                        .padding(.bottom, 32)

                    if results.isEmpty {
                        Spacer()
                        Text("no results")
                            .font(.system(size: 16, weight: .thin))
                            .tracking(3)
                            .foregroundStyle(.white.opacity(0.28))
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(results) { scan in
                                    NavigationLink(destination: ModelViewerView(capturedRoom: nil, exportURL: scan.url, depthImageURL: scan.depthURL, dismissLabel: "back", onNewScan: {})) {
                                        VStack(spacing: 4) {
                                            Text(scan.scanType.rawValue)
                                                .font(.system(size: 18, weight: .thin))
                                                .tracking(4)
                                                .foregroundStyle(.white)
                                            Text(scan.formattedDate)
                                                .font(.system(size: 13, weight: .thin))
                                                .tracking(2)
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 72)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 40)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Colour Extensions

extension Color {
    static let accent = Color(red: 0, green: 0.831, blue: 1.0) // #00D4FF

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
