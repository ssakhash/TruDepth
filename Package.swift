// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TruDepthCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TruDepthCore", targets: ["TruDepthCore"])],
    targets: [
        .target(name: "TruDepthCore", path: "TruDepth", exclude: [
            "AppDelegate.swift", "SceneDelegate.swift", "ViewController.swift", "ObjectScanView.swift",
            "ScanServices.swift", "ScanLibraryView.swift", "RealityModelView.swift", "PhotoScanView.swift",
            "DepthHeatmap.metal", "Info.plist", "Assets.xcassets", "Base.lproj", "TruDepth.xcdatamodeld", "appstore.png", "playstore.png"
        ], sources: ["ScanCore.swift", "ScanAsset.swift", "ModelIOCodec.swift", "DepthSnapshot.swift"]),
        .testTarget(name: "TruDepthCoreTests", dependencies: ["TruDepthCore"], path: "Tests")
    ]
)
