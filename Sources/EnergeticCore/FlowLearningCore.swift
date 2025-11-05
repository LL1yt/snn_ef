import Foundation

// MARK: - Completion Aggregator

/// Smart weighted aggregator for particle completions
public enum CompletionAggregator {
    /// Computes weighted per-bin estimates from completions.
    /// Returns yHat[b] for each bin, where multiple completions in the same bin are averaged with smart weights.
    public static func aggregate(
        completions: [CompletionEvent],
        targets: [Float]?,
        config: AggregatorConfig,
        bins: Int
    ) -> [Float] {
        var yHat = [Float](repeating: 0, count: bins)
        var binWeights = [Float](repeating: 0, count: bins)

        let eps: Float = 1e-8

        // Find max energy for normalization if no targets provided
        let maxE = completions.map { $0.energy }.max() ?? 1.0

        for comp in completions {
            let b = comp.binIndex
            guard b >= 0 && b < bins else { continue }

            // Distance weight: exp(-|r - R| / sigma_r)
            let r = length(comp.position)
            let rDist = abs(r - config.radius)
            let wDist = exp(-rDist / config.sigmaR)

            // Energy weight
            let wEnergy: Float
            if let targets = targets, targets.count == bins {
                let eDist = abs(comp.energy - targets[b])
                wEnergy = exp(-eDist / config.sigmaE)
            } else {
                // Fallback: magnitude proxy
                wEnergy = comp.energy / (maxE + eps)
            }

            // Alignment weight (optional, uses initialBinIndex if available)
            let wAlign: Float
            if let initialBin = comp.initialBinIndex {
                let angDist = angularDistance(from: initialBin, to: b, bins: bins)
                wAlign = exp(-angDist / config.tau)
            } else {
                wAlign = 1.0
            }

            // Combine weights with exponents
            let w = pow(wDist, config.alpha) * pow(wEnergy, config.beta) * pow(wAlign, config.gamma)

            yHat[b] += w * comp.energy
            binWeights[b] += w
        }

        // Normalize by total weight per bin
        for b in 0..<bins {
            if binWeights[b] > eps {
                yHat[b] /= binWeights[b]
            }
        }

        return yHat
    }

    /// Angular distance between two bin indices on a circle
    private static func angularDistance(from: Int, to: Int, bins: Int) -> Float {
        let diff = abs(from - to)
        let wrapped = min(diff, bins - diff)
        return Float(wrapped) / Float(bins) * (2 * .pi)
    }
}

// MARK: - Loss Functions

public enum LossFunctions {
    /// Bin loss: sum_b (yHat[b] - T[b])^2 + lambda_g * ||g||_2^2
    public static func binLoss(yHat: [Float], target: [Float], gains: [Float], lambdaG: Float = 0.01) -> Float {
        let bins = yHat.count
        var loss: Float = 0

        for b in 0..<bins {
            let diff = yHat[b] - target[b]
            loss += diff * diff
        }

        // L2 regularization on gains
        var regTerm: Float = 0
        for g in gains {
            regTerm += g * g
        }

        return loss + lambdaG * regTerm
    }

    /// Spike rate loss: (r_obs - r_tgt)^2
    public static func spikeRateLoss(observed: Float, target: Float) -> Float {
        let diff = observed - target
        return diff * diff
    }

    /// Boundary loss: mean_j max(0, |r_j - R| - eps)
    public static func boundaryLoss(completions: [CompletionEvent], radius: Float, eps: Float = 0.01) -> Float {
        guard !completions.isEmpty else { return 0 }

        var sum: Float = 0
        for comp in completions {
            let r = length(comp.position)
            let miss = abs(r - radius) - eps
            sum += max(0, miss)
        }

        return sum / Float(completions.count)
    }

    /// Total loss: L = L_bins + w_spike * L_spike + w_boundary * L_boundary
    public static func totalLoss(
        binLoss: Float,
        spikeLoss: Float,
        boundaryLoss: Float,
        spikeWeight: Float,
        boundaryWeight: Float
    ) -> Float {
        return binLoss + spikeWeight * spikeLoss + boundaryWeight * boundaryLoss
    }
}

// MARK: - Parameter Updates

public enum ParameterUpdater {
    /// Update per-bin gains
    public static func updateGains(
        gains: inout [Float],
        yHat: [Float],
        target: [Float],
        learningRate: Float,
        bounds: (min: Float, max: Float)
    ) {
        let bins = gains.count
        for b in 0..<bins {
            let gradient = 2 * (yHat[b] - target[b])
            gains[b] -= learningRate * gradient
            gains[b] = clamp(gains[b], min: bounds.min, max: bounds.max)
        }
    }

    /// Update LIF threshold based on spike rate
    public static func updateLifThreshold(
        threshold: inout Float,
        observedRate: Float,
        targetRate: Float,
        learningRate: Float,
        bounds: (min: Float, max: Float),
        margin: Float = 0.02
    ) {
        if observedRate > targetRate + margin {
            // Too many spikes, increase threshold
            threshold += learningRate
        } else if observedRate < targetRate - margin {
            // Too few spikes, decrease threshold
            threshold -= learningRate
        }
        threshold = clamp(threshold, min: bounds.min, max: bounds.max)
    }

    /// Update radial bias based on boundary completion
    public static func updateRadialBias(
        radialBias: inout Float,
        completionRate: Float,
        meanRadialMiss: Float,
        learningRate: Float,
        bounds: (min: Float, max: Float),
        targetCompletionRate: Float = 0.9,
        missThreshold: Float = 0.1
    ) {
        if completionRate < targetCompletionRate || meanRadialMiss > missThreshold {
            // Increase outward bias to help particles reach boundary
            radialBias += learningRate
        } else if completionRate > 0.98 && meanRadialMiss < 0.05 {
            // Too aggressive, decrease slightly
            radialBias -= learningRate * 0.5
        }
        radialBias = clamp(radialBias, min: bounds.min, max: bounds.max)
    }

    /// Update spike kick magnitude based on boundary miss
    public static func updateSpikeKick(
        spikeKick: inout Float,
        meanRadialMiss: Float,
        binLossTrend: Float,
        learningRate: Float,
        bounds: (min: Float, max: Float)
    ) {
        if meanRadialMiss > 0.1 {
            // Particles not reaching boundary, increase kick
            spikeKick += learningRate
        } else if binLossTrend > 0 && meanRadialMiss < 0.05 {
            // Overshoot degrading bin match, decrease
            spikeKick -= learningRate * 0.5
        }
        spikeKick = clamp(spikeKick, min: bounds.min, max: bounds.max)
    }
}

// MARK: - Utilities

@inline(__always)
private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.min(Swift.max(value, min), max)
}
