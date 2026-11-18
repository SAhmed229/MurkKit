import XCTest
@testable import MurkKit

final class HazeEstimateTests: XCTestCase {
    private let clear = ContrastSample(darkLuminance: 0.1, lightLuminance: 0.6, axialDepth: 4)
    private let hazy = ContrastSample(darkLuminance: 0.2, lightLuminance: 0.52, axialDepth: 4)

    func testTransmissionScalesWithObjectDepth() throws {
        let estimate = try XCTUnwrap(HazeEstimate(reference: clear, current: hazy))
        XCTAssertEqual(try XCTUnwrap(estimate.transmittance(atAxialDepth: 4)), 0.64, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(estimate.transmittance(atAxialDepth: 2)), 0.8, accuracy: 1e-12)
        XCTAssertEqual(estimate.transmittance(atAxialDepth: 0), 1)
        // Repeated updates use an absolute transmission, not compounded attenuation.
        XCTAssertEqual(try XCTUnwrap(estimate.transmittance(atAxialDepth: 2)), 0.8, accuracy: 1e-12)
    }

    func testZeroContrastRetainsZeroLengthPath() throws {
        let obscured = ContrastSample(darkLuminance: 0.4, lightLuminance: 0.4, axialDepth: 4)
        let estimate = try XCTUnwrap(HazeEstimate(reference: clear, current: obscured))
        XCTAssertEqual(estimate.transmittance(atAxialDepth: 2), 0)
        XCTAssertEqual(estimate.transmittance(atAxialDepth: 0), 1)
    }

    func testQueriesOutsideMeasuredDepthAreInvalid() throws {
        let estimate = try XCTUnwrap(HazeEstimate(reference: clear, current: hazy))
        XCTAssertNil(estimate.transmittance(atAxialDepth: -0.1))
        XCTAssertNil(estimate.transmittance(atAxialDepth: 4.1))
        XCTAssertNil(estimate.transmittance(atAxialDepth: .nan))
        XCTAssertNil(estimate.transmittance(atAxialDepth: .infinity))
    }

    func testNearClearNoiseClampsButLightingIncreaseIsInvalid() throws {
        let noisy = ContrastSample(darkLuminance: 0.1, lightLuminance: 0.625, axialDepth: 4)
        let estimate = try XCTUnwrap(HazeEstimate(reference: clear, current: noisy))
        XCTAssertEqual(estimate.transmittance(atAxialDepth: 2), 1)

        let brighter = ContrastSample(darkLuminance: 0.1, lightLuminance: 0.7, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: clear, current: brighter))
    }

    func testLowReferenceContrastAndReversedPatchesAreInvalid() {
        let flat = ContrastSample(darkLuminance: 0.4, lightLuminance: 0.44, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: flat, current: hazy))

        let reversed = ContrastSample(darkLuminance: 0.6, lightLuminance: 0.2, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: clear, current: reversed))
    }

    func testSaturatedReferenceOrCurrentPatchIsInvalid() {
        let saturated = ContrastSample(darkLuminance: 0.1, lightLuminance: 0.98, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: saturated, current: hazy))
        XCTAssertNil(HazeEstimate(reference: clear, current: saturated))
    }

    func testInvalidLuminanceIsRejected() {
        let negative = ContrastSample(darkLuminance: -0.1, lightLuminance: 0.6, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: negative, current: hazy))

        let nonfinite = ContrastSample(darkLuminance: 0.2, lightLuminance: .nan, axialDepth: 4)
        XCTAssertNil(HazeEstimate(reference: clear, current: nonfinite))
    }

    func testInvalidOrMismatchedDepthIsRejected() throws {
        let zero = ContrastSample(darkLuminance: 0.1, lightLuminance: 0.6, axialDepth: 0)
        XCTAssertNil(HazeEstimate(reference: zero, current: hazy))

        let nonfinite = ContrastSample(darkLuminance: 0.2, lightLuminance: 0.52, axialDepth: .infinity)
        XCTAssertNil(HazeEstimate(reference: clear, current: nonfinite))

        let moved = ContrastSample(darkLuminance: 0.2, lightLuminance: 0.52, axialDepth: 4.3)
        XCTAssertNil(HazeEstimate(reference: clear, current: moved))

        let nearby = ContrastSample(darkLuminance: 0.2, lightLuminance: 0.52, axialDepth: 4.1)
        XCTAssertNotNil(HazeEstimate(reference: clear, current: nearby))
    }
}
