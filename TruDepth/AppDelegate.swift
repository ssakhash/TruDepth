import SwiftUI

// MARK: - Entry Point

@main
struct TruDepthApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - Root (Tab Container)

struct RootView: View {
    @State private var selectedTab = 0
    @State private var showScanSheet = false
    @State private var showObjectScanSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            tabContent
                .animation(.easeInOut(duration: 0.2), value: selectedTab)

            FloatingTabBar(selectedTab: $selectedTab)
                .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanSheet) {
            RoomScanView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showObjectScanSheet) {
            ObjectScanView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0:
            NavigationStack {
                HomeView(showScanSheet: $showScanSheet, showObjectScanSheet: $showObjectScanSheet)
            }
            .transition(.opacity)
        case 1:
            LiveMeshView()
                .transition(.opacity)
        case 2:
            NavigationStack {
                ScanHistoryView(showScanSheet: $showScanSheet)
            }
            .transition(.opacity)
        default:
            NavigationStack {
                HomeView(showScanSheet: $showScanSheet, showObjectScanSheet: $showObjectScanSheet)
            }
        }
    }
}

// MARK: - Floating Tab Bar

private struct TabConfig {
    let icon: String
    let label: String
}

private let tabConfigs: [TabConfig] = [
    TabConfig(icon: "house", label: "Home"),
    TabConfig(icon: "cube.fill", label: "Depth"),
    TabConfig(icon: "clock", label: "History"),
]

struct FloatingTabBar: View {
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabConfigs.indices, id: \.self) { index in
                TabBarItem(
                    icon: tabConfigs[index].icon,
                    label: tabConfigs[index].label,
                    isSelected: selectedTab == index
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        selectedTab = index
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
        .padding(6)
        .background(Color.black, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

private struct TabBarItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
            }
            .foregroundStyle(isSelected ? Color.accent : .white.opacity(DS.textTertiary))
            .frame(minWidth: 64)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.white.opacity(isSelected ? 0.1 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home View

struct HomeView: View {
    @Binding var showScanSheet: Bool
    @Binding var showObjectScanSheet: Bool
    @ObservedObject private var scanStore = ScanStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 64)
                    featureSection
                        .padding(.top, 48)
                    if !scanStore.scans.isEmpty {
                        recentSection
                            .padding(.top, 40)
                    }
                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("trudepth")
                        .font(.system(size: 42, weight: .thin))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                    Text("lidar  ·  depth  ·  room scanning")
                        .font(.system(size: 13, weight: .regular))
                        .tracking(2.0)
                        .foregroundStyle(.white.opacity(DS.textTertiary))
                }
                Spacer()
                Button(action: {
                    showScanSheet = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(white: 0.1))
                            .frame(width: 44, height: 44)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            // Cyan hairline accent
            Rectangle()
                .fill(Color.accent)
                .frame(width: 24, height: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        }
    }

    // MARK: Features

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("FEATURES")

            FeatureCard(
                icon: "cube.transparent.fill",
                title: "Live Depth",
                subtitle: "Real-time LiDAR mesh visualization",
                destination: { LiveMeshView() }
            )

            FeatureCard(
                icon: "house.fill",
                title: "Scan Room",
                subtitle: "Capture and export a 3D room model",
                action: {
                    showScanSheet = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            )

            FeatureCard(
                icon: "cube.transparent",
                title: "Scan Item",
                subtitle: "Capture an object's 3D shape and measurements",
                action: {
                    showObjectScanSheet = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            )
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                sectionLabel("RECENT")
                Spacer()
                Text("\(scanStore.scans.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accent.opacity(0.15), in: Capsule())
            }

            ForEach(scanStore.scans.reversed().prefix(3)) { scan in
                NavigationLink(
                    destination: ModelViewerView(capturedRoom: nil, exportURL: scan.url, depthImageURL: scan.depthURL, onNewScan: {})
                ) {
                    ScanRow(record: scan)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.lowercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(1.0)
            .foregroundStyle(.white.opacity(DS.textTertiary))
    }
}

// MARK: - Scan History View

struct ScanHistoryView: View {
    @Binding var showScanSheet: Bool
    @ObservedObject private var scanStore = ScanStore.shared

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
    }

    private var titleBar: some View {
        HStack {
            Text("history")
                .font(.system(size: 28, weight: .thin))
                .tracking(0.5)
                .foregroundStyle(.white)
            Spacer()
            Button(action: {
                showScanSheet = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                        destination: ModelViewerView(capturedRoom: nil, exportURL: scan.url, depthImageURL: scan.depthURL, onNewScan: {})
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
                showScanSheet = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .font(.system(size: 16))
            .foregroundStyle(Color.accent)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
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
