# Implementation increments

## 001 — Reference-card haze occlusion

**Date:** 2026-11-18

**Outcome:** a dependency-free Swift package with a small RealityKit integration for one fade value per entity, measured against a stationary black-and-white reference card.

```swift
let haze = MurkHaze.attach(to: arView)
try await haze.captureClearAirReference()
haze.track(virtualObject)
```

The app retains the controller and calls `detach()` when leaving the experience. `untrack(_:)` restores one entity. The existing AR view must run world tracking with `.sceneDepth`; the controller does not replace its delegate or restart its session.

### Scope

- One `MurkKit` library target, three source files, and no third-party dependencies.
- iOS/iPadOS 18+ for RealityKit's `OpacityComponent`.
- Two small, fixed camera patches, sampled in linear RGB with a reused Core Image context.
- High-confidence LiDAR depth on both card halves, with matching surface depths.
- Exposure, white balance, and focus locked for the reference and observation, with the prior modes restored on cleanup when still owned by MurkKit.
- Contrast-ratio transmission, scaled to the object's axial depth and multiplied by its saved opacity.
- Updates at approximately 10 Hz, with no full-frame CPU image copies.
- Normal-opacity fallback for stale frames, poor tracking/depth, changed camera settings, camera movement, saturation, invalid contrast, or objects outside the reference region/depth.
- Idempotent tracking, hierarchy overlap protection, and restoration on untrack, detach, failed recapture, or controller release.

This increment deliberately excludes 3D smoke reconstruction, per-pixel compositing, volumetric lighting, fluid simulation, Vision Pro streaming, sensor benchmarks, and extra module scaffolding.

### Measurement

```text
T_card   = (light_now − dark_now) / (light_clear − dark_clear)
T_object = T_card ^ (object_axial_depth / card_axial_depth)
opacity  = original_opacity × T_object
```

For example, 64% transmission to a card at 4 m gives 80% transmission to an object at 2 m under the uniform-medium assumption. Queries beyond the card are rejected. ARKit scene depth is axial distance from the camera plane; the object's depth uses the same convention.

This is a controlled, fixed-view experiment. Keep the card and lighting stable. A single background observation cannot distinguish smoke in front of an object from smoke behind it; put the demo object close to the card. Camera processing can still affect contrast even with exposure locked, so the estimate is not calibrated volumetric reconstruction.

### Verification

- **Passed:** eight host tests for the numerical example, invalid/low-contrast/saturated inputs, depth mismatch, clear-air noise, and bounded depth queries.
- **Passed:** complete Swift package build for the arm64 iOS Simulator SDK, targeting iOS 18, with warnings treated as errors.
- **Passed:** iOS typechecking of all test sources, including three RealityKit tracking/cleanup tests, with warnings treated as errors. Those three tests were not executed because this environment has no usable iOS Simulator runtime.
- **Device verification:** not performed. A real-device smoke experiment is required to validate camera-to-opacity behavior; automated arithmetic tests cannot establish capture accuracy.

Run the portable tests with `swift test`. If a restricted environment prevents SwiftPM's nested manifest sandbox from starting, use `swift test --disable-sandbox`. Run the iOS tests from Xcode's `MurkKit` package scheme on an available iOS simulator or device.

### Device acceptance check

1. Run an AR view with scene depth on a LiDAR-equipped iPhone/iPad. Keep it fixed and let tracking settle.
2. Fill the two sampling regions described in the README with the matte card's black and white halves. Capture the clear-air reference.
3. Track a small entity just in front of the card; verify its clear-air opacity is preserved.
4. Introduce light, approximately uniform haze. Verify fading follows contrast loss and does not accumulate with each frame.
5. Move the phone or obscure the card with a nearer object; verify an unreliable observation restores the original opacity. Recapture after changing the setup.
6. Untrack/detach and verify entity opacity and the camera's previous exposure, white-balance, and focus modes are restored.

The next decision comes from this device check: improve the reference-card capture only where observed failures justify it before adding a broader feature.
