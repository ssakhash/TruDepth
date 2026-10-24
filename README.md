# TruDepth

An offline-first iPhone scanning utility built with SwiftUI, ARKit, RoomPlan,
RealityKit, Metal, and Model I/O. Requires **iOS 17+**. Capture capabilities are
detected at runtime rather than inferred from a device name, retaining support
for iPhone 14 Pro Max while using current frameworks on iPhone 18 Pro.

## Capture

- **Live depth:** classification or a confidence-filtered Metal depth heatmap,
  center distance, and explicit depth snapshots. A 180-degree preview correction
  aligns the display; snapshots use the matching portrait transform.
- **Quick item scan:** keep the object stationary and walk around it. Tap its
  horizontal supporting surface to place a crop box. Adjust width, height, depth,
  and rotation, or tap again to reposition. Measurement and export use exactly the
  same crop-local triangles, in meters. Completion requires valid geometry,
  normal tracking, and four distinct 45-degree camera-view sectors.
- **Detailed item scan:** guided automatic ObjectCapture photography, quality
  feedback, multiple passes/flip guidance, then on-device PhotogrammetrySession
  reconstruction with object masking and the iOS-supported `.reduced` detail.
  Keep the app open during reconstruction. Cancellation retains photographs and
  checkpoints for retry from history.
- **Connected rooms:** finish and save each room while retaining one AR session;
  add connected rooms and combine them using StructureBuilder. Loss of the
  coordinate frame ends further capture for that project. Retained rooms can be
  finalized after relaunch; adding rooms then requires a new project.
- **Depth snapshots:** capture the current AR frame, including RoomPlan's own AR
  session. Retain Float32 depth, UInt8 confidence, camera image, intrinsics, pose,
  and timestamp. Generate a PNG heatmap and calibrated, colored binary PLY cloud.

Crop-boundary warnings are a heuristic, **not verified background removal**.
LiDAR is suited to approximate shape and dimensions, not small-detail metrology.
Room scans are measured layouts, not photographic environment meshes.

## Local Library and Files

Projects live in `Application Support/TruDepth/Scans/<UUID>/`:

```text
manifest.json          Versioned identity, dates, type, state and relative paths
Sources/               Photos/checkpoints, cropped mesh, rooms, or raw depth
Assets/<revision>/     Committed model and thumbnail (depth PNG/PLY for snapshots)
```

`ScanRepository` serializes file operations. Asset revisions are written before
atomically replacing the manifest; only then does the main-actor `ScanStore`
publish success. Interrupted drafts remain in history. Recovery reads project
manifests rather than depending on a separately synchronized index.

Legacy `Documents/TruDepthScans` scans retain IDs and dates. Migration is
repeatable, verifies copies before removing duplicate legacy assets, keeps the
old index for diagnosis, and preserves missing-file records as damaged entries.
An unreadable legacy index is retained and reported without hiding newer scans.

Processing is on-device and successfully saved source data is retained until
explicitly removed. If RoomPlan refuses to serialize a raw capture, the app
still saves the processed room when possible and records the raw-archive
limitation in source details. That room can be finalized and exported, but its
unavailable raw sensor archive cannot be reprocessed. The notice remains visible
in history and accompanies source-folder exports; it is not a failed model save.
Completed models and sources remain eligible for normal system backups. Removing
the app deletes its local container unless restored from a backup; export
important work separately.

History supports names, thumbnails, capture types, dimensions, device/OS,
timestamps, processing status, storage totals, rename, delete, processing retry,
and explicit source removal. Removing sources preserves completed USDZ models
and their embedded textures. It disables rebuilding and individual-room export.

**Export to Files** always exports a copy through the system document picker.
Cancelling an export does not move or delete the stored original.

| Format | Contents |
| --- | --- |
| GLB | Self-contained static glTF 2.0 mesh with embedded textures and materials |
| OBJ folder | OBJ, MTL, texture files; keep the folder together |
| USDZ | Original packaged model for Quick Look/AR |
| PLY | Depth points with RGB, in ARKit world coordinates and meters |
| PNG | Depth heatmap or model preview |
| Source folder | Retained reconstruction inputs or raw depth with calibration |

Connected-room projects offer both combined and individual-room model exports.
Centimeter/inch display settings do not alter meter-based export geometry. OBJ
PBR material interpretation varies by receiving software; GLB is preferred for
portable PBR appearance. Export working copies live separately in Caches and are
removed after dismissal, with stale jobs cleaned on a later launch.

## Interaction and Performance

All screens offer **Main Menu**. Camera denial and unsupported hardware show
actionable errors instead of starting capture. Sessions and processing tasks are
cancelled when leaving their screens; recoverable source data is retained.

The RealityKit viewer fits model bounds. Drag to orbit, two-finger drag to pan,
and pinch to zoom. Quick Look remains available for AR placement.

Depth rendering uses a display-linked, latest-frame path capped at 60 fps, three
in-flight GPU frames, and retained zero-copy CoreVideo textures. Hidden rendering
is paused. Low Power Mode and thermal pressure reduce depth and mesh-update work;
camera and reconstruction acceleration remain framework-managed. Active capture
and processing prevent auto-lock while the app is in the foreground.
The app opts into [ProMotion timing](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays);
RealityKit and the system choose the actual viewer refresh rate. Sustained frame
rates are not guaranteed and require device profiling.

Configure **TruDepth > Start Scan** in Shortcuts or the Action button settings to
open the item-capture chooser. The shortcut does not start recording automatically.

## Development and Verification

Use Xcode with a Swift 6 compiler and the matching Metal toolchain. Project build
settings enable Swift 6 and complete strict-concurrency checking. Capture needs a
physical supported iPhone; the simulator supports library and navigation checks.

```sh
xcodebuild -downloadComponent MetalToolchain
xcodebuild -project TruDepth.xcodeproj -scheme TruDepth \
  -destination 'generic/platform=iOS' build
xcodebuild -project TruDepth.xcodeproj -scheme TruDepth \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
swift test --scratch-path /private/tmp/TruDepth-core-build
```

Core tests generate export fixtures in `/private/tmp/TruDepth-fixtures`. Optional
independent checks use temporary development-only packages:

```sh
npm install --prefix /private/tmp/TruDepth-validation gltf-validator three
node Scripts/validate-exports.mjs
```

The app itself has no third-party package dependencies or cloud processing.
Model I/O handles mesh ingestion and OBJ writing; SceneKit is used only as
Apple's native USDZ packager because Model I/O cannot directly write USDZ.
Rendering and interaction use RealityKit. See [validation notes](docs/VALIDATION.md)
for results and the physical-device release checklist.
