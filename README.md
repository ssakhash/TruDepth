# TruDepth

A native iOS app for real-time LiDAR depth visualization and 3D room scanning, built with ARKit, RealityKit, RoomPlan, Metal, and SwiftUI.

## Features

### Live Depth
- Real-time LiDAR mesh reconstruction rendered via ARKit + RealityKit
- Three visualization modes: **Classify** (semantic surface coloring), **Wireframe** (anchor geometry overlay), and **Depth** (GPU-accelerated Metal heatmap)
- Center-point distance readout sampled from the raw `sceneDepth` pixel buffer at 150ms intervals
- Metal heatmap uses a zero-copy `CVMetalTextureCache` path — no CPU roundtrips for the depth overlay

### Room Scanning
- Full 3D room capture via the RoomPlan framework, including walls, doors, windows, and furniture
- Real-time wall detection counter and progress indicator during scanning
- Exports scans as USDZ — viewable in AR via QuickLook or shared directly from the app

### Scan History
- Persistent scan library stored in the app's Documents directory (`TruDepthScans/`)
- Scan records keyed by filename (not absolute path) for stability across reinstalls
- Swipe to delete or share any previous scan
- 3D model viewer with full-bleed SceneKit rendering for any saved scan

## Architecture

The app is structured across three source files:

| File | Responsibility |
|------|---------------|
| `AppDelegate.swift` | App entry point, tab navigation, `HomeView`, `ScanHistoryView`, `ScanStore`, `ScanRecord`, design system tokens |
| `ViewController.swift` | `RoomScanView` (RoomPlan session lifecycle), `ModelViewerView` (SceneKit + QuickLook) |
| `SceneDelegate.swift` | `LiveMeshView` (ARKit session + mesh visualization), `DepthHeatmapRenderer` (Metal pipeline) |

### Key Design Decisions

- **`ScanRecord` stores filename, not URL** — the Documents directory path changes across reinstalls; the URL is recomputed at access time.
- **Phase enum has no associated values** — `CapturedRoom` is not `Equatable`, so associated values broke phase comparison. Room and URL are separate `@Published` properties on the view model.
- **Metal heatmap is a separate `MTKView` overlay** — keeps the ARView render loop untouched; the `MTKView` is hidden when not in depth mode.
- **`CVPixelBuffer` cross-thread transfer** — wrapped in `UncheckedSendable` with explicit `CVPixelBufferLockBaseAddress`/`Unlock` ownership. The Metal renderer handles its own `CVMetalTextureCacheCreateTextureFromImage` call independently.
- **`jetColor` is `static`** — pure function with no actor context, safe to call from background queues without hopping to the main actor.

## Requirements

- Xcode 15 or later
- iOS 17.0 or later
- LiDAR-equipped device (iPhone 12 Pro or later, iPad Pro 2020 or later)
  - Live Depth and Room Scanning require LiDAR; the app degrades gracefully on unsupported devices

## Usage

1. **Home** — overview of features and recent scans. Tap **+** or **Scan Room** to start a new capture.
2. **Depth** — tap the tab to enter live LiDAR visualization. Use the segmented control to switch modes. The distance badge shows the depth at the center of the frame in real time.
3. **History** — full list of saved scans. Tap any row to open the 3D model viewer. Swipe left to delete, swipe right to share.

## Contributing

PRs and issues are welcome. For significant changes, open an issue first to discuss the approach.
