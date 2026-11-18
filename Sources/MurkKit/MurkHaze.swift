#if os(iOS) && canImport(ARKit)
import ARKit
import Combine
import RealityKit
import UIKit

/// Estimates approximately uniform room haze from natural textures at different distances.
/// Retain this controller while scanning, and call `detach()` to restore camera settings.
@MainActor
public final class MurkHaze {
    public enum ScanError: LocalizedError {
        case detached, sceneDepthUnavailable, cameraUnavailable

        public var errorDescription: String? {
            switch self {
            case .detached:
                return "Attach a new MurkHaze controller before starting a scan."
            case .sceneDepthUnavailable:
                return "Run a world-tracking AR session with sceneDepth on a LiDAR-equipped device."
            case .cameraUnavailable:
                return "MurkKit could not lock the camera's exposure and white balance."
            }
        }
    }

    /// Confidence is insufficient until several surface patches support the same estimate.
    public private(set) var estimate: HazeEstimate = .unavailable
    public private(set) var isScanning = false

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
    private let capture = RoomCapture()
    private var estimator = RoomHazeEstimator()
    private var subscription: (any Cancellable)?
    private var entities: [ObjectIdentifier: TrackedEntity] = [:]
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

    /// Starts room scanning with the air as it is. No calibration target or clear-air pass.
    /// Move slowly toward/away from textured, matte surfaces under steady lighting.
    /// Exposure and white balance are held fixed; the host retains focus control.
    public func startScanning() throws {
        guard !detached, let view else { throw ScanError.detached }
        guard !isScanning else { return }
        reset()
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
              view.session.currentFrame?.sceneDepth != nil else {
            throw ScanError.sceneDepthUnavailable
        }
        do {
            try capture.start()
        } catch {
            capture.stop()
            throw ScanError.cameraUnavailable
        }
        isScanning = true
    }

    /// Discards measurements when entering a new room or changing the lighting.
    /// Keeps scanning and restores normal entity opacity until new evidence agrees.
    public func reset() {
        capture.reset()
        estimator.reset()
        estimate = .unavailable
        lastTimestamp = -.infinity
        restoreEntities()
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
        isScanning = false
        estimate = .unavailable
        estimator.reset()
        restoreEntities()
        entities.removeAll()
        capture.stop()
    }

    deinit {
        // Cleanup also works when the host releases its controller without detach().
        let capture = capture
        let entities = Array(entities.values)
        let subscription = subscription
        Task { @MainActor in
            subscription?.cancel()
            entities.forEach { $0.restore() }
            capture.stop()
        }
    }

    private func update() {
        guard isScanning else { return }
        guard let view, let frame = view.session.currentFrame,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.3,
              case .normal = frame.camera.trackingState else {
            reset()
            return
        }
        // Bound capture work to five observations/second, independently of rendering.
        guard frame.timestamp - lastTimestamp >= 0.2 else { return }
        lastTimestamp = frame.timestamp
        guard let observations = capture.observations(frame: frame) else {
            estimator.reset()
            estimate = .unavailable
            restoreEntities()
            return
        }
        let updated = estimator.add(observations, at: frame.timestamp)
        // Unobserved or refocusing frames never hold a previous fade on screen.
        estimate = observations.isEmpty ? .unavailable : updated
        guard estimate.confidence == .usable else {
            restoreEntities()
            return
        }

        entities = entities.filter { $0.value.entity != nil }
        let camera = frame.camera.transform.columns.3
        let cameraOrigin = SIMD3<Float>(camera.x, camera.y, camera.z)
        for tracked in entities.values {
            guard let entity = tracked.entity else { continue }
            // Reparenting after track() must not apply the same haze twice.
            guard !hasTrackedAncestor(entity) else {
                tracked.restore()
                continue
            }
            let position = entity.position(relativeTo: nil)
            let cameraPosition = frame.camera.transform.inverse * SIMD4<Float>(position, 1)
            let distance = Double(simd_distance(cameraOrigin, position))
            guard cameraPosition.z < 0,
                  let projected = view.project(position), view.bounds.contains(projected),
                  let transmission = estimate.transmittance(at: distance) else {
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

}
#endif
