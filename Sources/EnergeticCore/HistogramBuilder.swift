import Foundation

/// Builds orderless histograms from capsule energies (E = digits + 1).
public enum HistogramBuilder {
    /// Energy-weighted histogram (length = bins). Bin index = floor(E) - 1.
    public static func fromEnergies(_ energies: [Float], bins: Int) -> [Float] {
        precondition(bins > 0, "bins must be > 0")
        var histogram = [Float](repeating: 0, count: bins)
        for energy in energies {
            precondition(energy.isFinite, "energy must be finite")
            let idx = Int(floor(energy)) - 1
            precondition(idx >= 0 && idx < bins, "energy out of range for bins")
            histogram[idx] += energy
        }
        return histogram
    }

    /// Int version for exact energies in [1..bins].
    public static func fromEnergies(_ energies: [Int], bins: Int) -> [Float] {
        precondition(bins > 0, "bins must be > 0")
        var histogram = [Float](repeating: 0, count: bins)
        for energy in energies {
            let idx = energy - 1
            precondition(idx >= 0 && idx < bins, "energy out of range for bins")
            histogram[idx] += Float(energy)
        }
        return histogram
    }
}
