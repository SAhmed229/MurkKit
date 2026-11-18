#if os(iOS)
import RealityKit
import XCTest
@testable import MurkKit

final class MurkHazeTests: XCTestCase {
    @MainActor
    func testRoomScanStartsWithoutAnEstimateAndResetRestoresOpacity() {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        let haze = MurkHaze.attach(to: view)
        defer { haze.detach() }
        XCTAssertFalse(haze.isScanning)
        XCTAssertEqual(haze.estimate.confidence, .insufficient)
        XCTAssertNil(haze.estimate.extinctionCoefficient)
        let entity = Entity()
        entity.components.set(OpacityComponent(opacity: 0.7))
        haze.track(entity)
        entity.components.set(OpacityComponent(opacity: 0.2))

        haze.reset()

        XCTAssertEqual(entity.components[OpacityComponent.self]?.opacity, 0.7)
        XCTAssertNil(haze.estimate.transmittance(at: 2))
    }

    @MainActor
    func testTrackingIsIdempotentAndRejectsOverlappingHierarchies() {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        let haze = MurkHaze.attach(to: view)
        defer { haze.detach() }
        let parent = Entity()
        let child = Entity()
        parent.addChild(child)

        XCTAssertTrue(haze.track(parent))
        XCTAssertTrue(haze.track(parent))
        XCTAssertFalse(haze.track(child))

        haze.untrack(parent)
        XCTAssertTrue(haze.track(child))
        XCTAssertFalse(haze.track(parent))
    }

    @MainActor
    func testUntrackRestoresOpacitySavedBeforeRepeatedTracking() {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        let haze = MurkHaze.attach(to: view)
        defer { haze.detach() }
        let entity = Entity()
        entity.components.set(OpacityComponent(opacity: 0.4))
        XCTAssertTrue(haze.track(entity))

        // Simulate the controller-owned opacity while the entity is being faded.
        entity.components.set(OpacityComponent(opacity: 0.1))
        XCTAssertTrue(haze.track(entity))
        haze.untrack(entity)

        XCTAssertEqual(entity.components[OpacityComponent.self]?.opacity, 0.4)
    }

    @MainActor
    func testDetachRemovesAddedOpacityAndRejectsFurtherTracking() {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        let haze = MurkHaze.attach(to: view)
        let entity = Entity()
        XCTAssertNil(entity.components[OpacityComponent.self])
        XCTAssertTrue(haze.track(entity))
        entity.components.set(OpacityComponent(opacity: 0.2))

        haze.detach()

        XCTAssertNil(entity.components[OpacityComponent.self])
        XCTAssertFalse(haze.track(entity))
        XCTAssertFalse(haze.isScanning)
        XCTAssertThrowsError(try haze.startScanning()) { error in
            guard case MurkHaze.ScanError.detached = error else {
                return XCTFail("Expected a detached controller error")
            }
        }
        haze.detach() // Repeated cleanup is harmless.
    }
}
#endif
