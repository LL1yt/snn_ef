import Foundation

/// Routes energy packets through temporal grid using SNN dynamics.
public struct SpikeRouter: Sendable {
    
    // MARK: - Components
    
    /// Temporal grid layout
    public let grid: TemporalGrid
    
    /// Spiking kernel for membrane dynamics
    public let kernel: SpikingKernel
    
    /// Router configuration
    public let config: RouterConfig
    
    // MARK: - Initialization
    
    /// Creates a SpikeRouter with specified components.
    ///
    /// - Parameters:
    ///   - grid: Temporal grid
    ///   - kernel: Spiking kernel
    ///   - config: Router configuration
    public init(grid: TemporalGrid, kernel: SpikingKernel, config: RouterConfig) {
        self.grid = grid
        self.kernel = kernel
        self.config = config
    }
    
    /// Creates a SpikeRouter from configuration.
    ///
    /// - Parameter config: Router configuration
    /// - Returns: Initialized SpikeRouter
    /// - Throws: RouterError if initialization fails
    public static func create(from config: RouterConfig) throws -> SpikeRouter {
        let grid = try TemporalGrid(layers: config.layers, nodesPerLayer: config.nodesPerLayer)
        let kernel = try SpikingKernel(config: config.snn)
        return SpikeRouter(grid: grid, kernel: kernel, config: config)
    }
    
    // MARK: - Routing
    
    /// Routes a single packet through one time step.
    ///
    /// - Parameters:
    ///   - packet: Energy packet to route
    ///   - membrane: Membrane potential for this packet (updated)
    /// - Returns: New packet after routing, or nil if packet died
    public func route(
        packet: EnergyPacket,
        membrane: inout Float
    ) -> EnergyPacket? {
        // 1. Validate packet bounds
        guard grid.isValid(x: packet.x, y: packet.y) else {
            preconditionFailure("Packet out of bounds: \(packet)")
        }
        
        // 2. Check if already at output layer
        if grid.isOutputLayer(packet.x) {
            return nil  // Packet reaches output
        }
        
        // 3. Normalize packet state for kernel input
        let input = packet.asNormalizedInput(
            maxLayers: grid.layers,
            maxNodesPerLayer: grid.nodesPerLayer,
            maxEnergy: Float(config.energyBase),
            maxTime: 1000  // TODO: make configurable
        )
        
        // 4. Run spiking kernel
        let output = kernel.forward(input: input, membrane: &membrane)
        
        // 5. Calculate base forward step (always advance at least +1)
        let xBase = grid.advanceForward(packet.x)
        let yBase = grid.wrapY(packet.y)
        
        // 6. Apply spike jump if spike occurred
        var xNext: Int
        var yNext: Int
        
        if output.spike {
            // Spike: add delta jumps
            let deltaXInt = Int(round(output.deltaXY.x * Float(config.snn.deltaXRange.upperBound)))
            let deltaYInt = Int(round(output.deltaXY.y * Float(config.snn.deltaYRange.upperBound)))
            
            // Clamp deltaX to valid range
            let deltaXClamped = max(config.snn.deltaXRange.lowerBound, min(deltaXInt, config.snn.deltaXRange.upperBound))
            
            xNext = grid.clampX(xBase + deltaXClamped - 1)  // -1 because base already advanced
            yNext = grid.wrapY(yBase + deltaYInt)
        } else {
            // No spike: regular step
            xNext = xBase
            yNext = yBase
        }
        
        // 7. Apply energy decay and floor check
        let energyDecayed = config.alpha * max(output.energyNext, 0.0)
        
        guard energyDecayed >= config.energyFloor else {
            return nil  // Packet dies
        }
        
        // 8. Check for negative energy (fail-fast)
        guard energyDecayed >= 0 else {
            preconditionFailure("Negative energy after decay: \(energyDecayed) for stream \(packet.streamID)")
        }
        
        // 9. Create next packet
        return EnergyPacket(
            streamID: packet.streamID,
            x: xNext,
            y: yNext,
            energy: energyDecayed,
            time: packet.time + 1
        )
    }
    
    /// Routes multiple packets in batch.
    ///
    /// - Parameters:
    ///   - packets: Array of energy packets
    ///   - membranes: Array of membrane potentials (one per packet, updated)
    /// - Returns: Array of routed packets (nils filtered out)
    public func route(
        packets: [EnergyPacket],
        membranes: inout [Float]
    ) -> [EnergyPacket] {
        guard packets.count == membranes.count else {
            preconditionFailure("packets and membranes must have same count")
        }
        
        var nextPackets: [EnergyPacket] = []
        nextPackets.reserveCapacity(packets.count)
        
        for i in 0..<packets.count {
            if let next = route(packet: packets[i], membrane: &membranes[i]) {
                nextPackets.append(next)
            }
        }

        return nextPackets
    }

    /// Routes a single packet with detailed spike information.
    ///
    /// - Parameters:
    ///   - packet: Energy packet to route
    ///   - membrane: Membrane potential for this packet (updated)
    /// - Returns: Detailed route result with spike information, or nil if packet died/completed
    public func routeDetailed(
        packet: EnergyPacket,
        membrane: inout Float
    ) -> RouteStepResult? {
        // 1. Validate packet bounds
        guard grid.isValid(x: packet.x, y: packet.y) else {
            preconditionFailure("Packet out of bounds: \(packet)")
        }

        // 2. Check if already at output layer
        if grid.isOutputLayer(packet.x) {
            return RouteStepResult(
                nextPacket: nil,
                spike: false,
                reachedOutput: true,
                died: false
            )
        }

        // 3. Normalize packet state for kernel input
        let input = packet.asNormalizedInput(
            maxLayers: grid.layers,
            maxNodesPerLayer: grid.nodesPerLayer,
            maxEnergy: Float(config.energyBase),
            maxTime: 1000
        )

        // 4. Run spiking kernel
        let output = kernel.forward(input: input, membrane: &membrane)

        // 5. Calculate base forward step
        let xBase = grid.advanceForward(packet.x)
        let yBase = grid.wrapY(packet.y)

        // 6. Apply spike jump if spike occurred
        var xNext: Int
        var yNext: Int

        if output.spike {
            let deltaXInt = Int(round(output.deltaXY.x * Float(config.snn.deltaXRange.upperBound)))
            let deltaYInt = Int(round(output.deltaXY.y * Float(config.snn.deltaYRange.upperBound)))
            let deltaXClamped = max(config.snn.deltaXRange.lowerBound, min(deltaXInt, config.snn.deltaXRange.upperBound))

            xNext = grid.clampX(xBase + deltaXClamped - 1)
            yNext = grid.wrapY(yBase + deltaYInt)
        } else {
            xNext = xBase
            yNext = yBase
        }

        // 7. Apply energy decay and floor check
        let energyDecayed = config.alpha * max(output.energyNext, 0.0)

        guard energyDecayed >= config.energyFloor else {
            return RouteStepResult(
                nextPacket: nil,
                spike: output.spike,
                reachedOutput: false,
                died: true
            )
        }

        // 8. Check for negative energy
        guard energyDecayed >= 0 else {
            preconditionFailure("Negative energy after decay: \(energyDecayed) for stream \(packet.streamID)")
        }

        // 9. Create next packet
        let nextPacket = EnergyPacket(
            streamID: packet.streamID,
            x: xNext,
            y: yNext,
            energy: energyDecayed,
            time: packet.time + 1
        )

        return RouteStepResult(
            nextPacket: nextPacket,
            spike: output.spike,
            reachedOutput: false,
            died: false
        )
    }
}

// MARK: - Route Result

/// Result of a single routing step with detailed information
public struct RouteStepResult: Sendable {
    /// Next packet state (nil if died or reached output)
    public let nextPacket: EnergyPacket?

    /// Whether a spike occurred during this step
    public let spike: Bool

    /// Whether packet reached output layer
    public let reachedOutput: Bool

    /// Whether packet died (energy below floor)
    public let died: Bool

    public init(nextPacket: EnergyPacket?, spike: Bool, reachedOutput: Bool, died: Bool) {
        self.nextPacket = nextPacket
        self.spike = spike
        self.reachedOutput = reachedOutput
        self.died = died
    }
}

/// Result of routing operation containing new packets and completed streams.
public struct RouteResult: Sendable {
    /// Packets that continue routing
    public let activePackets: [EnergyPacket]

    /// Stream IDs that reached output layer
    public let completedStreams: Set<Int>

    /// Stream IDs that died (energy below floor)
    public let deadStreams: Set<Int>

    public init(activePackets: [EnergyPacket], completedStreams: Set<Int>, deadStreams: Set<Int>) {
        self.activePackets = activePackets
        self.completedStreams = completedStreams
        self.deadStreams = deadStreams
    }
}
