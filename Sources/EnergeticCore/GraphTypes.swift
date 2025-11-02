import Foundation

// MARK: - SNN Configuration

/// SNN-specific parameters loaded from router.snn config section
public struct SNNConfig: Sendable, Equatable {
    /// Total number of trainable parameters in SpikingKernel
    public let parameterCount: Int
    
    /// Membrane potential decay factor, (0, 1)
    public let decay: Float
    
    /// Spike threshold, (0, 1]
    public let threshold: Float
    
    /// Value to reset membrane potential after spike
    public let resetValue: Float
    
    /// Delta X range for spike jumps [min, max], min >= 1
    public let deltaXRange: ClosedRange<Int>
    
    /// Delta Y range for vertical movement [min, max], must contain 0
    public let deltaYRange: ClosedRange<Int>
    
    /// Surrogate gradient function name
    public let surrogate: String
    
    /// Time step duration
    public let dt: Int
    
    public init(
        parameterCount: Int,
        decay: Float,
        threshold: Float,
        resetValue: Float,
        deltaXRange: ClosedRange<Int>,
        deltaYRange: ClosedRange<Int>,
        surrogate: String,
        dt: Int
    ) {
        self.parameterCount = parameterCount
        self.decay = decay
        self.threshold = threshold
        self.resetValue = resetValue
        self.deltaXRange = deltaXRange
        self.deltaYRange = deltaYRange
        self.surrogate = surrogate
        self.dt = dt
    }
}

// MARK: - Router Configuration

/// Global router configuration including grid and energy flow
public struct RouterConfig: Sendable, Equatable {
    /// Number of layers in temporal grid
    public let layers: Int
    
    /// Number of nodes per layer
    public let nodesPerLayer: Int
    
    /// SNN-specific parameters
    public let snn: SNNConfig
    
    /// Energy decay factor per step, (0, 1]
    public let alpha: Float
    
    /// Minimum energy threshold (packets below are dropped)
    public let energyFloor: Float
    
    /// Energy base (must match capsule.base)
    public let energyBase: Int
    
    public init(
        layers: Int,
        nodesPerLayer: Int,
        snn: SNNConfig,
        alpha: Float,
        energyFloor: Float,
        energyBase: Int
    ) {
        self.layers = layers
        self.nodesPerLayer = nodesPerLayer
        self.snn = snn
        self.alpha = alpha
        self.energyFloor = energyFloor
        self.energyBase = energyBase
    }
    
    /// Total nodes in the grid
    public var totalNodes: Int {
        layers * nodesPerLayer
    }
}

// MARK: - Energy Packet

/// Represents a packet of energy moving through the temporal grid
public struct EnergyPacket: Sendable, Equatable {
    /// Stream identifier
    public let streamID: Int
    
    /// Current layer position (X coordinate)
    public var x: Int
    
    /// Current node index within layer (Y coordinate)
    public var y: Int
    
    /// Current energy level
    public var energy: Float
    
    /// Current time step
    public var time: Int
    
    public init(streamID: Int, x: Int, y: Int, energy: Float, time: Int) {
        self.streamID = streamID
        self.x = x
        self.y = y
        self.energy = energy
        self.time = time
    }
    
    /// Converts packet state to normalized input [x_norm, y_norm, energy_norm, time_norm]
    public func asNormalizedInput(
        maxLayers: Int,
        maxNodesPerLayer: Int,
        maxEnergy: Float,
        maxTime: Int
    ) -> SIMD4<Float> {
        let xNorm = Float(x) / Float(max(maxLayers - 1, 1))
        let yNorm = Float(y) / Float(max(maxNodesPerLayer - 1, 1))
        let energyNorm = energy / max(maxEnergy, 1.0)
        let timeNorm = Float(time) / Float(max(maxTime, 1))
        return SIMD4(xNorm, yNorm, energyNorm, timeNorm)
    }
    
    /// Checks if packet is alive (energy above threshold)
    public func isAlive(minEnergy: Float) -> Bool {
        energy >= minEnergy
    }
}

// MARK: - Spiking Output

/// Output from SpikingKernel for a single packet
public struct SpikingOutput: Sendable {
    /// Next energy level (before alpha decay)
    public let energyNext: Float
    
    /// Delta X and Y for movement (float values, will be rounded)
    public let deltaXY: SIMD2<Float>
    
    /// Whether spike occurred
    public let spike: Bool
    
    public init(energyNext: Float, deltaXY: SIMD2<Float>, spike: Bool) {
        self.energyNext = energyNext
        self.deltaXY = deltaXY
        self.spike = spike
    }
}

// MARK: - Graph Errors

/// Errors that can occur during router operation
public enum RouterError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case packetOutOfBounds(EnergyPacket)
    case negativeEnergy(streamID: Int, energy: Float)
    case membraneNaN(streamID: Int)
    case invalidSurrogate(String)
    
    public var description: String {
        switch self {
        case .invalidConfiguration(let reason):
            return "Invalid router configuration: \(reason)"
        case .packetOutOfBounds(let packet):
            return "Packet out of bounds: streamID=\(packet.streamID) x=\(packet.x) y=\(packet.y)"
        case .negativeEnergy(let streamID, let energy):
            return "Negative energy for stream \(streamID): \(energy)"
        case .membraneNaN(let streamID):
            return "NaN in membrane potential for stream \(streamID)"
        case .invalidSurrogate(let name):
            return "Invalid surrogate function: \(name)"
        }
    }
}
