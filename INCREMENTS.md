# Implementation increments

## 002 — Live room scanning

**Date:** 2026-11-18

**Outcome:** estimate approximately uniform haze while moving through a room that is already hazy. The app uses natural surface textures at several distances, without a physical card or clear-air scan.

```swift
let haze = MurkHaze.attach(to: arView)
try haze.startScanning()
haze.track(virtualObject)

let estimate = haze.estimate
let transmission = estimate.transmittance(at: 2.0)
```

Retain the controller, run the host AR session with `.sceneDepth`, and start after the view is tracking normally. `reset()` clears the measurements when entering a new area; `untrack(_:)` and `detach()` restore original entity opacity. The controller leaves the session delegate and configuration alone.

### Scope

- One Swift package with no third-party dependencies, cloud requests, or trained model.
- A bounded set of world-anchored, approximately planar texture patches, reprojected and sampled over the same physical footprint as the phone moves.
- Linear-light contrast observations with depth, correspondence, viewing-angle, camera-setting, and focus checks.
- Exposure and white balance held steady; autofocus remains under the host's control.
- Separate contrast-distance fits for patches with unknown starting contrasts, followed by agreement and freshness checks.
- One effective extinction coefficient and confidence level for the observed area. Only usable estimates affect RealityKit opacity.
- Freshness expiry, bounded observation history, finite distance queries, and normal-opacity fallback.
- No fixed-camera tolerance, physical target, clear-air capture method, or card-based estimator remains.

This increment does not add voxel reconstruction, individual plume localization, fluid simulation, volumetric lighting, Vision Pro sync, or a new dependency/module framework.

### Measurement and confidence

```text
ln(contrast_patch) = unknown_patch_intercept − extinction × distance
transmission(distance) = exp(−extinction × distance)
entity_opacity = original_opacity × transmission
```

Distance is Euclidean camera-to-surface distance. Measurements must revisit the same physical texture across enough distance; merely collecting many frames from one position is insufficient. At least three fresh, agreeing patches are needed before an estimate becomes usable. Histories expire rather than preserving an old room value indefinitely.

`.insufficient` means more useful observations are needed. `.low` means the available fits are unsuitable or inconsistent. `.usable` means the internal model checks pass; it is not a calibrated accuracy guarantee. Queries outside the supported distance limit or without usable confidence return `nil`.

The model assumes roughly homogeneous, steady haze, stable lighting, and matte surfaces. Shadows, reflections, motion blur, changing camera processing, or changing smoke can still resemble contrast loss. The estimate is not a 3D haze-density map. The near/far principle is supported by [Du et al.](https://amt.copernicus.org/articles/6/2121/2013/); this indoor iPhone implementation requires its own device validation.

### Verification

- **Passed:** 12 portable tests, including recovery with unknown texture contrasts and no clear-air sample, gradual 5 Hz walking, stationary-view retention, inconsistent paths, stale data, invalid inputs, bounded storage, and transmission query limits.
- **Passed:** complete package build for the arm64 iOS Simulator SDK with an iOS 18 deployment target and warnings treated as errors.
- **Passed:** iOS typechecking of all test sources, including four RealityKit lifecycle tests, with warnings treated as errors. Runtime execution of those four tests remains unavailable because no usable iOS Simulator runtime is installed here.
- **Passed:** a synthetic Core Image check of the patch-sampling function across four rotations and a 2× footprint size change recovered imposed transmission 0.8 as approximately 0.803, with texture correlation approximately 0.99995.
- **Device verification:** not performed. Physical-room optical accuracy, autofocus availability, power use, and live capture performance require a LiDAR-equipped iPhone/iPad.

Run portable estimator tests with `swift test` (`--disable-sandbox` if the environment cannot run SwiftPM's nested sandbox). The RealityKit lifecycle tests require an iOS simulator or device. A real-device walk-through is necessary to evaluate optical accuracy and performance.

### Device acceptance check

1. Start in an already hazy room with steady lighting and visible, textured matte surfaces. No clean-room scan is needed.
2. Run the host AR session with scene depth, attach MurkKit, start scanning, and track a small virtual entity.
3. Walk slowly toward and away from the same textures, changing distance by at least about 0.6 m while keeping them in view. Confirm that confidence stays insufficient while there is too little travel or too few usable patches.
4. Once several patches agree, inspect the coefficient and transmission and confirm that the virtual entity fades according to its distance without repeated opacity multiplication.
5. Turn toward a featureless surface, interrupt tracking, or let observations become stale. Confirm opacity returns to the original value rather than holding a previous fade.
6. Repeat in clear air and under deliberately changed lighting to characterize false haze estimates; do not treat agreement alone as proof of physical accuracy.
7. Call `reset()` in a new area, then `detach()` on exit. Confirm histories clear, opacity restores, and prior exposure/white-balance modes return.

## 001 — Initial opacity integration (superseded)

Introduced the Swift package, per-entity opacity handling, and cleanup behavior. Its physical-card capture and clear-air-reference API were removed in Increment 002. The original implementation remains available in Git history at `694e337`.
