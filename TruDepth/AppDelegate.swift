import SwiftUI

@main
struct TruDepthApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

// MARK: - Home Screen

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    headerSection
                        .padding(.top, 56)

                    Spacer()

                    featureCards
                        .padding(.horizontal, 20)

                    Spacer()

                    footer
                        .padding(.bottom, 28)
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
    }

    private var headerSection: some View {
        VStack(spacing: 6) {
            Text("TruDepth")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("LiDAR · Depth · Room Scanning")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1.5)
        }
    }

    private var featureCards: some View {
        VStack(spacing: 16) {
            NavigationLink(destination: LiveMeshView()) {
                FeatureCard(
                    icon: "cube.transparent.fill",
                    title: "Live Depth",
                    subtitle: "Real-time LiDAR mesh visualization",
                    gradient: [Color(hex: "0A84FF"), Color(hex: "5E5CE6")]
                )
            }
            .buttonStyle(.plain)

            NavigationLink(destination: RoomScanView()) {
                FeatureCard(
                    icon: "house.fill",
                    title: "Scan Room",
                    subtitle: "Capture and export a 3D room model",
                    gradient: [Color(hex: "30D158"), Color(hex: "0A84FF")]
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        Text("Requires iPhone with LiDAR Sensor")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.2))
            .tracking(0.5)
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Helpers

extension Color {
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
