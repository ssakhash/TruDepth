# TruDepth

A native iOS app for real-time LiDAR depth visualization, 3D room scanning, and object measurement, built with ARKit, RealityKit, RoomPlan, Metal, ModelIO, and SwiftUI.

## Features

### Live Depth
- Real-time LiDAR mesh reconstruction rendered via ARKit + RealityKit
- Three distinct visualization modes:
  - **classify** — semantic surface coloring (walls, floors, doors, windows)
  - **wireframe** — raw LiDAR mesh wire skeleton on live camera passthrough (no surface fill)
  - **depth** — GPU-accelerated jet-colormap heatmap on black background via Metal
- Center-point distance readout sampled from the raw `sceneDepth` pixel buffer at 150ms intervals
- Metal heatmap uses a zero-copy `CVMetalTextureCache` path — no CPU roundtrips for the depth overlay

### Scan Room
- Full 3D room capture via the RoomPlan framework, including walls, doors, windows, and furniture
- Real-time wall detection counter and progress indicator during scanning
- **Depth snapshot**: tap the capture button during a scan to save a jet-colormap PNG of the raw LiDAR depth data alongside the USDZ export
- Exports scans as USDZ — viewable in AR via QuickLook or shared directly from the app

### Scan Item
- Object scanning using ARWorldTracking + LiDAR mesh reconstruction
- Keep the phone still and rotate the object — the app builds a 3D mesh in real time
- Live bounding box readout shows width × height × depth in centimetres as the mesh grows
- Exports the captured mesh as USDZ via ModelIO for sharing or AR viewing

### Scan History
- Persistent scan library stored in the app's Documents directory (`TruDepthScans/`)
- Tracks both room scans and object scans with distinct icons
- Scan records keyed by filename for stability across reinstalls
- Optional depth PNG stored alongside room scan USDZ records
- Swipe to delete or share any previous scan
- 3D model viewer with full-bleed SceneKit rendering for any saved scan

## Architecture

The app is structured across four source files plus one Metal shader:

| File | Responsibility |
|------|---------------|
| `AppDelegate.swift` | App entry point, tab navigation, `HomeView`, `ScanHistoryView`, design system tokens |
| `ViewController.swift` | `RoomScanView` (RoomPlan session), `ModelViewerView` (SceneKit + QuickLook), `ScanStore`, `ScanRecord` |
| `SceneDelegate.swift` | `LiveMeshView` (ARKit session + mesh visualization), `DepthHeatmapRenderer` (Metal pipeline) |
| `ObjectScanView.swift` | `ObjectScanView` + `ObjectScanViewModel` (ARWorldTracking + LiDAR mesh + MDLAsset USDZ export) |
| `DepthHeatmap.metal` | Full-screen quad vertex shader + jet-colormap fragment shader for the depth heatmap |

### Key Design Decisions

- **`ScanRecord` stores filename, not URL** — the Documents directory path changes across reinstalls; the URL is recomputed at access time.
- **`ScanRecord` has a `scanType` field** with backward-compatible Codable decoding (`decodeIfPresent`, defaults to `.room` for old records).
- **Phase enum has no associated values** — `CapturedRoom` is not `Equatable`, so associated values broke phase comparison. Room data and URLs are separate `@Published` properties on the view model.
- **Metal heatmap is a separate `MTKView` overlay** — keeps the ARView render loop untouched; in depth mode a `Color.black` layer is inserted between the ARView and the MTKView so jet-color values pop against a dark background.
- **wireframe mode omits `.showSceneUnderstanding`** — using only `.showAnchorGeometry` prevents the opaque semantic surface fill from hiding the wire edges.
- **Depth snapshot uses a post-scan ARSession** — RoomPlan's session does not expose its underlying ARSession; after `RoomCaptureSession.stop()` a brief standalone `ARSession` with `.sceneDepth` semantics captures one frame.
- **Object USDZ export uses ModelIO** — `ARMeshAnchor` vertex positions are transformed to world space and packed into `MDLMesh` / `MDLAsset`, then exported via `MDLAsset.export(to:)`.
- **`CVPixelBuffer` cross-thread transfer** — wrapped in `UncheckedSendable` with explicit `CVPixelBufferLockBaseAddress`/`Unlock` ownership.

## Requirements

- Xcode 15 or later
- iOS 14.0 or later
- LiDAR-equipped device (iPhone 12 Pro or later, iPad Pro 2020 or later)
  - All core features require LiDAR; the app degrades gracefully on unsupported devices

## Usage

1. **Home** — overview of features and recent scans. Tap any feature card to begin.
2. **live depth** — enter real-time LiDAR visualization. Use the segmented control to switch between classify, wireframe, and depth modes. The distance badge shows center-frame depth in real time.
3. **scan room** — walk around a room while RoomPlan builds a 3D model. Tap the aperture button to save a raw depth snapshot. Tap **done** when coverage is complete.
4. **scan item** — place an object on a flat surface, keep the phone still, and slowly rotate the object. The bounding box readout updates live. Tap **done** to export.
5. **History** tab — full list of saved room and object scans. Tap any row to open the 3D model viewer. Swipe left to delete, swipe right to share.

## Contributing

PRs and issues are welcome. For significant changes, open an issue first to discuss the approach.
