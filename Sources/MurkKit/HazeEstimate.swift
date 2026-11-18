import Foundation

/// A room-wide estimate under the assumption of steady, approximately uniform haze.
public struct HazeEstimate: Sendable, Equatable {
    public enum Confidence: Sendable, Equatable {
        /// More observations at different distances are needed.
        case insufficient
        /// Some evidence exists, but it is too limited or inconsistent to apply.
        case low
        /// Several independently tracked patches agree within the model's tolerances.
        case usable
    }

    /// Estimated visible-band optical extinction in inverse metres, when usable.
    public let extinctionCoefficient: Double?
    public let confidence: Confidence
    /// Fresh patches with enough distance variation to attempt a fit.
    public let patchCount: Int
    /// Distance supported by every patch contributing to a usable estimate, in metres.
    public let maximumDistance: Double

    static let unavailable = HazeEstimate(
        extinctionCoefficient: nil, confidence: .insufficient, patchCount: 0, maximumDistance: 0
    )

    /// Returns nil for uncertain estimates or distances outside observed coverage.
    public func transmittance(at distance: Double) -> Double? {
        guard confidence == .usable, let coefficient = extinctionCoefficient,
              coefficient.isFinite, coefficient >= 0,
              distance.isFinite, distance >= 0, distance <= maximumDistance else { return nil }
        return exp(-coefficient * distance)
    }
}
