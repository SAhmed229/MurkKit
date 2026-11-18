import Foundation

/// Linear-light samples from two adjacent patches on the same reference surface.
struct ContrastSample: Sendable {
    let darkLuminance: Double
    let lightLuminance: Double
    let axialDepth: Double
}

/// A contrast-based estimate for approximately uniform haze in front of a reference.
struct HazeEstimate: Sendable {
    private let referenceDepth: Double
    private let referenceTransmittance: Double

    init?(reference: ContrastSample, current: ContrastSample) {
        let luminances = [
            reference.darkLuminance, reference.lightLuminance,
            current.darkLuminance, current.lightLuminance
        ]
        guard luminances.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              reference.lightLuminance < 0.98,
              current.lightLuminance < 0.98,
              reference.axialDepth.isFinite, reference.axialDepth > 0,
              current.axialDepth.isFinite, current.axialDepth > 0,
              abs(current.axialDepth - reference.axialDepth)
                <= max(0.05, reference.axialDepth * 0.05) else {
            return nil
        }

        let referenceContrast = reference.lightLuminance - reference.darkLuminance
        let currentContrast = current.lightLuminance - current.darkLuminance
        guard referenceContrast >= 0.05, currentContrast >= 0 else {
            return nil
        }

        let ratio = currentContrast / referenceContrast
        guard ratio <= 1.1 else { return nil }

        referenceDepth = reference.axialDepth
        referenceTransmittance = min(ratio, 1)
    }

    /// Queries only the measured depth interval, without extrapolating behind the card.
    func transmittance(atAxialDepth depth: Double) -> Double? {
        guard depth.isFinite, depth >= 0, depth <= referenceDepth else {
            return nil
        }
        guard depth > 0 else { return 1 }
        return pow(referenceTransmittance, depth / referenceDepth)
    }
}
