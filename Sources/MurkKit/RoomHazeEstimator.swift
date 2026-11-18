import Foundation

/// Absolute linear-light contrast of the same physical texture at a measured distance.
struct HazeObservation: Sendable {
    let patchID: Int
    let contrast: Double
    let distance: Double
    let timestamp: TimeInterval
}

/// Fits a separate unknown texture intercept per patch; no clear-air sample is needed.
struct RoomHazeEstimator {
    private var histories: [Int: [HazeObservation]] = [:]
    private var lastTime: TimeInterval?

    var retainedPatchCount: Int { histories.count }
    var retainedObservationCount: Int { histories.values.reduce(0) { $0 + $1.count } }

    mutating func reset() {
        histories.removeAll(keepingCapacity: true)
        lastTime = nil
    }

    mutating func add(_ observations: [HazeObservation], at time: TimeInterval) -> HazeEstimate {
        guard time.isFinite, time >= 0 else {
            reset()
            return .unavailable
        }
        if let lastTime, time < lastTime { reset() }
        lastTime = time
        histories = histories.compactMapValues { samples in
            let recent = samples.filter { $0.timestamp >= time - 12 }
            return recent.isEmpty ? nil : recent
        }

        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard observation.contrast.isFinite, observation.contrast > 0, observation.contrast <= 1,
                  observation.distance.isFinite, observation.distance > 0,
                  observation.timestamp.isFinite, observation.timestamp >= time - 12,
                  observation.timestamp <= time else { continue }
            let distanceBin = floor(observation.distance / 0.15)
            guard distanceBin.isFinite else { continue }
            var samples = histories[observation.patchID] ?? []
            if let last = samples.last {
                guard observation.timestamp > last.timestamp else { continue }
            }
            // Fixed bins preserve slow cumulative travel while refreshing stationary views.
            if let sameBin = samples.firstIndex(where: { floor($0.distance / 0.15) == distanceBin }) {
                samples.remove(at: sameBin)
            }
            samples.append(observation)
            histories[observation.patchID] = Array(samples.suffix(24))
        }
        while histories.count > 12 {
            let oldest = histories.min {
                let lhs = $0.value.last!.timestamp
                let rhs = $1.value.last!.timestamp
                return lhs == rhs ? $0.key < $1.key : lhs < rhs
            }!.key
            histories.removeValue(forKey: oldest)
        }

        let candidates = histories.values.filter {
            $0.last!.timestamp >= time - 1 && hasDistanceCoverage($0)
        }
        guard !candidates.isEmpty else { return .unavailable }
        let fits = candidates.compactMap(fit)
        let low = HazeEstimate(extinctionCoefficient: nil, confidence: .low,
                               patchCount: candidates.count, maximumDistance: 0)
        // Contradictory or poorly fitting paths invalidate consensus rather than being hidden.
        guard candidates.count >= 3, fits.count == candidates.count else { return low }
        let coefficients = fits.map(\.coefficient).sorted()
        let middle = coefficients.count / 2
        let coefficient = coefficients.count.isMultiple(of: 2)
            ? (coefficients[middle - 1] + coefficients[middle]) / 2 : coefficients[middle]
        let tolerance = max(0.025, coefficient * 0.3)
        guard coefficients.allSatisfy({ abs($0 - coefficient) <= tolerance }) else { return low }
        return HazeEstimate(extinctionCoefficient: coefficient, confidence: .usable,
                            patchCount: fits.count, maximumDistance: fits.map(\.maximumDistance).min()!)
    }

    private func hasDistanceCoverage(_ samples: [HazeObservation]) -> Bool {
        let distances = samples.map(\.distance).sorted()
        guard distances.count >= 3, distances.last! - distances.first! >= 0.6 - 1e-9 else { return false }
        var distinct = 1
        var previous = distances[0]
        for distance in distances.dropFirst() where distance - previous >= 0.15 {
            distinct += 1
            previous = distance
        }
        return distinct >= 3
    }

    private struct Fit {
        let coefficient: Double
        let maximumDistance: Double
    }

    private func fit(_ samples: [HazeObservation]) -> Fit? {
        let count = Double(samples.count)
        let meanDistance = samples.reduce(0) { $0 + $1.distance } / count
        let meanLogContrast = samples.reduce(0) { $0 + log($1.contrast) } / count
        let variance = samples.reduce(0) { $0 + pow($1.distance - meanDistance, 2) }
        let covariance = samples.reduce(0) {
            $0 + ($1.distance - meanDistance) * (log($1.contrast) - meanLogContrast)
        }
        guard variance.isFinite, variance > 0 else { return nil }
        let slope = covariance / variance
        let coefficient = -slope
        guard coefficient.isFinite, coefficient >= -0.015 else { return nil }
        let squaredError = samples.reduce(0) {
            let residual = log($1.contrast) - meanLogContrast - slope * ($1.distance - meanDistance)
            return $0 + residual * residual
        }
        let rms = sqrt(squaredError / count)
        let slopeError = sqrt(squaredError / (count - 2) / variance)
        guard rms.isFinite, rms <= 0.05,
              slopeError.isFinite, slopeError <= max(0.04, max(0, coefficient) * 0.35) else { return nil }
        return Fit(coefficient: max(0, coefficient), maximumDistance: samples.map(\.distance).max()!)
    }
}
