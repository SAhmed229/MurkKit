import XCTest
@testable import MurkKit

final class RoomHazeEstimatorTests: XCTestCase {
    private func observations(coefficients: [Double] = [0.2, 0.2, 0.2],
                              distances: [Double] = [1, 1.4, 1.8, 2.2],
                              start: Double = 0, noise: [Double] = []) -> [HazeObservation] {
        coefficients.enumerated().flatMap { patch, coefficient in
            distances.enumerated().map { index, distance in
                let intercept = 0.15 + Double(patch) * 0.03
                let perturbation = noise.isEmpty ? 0 : noise[index % noise.count]
                return HazeObservation(patchID: patch,
                    contrast: intercept * exp(-coefficient * distance + perturbation),
                    distance: distance, timestamp: start + Double(index) * 0.2)
            }
        }
    }

    func testRecoversExtinctionWithoutAnyClearAirReference() throws {
        var estimator = RoomHazeEstimator()
        let result = estimator.add(observations(), at: 0.61)
        XCTAssertEqual(result.confidence, .usable)
        XCTAssertEqual(result.patchCount, 3)
        XCTAssertEqual(try XCTUnwrap(result.extinctionCoefficient), 0.2, accuracy: 1e-12)
        XCTAssertEqual(result.maximumDistance, 2.2)
    }

    func testSmallContrastNoiseAndClearRoomRemainUsable() throws {
        var estimator = RoomHazeEstimator()
        let noisy = estimator.add(observations(noise: [0.002, -0.002, 0.001, -0.001]), at: 0.61)
        XCTAssertEqual(noisy.confidence, .usable)
        XCTAssertEqual(try XCTUnwrap(noisy.extinctionCoefficient), 0.2, accuracy: 0.01)
        estimator.reset()
        let clear = estimator.add(observations(coefficients: [0, 0, 0]), at: 0.61)
        XCTAssertEqual(clear.confidence, .usable)
        XCTAssertEqual(try XCTUnwrap(clear.transmittance(at: 2)), 1, accuracy: 1e-12)
    }

    func testInsufficientTravelOrOnlyOnePatchCannotProduceUsableEstimate() {
        var estimator = RoomHazeEstimator()
        XCTAssertEqual(estimator.add(observations(distances: [1, 1, 1, 1]), at: 0.61).confidence, .insufficient)
        estimator.reset()
        XCTAssertEqual(estimator.add(observations(distances: [1, 1.1, 1.2]), at: 0.41).confidence, .insufficient)
        estimator.reset()
        XCTAssertEqual(estimator.add(observations(coefficients: [0.2]), at: 0.61).confidence, .low)
    }

    func testContradictoryPathsAreNotDiscardedToManufactureConsensus() {
        var estimator = RoomHazeEstimator()
        let heterogeneous = estimator.add(observations(coefficients: [0.2, 0.2, 0.2, 0.7]), at: 0.61)
        XCTAssertEqual(heterogeneous.confidence, .low)
        XCTAssertNil(heterogeneous.extinctionCoefficient)
        estimator.reset()
        let backwards = estimator.add(observations(coefficients: [0.2, 0.2, 0.2, -0.2]), at: 0.61)
        XCTAssertEqual(backwards.confidence, .low)
        XCTAssertNil(backwards.transmittance(at: 1))
    }

    func testPoorFitsStayLowConfidence() {
        var estimator = RoomHazeEstimator()
        let result = estimator.add(observations(noise: [0, 0.3, -0.2, 0]), at: 0.61)
        XCTAssertEqual(result.confidence, .low)
    }

    func testFreshnessWindowAndReset() {
        var estimator = RoomHazeEstimator()
        XCTAssertEqual(estimator.add(observations(), at: 0.61).confidence, .usable)
        XCTAssertEqual(estimator.add([], at: 2).confidence, .insufficient)
        XCTAssertEqual(estimator.add([], at: 13).confidence, .insufficient)
        XCTAssertEqual(estimator.retainedObservationCount, 0)
        _ = estimator.add(observations(start: 14), at: 14.61)
        estimator.reset()
        XCTAssertEqual(estimator.retainedPatchCount, 0)
        XCTAssertEqual(estimator.add([], at: 15).confidence, .insufficient)
    }

    func testPausedViewRetainsDistanceHistoryWhileRefreshingFreshness() {
        var estimator = RoomHazeEstimator()
        _ = estimator.add(observations(), at: 0.61)
        for index in 0..<30 {
            let time = 1 + Double(index) * 0.2
            let samples = (0..<3).map { patch in
                HazeObservation(patchID: patch, contrast: (0.15 + Double(patch) * 0.03) * exp(-0.2 * 2.2),
                                distance: 2.2, timestamp: time)
            }
            XCTAssertEqual(estimator.add(samples, at: time).confidence, .usable)
        }
        XCTAssertEqual(estimator.retainedObservationCount, 12)
    }

    func testSlowContinuousWalkAccumulatesEnoughDistanceVariation() throws {
        var estimator = RoomHazeEstimator()
        var estimate = HazeEstimate.unavailable
        for frame in 0...25 {
            let time = Double(frame) * 0.2
            let distance = 1 + Double(frame) * 0.04
            let samples = (0..<3).map { patch in
                HazeObservation(patchID: patch,
                    contrast: (0.15 + Double(patch) * 0.03) * exp(-0.2 * distance),
                    distance: distance, timestamp: time)
            }
            estimate = estimator.add(samples, at: time)
        }
        XCTAssertEqual(estimate.confidence, .usable)
        XCTAssertEqual(try XCTUnwrap(estimate.extinctionCoefficient), 0.2, accuracy: 1e-12)
    }

    func testMemoryIsBoundedAndTimeResetDiscardsOldSamples() {
        var estimator = RoomHazeEstimator()
        for index in 0..<100 {
            let time = Double(index) * 0.1
            let samples = (0..<20).map { patch in
                HazeObservation(patchID: patch, contrast: 0.2,
                                distance: 1 + Double(index % 10) * 0.1, timestamp: time)
            }
            _ = estimator.add(samples, at: time)
        }
        XCTAssertLessThanOrEqual(estimator.retainedPatchCount, 12)
        XCTAssertLessThanOrEqual(estimator.retainedObservationCount, 12 * 24)
        XCTAssertEqual(estimator.add([], at: 0).confidence, .insufficient)
        XCTAssertEqual(estimator.retainedObservationCount, 0)
    }

    func testInvalidObservationsCannotCreateAnEstimate() {
        var estimator = RoomHazeEstimator()
        let invalid = [
            HazeObservation(patchID: 0, contrast: .nan, distance: 1, timestamp: 0),
            HazeObservation(patchID: 1, contrast: 0, distance: 1, timestamp: 0),
            HazeObservation(patchID: 2, contrast: 0.2, distance: .infinity, timestamp: 0),
            HazeObservation(patchID: 3, contrast: 0.2, distance: 1, timestamp: 2),
            HazeObservation(patchID: 4, contrast: 0.2, distance: .greatestFiniteMagnitude, timestamp: 0)
        ]
        XCTAssertEqual(estimator.add(invalid, at: 1), .unavailable)
        XCTAssertEqual(estimator.retainedObservationCount, 0)
        XCTAssertEqual(estimator.add([], at: .nan), .unavailable)
    }
}
