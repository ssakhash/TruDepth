# Upgrade Validation

## Automated Results (2026-10-23)

- Xcode 27.1 / iPhoneOS 27.1 SDK, deployment target iOS 17.0.
- iPhone Debug, optimized iPhone Release, and simulator Debug builds succeeded with Swift 6 and complete
  strict-concurrency checking. Initial validation builds disabled signing;
  subsequent Debug builds were signed and installed in place on the physical
  iPhone 18 Pro for the rendering and room-save fixes.
- The missing Metal toolchain was installed successfully. The heatmap shader is
  compiled into both targets; full builds are no longer blocked by that component.
- 28 Swift Testing tests pass via the macOS core package. These exercise actual
  shared app storage, geometry, Model I/O, GLB and depth implementations.
- Tests cover relaunch persistence, failed asset/manifest writes, failed deletion,
  interrupted deletion/source removal, source-removal rollback, corrupt indexes,
  migration retries/identity, missing models, cancellation after commit, path
  traversal, crop rotation/boundaries, packed/padded vertex strides, invalid
  indices, tracked viewpoints, model transforms, texture channels, depth
  calibration/confidence/color, malformed depth, portrait orientation, room
  archive serialization/fallback/retry, and preservation of failure details.
- Khronos glTF validator: both the original textured GLB fixture and the
  USDZ-to-GLB roundtrip have **0 errors and 0 warnings**. Each has one informational
  unused-UV message for its untextured fixture mesh.
- Three.js independently reads OBJ and PLY fixtures. Checks verify meter scale,
  mesh count, normals, UVs, MTL texture paths, calibrated points, confidence
  filtering and RGB correspondence.
- The app installs and launches on the iPhone 18 Pro / iOS 27 simulator. The home
  screen was visually inspected. This is a launch smoke check, not a completed
  interactive UI or sensor test.
- Apple's native USDZ packager emits redacted asset-localization diagnostics for
  synthetic texture fixtures. Roundtrip tests verify embedded image dimensions,
  four distinct fixture colors, geometry bounds and PBR texture channels despite
  those diagnostics. Quick Look and Blender visual review remain required.

## Release Gate: Physical Devices

One room capture and finalized model have now been verified on the physical
iPhone 18 Pro. Its raw RoomPlan archive was rejected, but processed room JSON,
USDZ and thumbnail were saved. Complete capture/export/lifecycle coverage and
iPhone 14 Pro Max regression testing remain release gates.
Do not infer capture quality or sustained performance from simulator success.

1. On both phones, deny camera permission, then allow it in Settings. Verify all
   capture screens recover and Main Menu always releases the camera. Repeat
   start/cancel, back swipe, background/foreground, locking and interruptions.
2. Scan a known-size object without moving it. Reposition/rotate the crop and
   verify surrounding floor/table changes do not alter exported bounds. Ensure
   fewer than four tracked viewpoint sectors cannot complete. Inspect warnings
   for a small object touching only one crop face.
3. Run detailed capture offline, multiple passes and a flip. Reach the image
   limit, finish, cancel reconstruction, relaunch, and retry using retained
   photographs/checkpoints. Check low-light and tracking guidance.
4. Scan multiple connected rooms without resetting the session. Verify each room
   survives an interrupted finalization. After tracking loss/backgrounding or
   relaunch, adding rooms must be blocked while finalizing retained rooms works.
   Check combined and individual exports align in meters.
5. Take depth snapshots in live mode and during RoomPlan capture. Compare PNG
   orientation to the heatmap, colored PLY to the camera frame, and raw metadata
   to the captured frame. No post-scan camera restart should occur.
6. Export GLB, OBJ folder, USDZ, PLY, PNG and raw folders through Files. Test local
   Files and a chosen provider, cancel the picker, and swipe-dismiss it. Confirm
   stored originals remain unchanged and survive relaunch.
7. Remove source data from a completed item/room scan. Confirm model textures and
   exports remain intact, rebuilding/individual-room export is unavailable, and
   storage totals decrease. Delete the project and verify all assets disappear.
8. Open GLB/OBJ in Blender, USDZ in Quick Look, and PLY in another point-cloud
   application. Check asymmetric textured fixtures for orientation, scale, UVs,
   normals and multiple materials. Blender is not installed on this development
   machine; the independent automated readers do not replace visual inspection.
9. Profile with Instruments under nominal/serious thermal state and Low Power
   Mode. Measure camera/UI frame times, main-thread stalls, GPU in-flight memory,
   peak reconstruction/export memory, battery use and repeated-session leaks.
   ProMotion is enabled, but no sustained frame-rate claim has been measured.
10. Configure the Start Scan App Shortcut on the Action button. Confirm it opens
    the item chooser without starting camera capture before permission/selection.

An iOS 17 simulator runtime is not installed locally. iOS 17 deployment builds
compile, but iOS 17 UI/runtime regression coverage is still a release gate.
Filesystem failure tests inject out-of-space errors before durable writes;
physical low-storage behavior and provider failures also require device testing.

## iPhone 18 Pro Capture Freeze Investigation

A device log records repeated `CAMetalLayer nextDrawable`
allocation failures, a gesture timeout, and then a Metal validation assertion in
`realitykit::fsSurfacePbr`: 2D textures are bound where `tonemapLUT` and
`ispTonemapLUT` expect 1D textures. The failing function belongs to RealityKit,
not the app's depth shader. The earlier PointerUI message does not establish the
cause. The log does not distinguish allocation pressure from a framework or
validation compatibility defect.

The connected physical iPhone was identified as iPhone 18 Pro on iOS 27.0.1;
the development toolchain is Xcode 27.1. A targeted backtrace attempt was blocked
by the phone being locked. A newly signed device build succeeds, and the 20
shared-core tests still pass; these checks do not prove the freeze is fixed.

The mitigation uses public APIs only:

- Disable HDR post-processing in app-owned RealityKit views. Apple's
  [render option](https://developer.apple.com/documentation/realitykit/arview/renderoptions-swift.struct/disablehdr)
  controls HDR/tone mapping, but whether it avoids this specific assertion needs
  a physical-device retest.
- Replace the quick-scan PBR crop box with an unlit outline; source geometry and
  exported materials are unchanged.
- Turn off RoomPlan's optional miniature model with
  [isModelEnabled](https://developer.apple.com/documentation/roomplan/roomcaptureview/ismodelenabled),
  and decline its automatic result presentation because TruDepth already owns
  reconstruction and the result screen. Native capture guidance remains enabled.
- Create the room capture view after Start/permission and release it on exit.

No private framework properties are modified and Metal API validation has not
been disabled. RoomPlan and guided ObjectCapture own internal rendering paths;
the app-owned HDR setting does not configure those internal renderers.

Retest room capture and quick item capture separately, including crop placement,
Finish, Main Menu, and repeated entry. Keep Metal API validation enabled for this
test. If Xcode stops on the same assertion, capture the stopped thread stack and
compare a launch from the Home Screen without a debugger. A successful standalone
launch only narrows the diagnosis; it is not evidence that the validated path is
correct. Preserve saved scans: update the app in place rather than uninstalling it.

## Room Save Format Error

On the physical iPhone, a format error was reported immediately after
Finish Room. The affected project contained a manifest but no source files;
the original encoding error details were not retained, so the exact offending
value is not established. A later history retry recorded missing source data.
That older empty draft cannot be rebuilt from disk.

Room archives now use a matched JSON encoding/decoding policy for IEEE 754
exceptional values, while retaining compatibility with existing ordinary JSON.
Foundation's default JSON encoder throws for these values; see
[Apple's encoding strategy documentation](https://developer.apple.com/documentation/foundation/jsonencoder/nonconformingfloatencodingstrategy-swift.enum).
This policy is limited to RoomPlan archives: exported mesh validation still
rejects non-finite geometry. A subsequent device retest reported an encoding
error with an empty coding path and the description `Invalid data`, even with
the exceptional-number policy enabled. Non-finite JSON values therefore do not
explain the remaining raw-archive rejection. The evidence identifies the raw
encoder boundary, not the framework's internal reason for rejecting the data.

A raw archive failure no longer prevents reconstruction and saving the processed
room. If both fail, the capture remains in memory for Retry Room Save while the
screen stays open. Main Menu asks for confirmation before discarding unsaved
room data. Failures identify the save/reconstruction stage and include encoding
details or an NSError domain/code. Retained raw/processed room JSON is decoded
using the same policy for project recovery and individual-room exports.

Regression coverage includes exceptional-value round trips, legacy JSON,
processed-room fallback after raw encoding failure, reconstruction failure with
retained inputs, disk-full retry preserving earlier rooms, cancellation, and
failure diagnostics surviving navigation/rename/relaunch.
These tests use Codable fixtures, not a synthetic RoomPlan capture.

The subsequent physical-device project contains `Sources/room-001.json`, a
completed `model.usdz`, and its thumbnail; the manifest state is `ready`.
The actual saved USDZ was copied locally (not uploaded) and converted through
the shared app codec into OBJ and GLB. OBJ reimport preserves the bounds within
1 mm; Three.js independently verifies 230 triangles, normals and meter-scale
bounds. The GLB passes Khronos validation with zero errors and warnings. These
Mac-side checks do not substitute for testing the iPhone Files picker.

Raw-archive limitations now have their own optional `sourceWarnings` manifest
field, separate from a failed capture or processing operation. They survive
finalization/rebuild/rename/relaunch, appear in source details, and accompany
source-folder exports. Older processed-only projects infer the limitation from
their retained files without changing their ID, date, model or ready state.
New captures still attempt raw serialization. If it fails but processed-room
storage succeeds, the UI shows a non-blocking source notice instead of an error
alert; it does not claim that raw data was recovered. Removing source data clears
the notice along with the sources, never the model. Additional tests cover these
transitions. Raw archive capture, multi-room assembly and on-phone exports still
require physical-device validation.

## Reproduce

See README for build/test commands. Fixtures are generated by `swift test` under
`/private/tmp/TruDepth-fixtures`, with external validation in
`Scripts/validate-exports.mjs`. Temporary validator dependencies are not shipped
with the app. Normal backup eligibility is preserved; there is no app cloud sync
or server reconstruction pipeline.
