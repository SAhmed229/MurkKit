import XCTest
@testable import MurkKit

final class HazeEstimateTests: XCTestCase {
    func testUsableTransmissionAndObservedDistanceBounds() throws {
        let estimate = HazeEstimate(extinctionCoefficient: 0.2, confidence: .usable,
                                    patchCount: 3, maximumDistance: 4)
        XCTAssertEqual(try XCTUnwrap(estimate.transmittance(at: 2)), exp(-0.4), accuracy: 1e-12)
        XCTAssertEqual(estimate.transmittance(at: 0), 1)
        XCTAssertNotNil(estimate.transmittance(at: 4))
        XCTAssertNil(estimate.transmittance(at: 4.1))
        XCTAssertNil(estimate.transmittance(at: -1))
        XCTAssertNil(estimate.transmittance(at: .nan))
        XCTAssertNil(estimate.transmittance(at: .infinity))
    }

    func testUncertainOrInvalidCoefficientsDoNotFade() {
        XCTAssertNil(HazeEstimate.unavailable.transmittance(at: 1))
        let low = HazeEstimate(extinctionCoefficient: 0.2, confidence: .low,
                              patchCount: 2, maximumDistance: 4)
        XCTAssertNil(low.transmittance(at: 1))
        for coefficient in [Double.nan, .infinity, -0.1] {
            let invalid = HazeEstimate(extinctionCoefficient: coefficient, confidence: .usable,
                                       patchCount: 3, maximumDistance: 4)
            XCTAssertNil(invalid.transmittance(at: 1))
        }
    }
}
