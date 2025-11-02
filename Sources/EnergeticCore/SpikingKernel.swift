import Foundation
import Accelerate

/// Spiking neural kernel implementing membrane dynamics and spike generation.
/// Shared across all packets; stateless except for learnable parameters.
public struct SpikingKernel: Sendable {
    
    // MARK: - Parameters
    
    /// Total number of trainable parameters
    public let parameterCount: Int
    
    /// Hidden dimension (derived from parameter_count)
    private let hiddenDim: Int
    
    /// Input weights W_in [hiddenDim × 4]
    public var wIn: [Float]
    
    /// Input bias b_in [hiddenDim]
    public var bIn: [Float]
    
    /// Energy output weights W_energy [1 × hiddenDim]
    public var wEnergy: [Float]
    
    /// Energy output bias b_energy [1]
    public var bEnergy: Float
    
    /// Delta XY output weights W_delta [2 × hiddenDim]
    public var wDelta: [Float]
    
    /// Delta XY output bias b_delta [2]
    public var bDelta: SIMD2<Float>
    
    // MARK: - SNN Parameters
    
    /// Membrane potential decay factor, (0, 1)
    public let decay: Float
    
    /// Spike threshold, (0, 1]
    public let threshold: Float
    
    /// Reset value after spike
    public let resetValue: Float
    
    /// Surrogate activation function
    public let surrogate: SurrogateActivation
    
    // MARK: - Initialization
    
    /// Creates a SpikingKernel with deterministic initialization.
    ///
    /// - Parameters:
    ///   - config: SNN configuration from RouterConfig
    /// - Throws: `RouterError.invalidConfiguration` if parameters invalid
    public init(config: SNNConfig) throws {
        self.parameterCount = config.parameterCount
        self.decay = config.decay
        self.threshold = config.threshold
        self.resetValue = config.resetValue
        self.surrogate = try SurrogateActivation.from(name: config.surrogate)
        
        // Calculate hidden dimension from parameter budget
        // Total params = hiddenDim*4 (W_in) + hiddenDim (b_in) + hiddenDim (W_energy) + 1 (b_energy) + hiddenDim*2 (W_delta) + 2 (b_delta)
        //             = hiddenDim * (4 + 1 + 1 + 2) + 3 = hiddenDim * 8 + 3
        // Solve: hiddenDim = (parameterCount - 3) / 8
        guard config.parameterCount >= 11 else {
            throw RouterError.invalidConfiguration("parameter_count must be >= 11 for minimal network")
        }
        
        let rawHiddenDim = (config.parameterCount - 3) / 8
        let hiddenDim = max(1, rawHiddenDim)
        self.hiddenDim = hiddenDim
        
        // Deterministic lightweight initialization keeps unit tests reproducible.
        var inputWeights: [Float] = []
        inputWeights.reserveCapacity(hiddenDim * 4)
        let baseInput = SIMD4<Float>(0.022, 0.018, 0.040, 0.012)
        
        for i in 0..<hiddenDim {
            let phase = Float(i) * 0.37
            let scaleFactor = 0.7 + 0.3 * sin(phase)
            let scaled = baseInput * scaleFactor
            inputWeights.append(contentsOf: [scaled.x, scaled.y, scaled.z, scaled.w])
        }
        self.wIn = inputWeights
        self.bIn = [Float](repeating: 0, count: hiddenDim)
        
        var energyWeights: [Float] = []
        energyWeights.reserveCapacity(hiddenDim)
        let denom = Float(hiddenDim)
        for i in 0..<hiddenDim {
            let position = denom > 1 ? Float(i) / (denom - 1) : 0.0
            let weight = (0.45 + 0.35 * position) / denom
            energyWeights.append(weight)
        }
        self.wEnergy = energyWeights
        self.bEnergy = 0.0
        
        var routingWeights: [Float] = []
        routingWeights.reserveCapacity(hiddenDim * 2)
        for i in 0..<hiddenDim {
            let phase = Float(i) * 0.5
            routingWeights.append(0.15 * sin(phase))
        }
        for i in 0..<hiddenDim {
            let phase = Float(i + 1) * 0.5
            routingWeights.append(0.15 * cos(phase))
        }
        self.wDelta = routingWeights
        self.bDelta = SIMD2(0, 0)
    }
    
    // MARK: - Forward Pass
    
    /// Performs forward pass for a single packet.
    ///
    /// - Parameters:
    ///   - input: Normalized input [x_norm, y_norm, energy_norm, time_norm]
    ///   - membrane: Current membrane potential (will be updated)
    /// - Returns: Spiking output (energyNext, deltaXY, spike)
    public func forward(
        input: SIMD4<Float>,
        membrane: inout Float
    ) -> SpikingOutput {
        var hidden = [Float](repeating: 0, count: hiddenDim)
        
        for i in 0..<hiddenDim {
            let base = i * 4
            var sum = wIn[base] * input.x
            sum += wIn[base + 1] * input.y
            sum += wIn[base + 2] * input.z
            sum += wIn[base + 3] * input.w
            sum += bIn[i]
            hidden[i] = max(0.0, sum)
        }
        
        let hiddenSum = hidden.reduce(0, +)
        let hiddenAverage = hiddenDim > 0 ? hiddenSum / Float(hiddenDim) : 0.0
        // Membrane integrates hidden drive plus an energy-sensitive boost to preserve multi-step dynamics.
        let energyNormalized = max(0.0, min(input.z, 1.0))
        let energyBoost = energyNormalized * threshold * 0.4
        let contributionCap = threshold * 0.8
        let membraneContribution = min(hiddenAverage + energyBoost, contributionCap)
        let membraneUpdated = decay * membrane + membraneContribution
        
        let spike = membraneUpdated >= threshold
        
        if spike {
            membrane = resetValue
        } else {
            membrane = max(0.0, membraneUpdated)
        }
        
        var energyNext: Float = bEnergy
        vDSP_dotpr(wEnergy, 1, hidden, 1, &energyNext, vDSP_Length(hiddenDim))
        energyNext = max(0.0, energyNext)
        
        var deltaX: Float = bDelta.x
        var deltaY: Float = bDelta.y
        
        for i in 0..<hiddenDim {
            deltaX += wDelta[i] * hidden[i]
            deltaY += wDelta[hiddenDim + i] * hidden[i]
        }
        
        let deltaXY = SIMD2<Float>(tanh(deltaX), tanh(deltaY))
        
        return SpikingOutput(
            energyNext: energyNext,
            deltaXY: deltaXY,
            spike: spike
        )
    }
    
    /// Batch forward pass for multiple packets.
    ///
    /// - Parameters:
    ///   - inputs: Array of normalized inputs
    ///   - membranes: Array of membrane potentials (will be updated in-place)
    /// - Returns: Array of spiking outputs
    public func forward(
        inputs: [SIMD4<Float>],
        membranes: inout [Float]
    ) -> [SpikingOutput] {
        guard inputs.count == membranes.count else {
            preconditionFailure("inputs and membranes must have same count")
        }
        
        var outputs: [SpikingOutput] = []
        outputs.reserveCapacity(inputs.count)
        
        for i in 0..<inputs.count {
            let output = forward(input: inputs[i], membrane: &membranes[i])
            outputs.append(output)
        }
        
        return outputs
    }
    
    // MARK: - Utilities
    
    /// Returns statistics about current parameters.
    public func statistics() -> KernelStatistics {
        let wInMean = vDSP.mean(wIn)
        let wInStd = sqrt(vDSP.meanSquare(wIn.map { ($0 - wInMean) * ($0 - wInMean) }))
        
        return KernelStatistics(
            parameterCount: parameterCount,
            hiddenDim: hiddenDim,
            wInMean: wInMean,
            wInStd: wInStd,
            threshold: threshold,
            decay: decay
        )
    }
}

// MARK: - Kernel Statistics

public struct KernelStatistics: CustomStringConvertible {
    public let parameterCount: Int
    public let hiddenDim: Int
    public let wInMean: Float
    public let wInStd: Float
    public let threshold: Float
    public let decay: Float
    
    public var description: String {
        """
        SpikingKernel Statistics:
          Parameters: \(parameterCount)
          Hidden dim: \(hiddenDim)
          W_in: mean=\(String(format: "%.4f", wInMean)), std=\(String(format: "%.4f", wInStd))
          Threshold: \(String(format: "%.2f", threshold))
          Decay: \(String(format: "%.2f", decay))
        """
    }
}
