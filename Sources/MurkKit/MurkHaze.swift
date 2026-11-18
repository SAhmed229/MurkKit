#if os(iOS) && canImport(ARKit)
import ARKit
import Combine
import RealityKit
import UIKit

/// Fades opted-in entities using contrast loss on a stationary reference card.
/// Retain this controller while in use and call `detach()` to release camera settings.
@MainActor
public final class MurkHaze {
    public enum CaptureError: LocalizedError {
        case detached, captureInProgress, sceneDepthUnavailable, cameraUnavailable, invalidReference

        public var errorDescription: String? {
            switch self {
            case .detached:
                return "Attach a new MurkHaze controller before capturing a reference."
            case .captureInProgress:
                return "A clear-air reference capture is already in progress."
            case .sceneDepthUnavailable:
                return "Run a world-tracking AR session with sceneDepth on a LiDAR-equipped device."
            case .cameraUnavailable:
                return "MurkKit could not lock the camera's exposure, white balance, and focus."
            case .invalidReference:
                return "Hold the phone still and center a matte black-left, white-right card in clear air. Check lighting and depth tracking."
            }
        }
    }

    private struct Reference {
        let sample: ContrastSample
        let transform: simd_float4x4
        let orientation: UIInterfaceOrientation
        let viewport: CGSize
    }

    @MainActor
    private final class TrackedEntity {
        weak var entity: Entity?
        let originalOpacity: OpacityComponent?

        init(_ entity: Entity) {
            self.entity = entity
            originalOpacity = entity.components[OpacityComponent.self]
        }

        func restore() {
            guard let entity else { return }
            if let originalOpacity {
                entity.components.set(originalOpacity)
            } else {
                entity.components.remove(OpacityComponent.self)
            }
        }

        func apply(_ transmission: Double) {
            guard let entity else { return }
            entity.components.set(OpacityComponent(
                opacity: (originalOpacity?.opacity ?? 1) * Float(transmission)
            ))
        }
    }

    private weak var view: ARView?
    private let capture = CardCapture()
    private var subscription: (any Cancellable)?
    private var reference: Reference?
    private var entities: [ObjectIdentifier: TrackedEntity] = [:]
    private var capturing = false
    private var detached = false
    private var lastTimestamp: TimeInterval = -.infinity

    /// Attaches without replacing the session delegate or changing its configuration.
    /// Use one controller per ARView. The session must already provide scene depth.
    public static func attach(to view: ARView) -> MurkHaze {
        MurkHaze(view: view)
    }

    private init(view: ARView) {
        self.view = view
        subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.update()
        }
    }

    /// Locks exposure, white balance, and focus, then captures a clear-air reference.
    /// The card must have black on the left and white on the right at screen center.
    /// Keep the camera and card fixed after capture. Recapture after moving either.
    public func captureClearAirReference() async throws {
        guard !detached, let view else { throw CaptureError.detached }
        guard !capturing else { throw CaptureError.captureInProgress }
        capturing = true
        reference = nil
        restoreEntities()
        defer {
            capturing = false
            if reference == nil { capture.restoreCamera() }
        }
        try Task.checkCancellation()
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
              let firstFrame = view.session.currentFrame,
              firstFrame.sceneDepth != nil else {
            throw CaptureError.sceneDepthUnavailable
        }
        do {
            try capture.lockCamera()
        } catch {
            throw CaptureError.cameraUnavailable
        }

        // Let locked camera settings reach a fresh frame; never reuse a pre-lock image.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            guard !detached else { throw CaptureError.detached }
            guard let frame = view.session.currentFrame,
                  frame.timestamp > firstFrame.timestamp + 0.15,
                  ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.3,
                  case .normal = frame.camera.trackingState,
                  capture.cameraIsStable,
                  let orientation = view.window?.windowScene?.interfaceOrientation,
                  let sample = capture.sample(frame: frame, in: view),
                  HazeEstimate(reference: sample, current: sample) != nil else { continue }

            capture.saveLockedSettings()
            guard capture.settingsAreUnchanged else { continue }
            reference = Reference(sample: sample, transform: frame.camera.transform,
                                  orientation: orientation, viewport: view.bounds.size)
            lastTimestamp = -.infinity
            return
        }
        throw CaptureError.invalidReference
    }

    /// Opts an entity and its descendants into fading, preserving its existing opacity.
    /// Returns false for a detached controller or overlapping tracked hierarchies.
    @discardableResult
    public func track(_ entity: Entity) -> Bool {
        guard !detached else { return false }
        entities = entities.filter { $0.value.entity != nil }
        let id = ObjectIdentifier(entity)
        if entities[id] != nil { return true }
        for tracked in entities.values {
            guard let other = tracked.entity else { continue }
            if isAncestor(entity, of: other) || isAncestor(other, of: entity) { return false }
        }
        entities[id] = TrackedEntity(entity)
        return true
    }

    /// Stops fading this entity and restores the opacity it had when tracked.
    public func untrack(_ entity: Entity) {
        entities.removeValue(forKey: ObjectIdentifier(entity))?.restore()
    }

    /// Restores entities and camera modes, then removes the update subscription.
    public func detach() {
        detached = true
        subscription?.cancel()
        subscription = nil
        reference = nil
        restoreEntities()
        entities.removeAll()
        capture.restoreCamera()
    }

    deinit {
        // Cleanup also works when the host releases its controller without detach().
        let capture = capture
        let entities = Array(entities.values)
        let subscription = subscription
        Task { @MainActor in
            subscription?.cancel()
            entities.forEach { $0.restore() }
            capture.restoreCamera()
        }
    }

    private func update() {
        guard let reference, !capturing else { return }
        guard let view, let frame = view.session.currentFrame,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.3,
              case .normal = frame.camera.trackingState,
              view.bounds.size == reference.viewport,
              view.window?.windowScene?.interfaceOrientation == reference.orientation,
              cameraIsNearReference(frame.camera.transform, reference.transform),
              capture.settingsAreUnchanged else {
            restoreEntities()
            return
        }
        // Two tiny image averages at 10 Hz; no volume reconstruction or full-frame copies.
        guard frame.timestamp - lastTimestamp >= 0.1 else { return }
        lastTimestamp = frame.timestamp
        guard let sample = capture.sample(frame: frame, in: view),
              let estimate = HazeEstimate(reference: reference.sample, current: sample) else {
            restoreEntities()
            return
        }

        entities = entities.filter { $0.value.entity != nil }
        for tracked in entities.values {
            guard let entity = tracked.entity else { continue }
            // Reparenting after track() must not apply the same haze twice.
            guard !hasTrackedAncestor(entity) else {
                tracked.restore()
                continue
            }
            let position = entity.position(relativeTo: nil)
            let cameraPosition = frame.camera.transform.inverse * SIMD4<Float>(position, 1)
            guard let projected = view.project(position),
                  referenceRegion(in: view).contains(projected),
                  let transmission = estimate.transmittance(atAxialDepth: Double(-cameraPosition.z)) else {
                tracked.restore()
                continue
            }
            tracked.apply(transmission)
        }
    }

    private func restoreEntities() {
        entities.values.forEach { $0.restore() }
    }

    private func isAncestor(_ ancestor: Entity, of entity: Entity) -> Bool {
        var parent = entity.parent
        while let current = parent {
            if current === ancestor { return true }
            parent = current.parent
        }
        return false
    }

    private func hasTrackedAncestor(_ entity: Entity) -> Bool {
        var parent = entity.parent
        while let current = parent {
            if entities[ObjectIdentifier(current)] != nil { return true }
            parent = current.parent
        }
        return false
    }

    private func referenceRegion(in view: ARView) -> CGRect {
        CGRect(x: view.bounds.width * 0.34, y: view.bounds.height * 0.44,
               width: view.bounds.width * 0.32, height: view.bounds.height * 0.12)
    }

    private func cameraIsNearReference(_ current: simd_float4x4, _ baseline: simd_float4x4) -> Bool {
        let delta = current.columns.3 - baseline.columns.3
        let translation = simd_length(SIMD3<Float>(delta.x, delta.y, delta.z))
        let rotation = simd_quatf(baseline).inverse * simd_quatf(current)
        let angle = min(rotation.angle, 2 * .pi - rotation.angle)
        return translation <= 0.015 && angle <= .pi / 180
    }
}
#endif
