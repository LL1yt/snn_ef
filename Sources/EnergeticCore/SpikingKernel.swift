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
    
    /// Creates a SpikingKernel with random initialization.
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
        
        let hiddenDim = (config.parameterCount - 3) / 8
        self.hiddenDim = hiddenDim
        
        // Initialize weights with Xavier/He initialization
        let scale = sqrt(2.0 / Float(4 + hiddenDim))
        
        self.wIn = (0..<(hiddenDim * 4)).map { _ in Float.random(in: -scale...scale) }
        self.bIn = [Float](repeating: 0, count: hiddenDim)
        
        self.wEnergy = (0..<hiddenDim).map { _ in Float.random(in: -scale...scale) }
        self.bEnergy = 0.0
        
        self.wDelta = (0..<(hiddenDim * 2)).map { _ in Float.random(in: -scale...scale) }
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
        // 1. Update membrane potential: V ← decay·V + W_in·input + b_in
        var hidden = [Float](repeating: 0, count: hiddenDim)
        
        // Matrix-vector multiply: hidden = W_in * input
        for i in 0..<hiddenDim {
            var sum: Float = 0
            for j in 0..<4 {
                let inputVal: Float
                switch j {
                case 0: inputVal = input.x
                case 1: inputVal = input.y
                case 2: inputVal = input.z
                case 3: inputVal = input.w
                default: inputVal = 0
                }
                sum += wIn[i * 4 + j] * inputVal
            }
            hidden[i] = decay * membrane + sum + bIn[i]
        }
        
        // Apply activation (ReLU for hidden layer)
        vDSP_vthres(hidden, 1, [0.0], &hidden, 1, vDSP_Length(hiddenDim))
        
        // 2. Compute outputs
        // Energy: energyNext = W_energy · hidden + b_energy
        var energyNext: Float = bEnergy
        vDSP_dotpr(wEnergy, 1, hidden, 1, &energyNext, vDSP_Length(hiddenDim))
        energyNext += bEnergy
        
        // Delta XY: deltaXY = tanh(W_delta · hidden + b_delta)
        var deltaX: Float = bDelta.x
        var deltaY: Float = bDelta.y
        
        for i in 0..<hiddenDim {
            deltaX += wDelta[i] * hidden[i]
            deltaY += wDelta[hiddenDim + i] * hidden[i]
        }
        
        let deltaXY = SIMD2(tanh(deltaX), tanh(deltaY))
        
        // 3. Check spike condition: spike = (V >= threshold)
        // Use surrogate for differentiability
        let v = hidden.reduce(0, +) / Float(hiddenDim)  // Simple aggregation
        membrane = v
        
        let spike = v >= threshold
        
        // 4. Reset membrane if spike occurred
        if spike {
            membrane = resetValue
        }
        
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
