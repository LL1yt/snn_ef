import Foundation

/// Simulates energy flow through the router over multiple time steps.
public final class EnergyFlowSimulator {
    
    // MARK: - Components
    
    /// Router for packet routing
    private let router: SpikeRouter
    
    /// Maximum simulation time steps
    private let maxSteps: Int
    
    // MARK: - State
    
    /// Currently active packets
    private var activePackets: [EnergyPacket]
    
    /// Membrane potentials for each active packet
    private var membranes: [Float]
    
    /// Accumulated output energy per stream ID
    private var outputAccumulator: [Int: Float]
    
    /// Current simulation step
    private var currentStep: Int
    
    /// Completed stream IDs
    private var completedStreams: Set<Int>
    
    /// Dead stream IDs (energy below floor)
    private var deadStreams: Set<Int>
    
    // MARK: - Initialization
    
    /// Creates an EnergyFlowSimulator.
    ///
    /// - Parameters:
    ///   - router: Spike router
    ///   - initialPackets: Starting packets
    ///   - maxSteps: Maximum simulation steps (default: 1000)
    public init(
        router: SpikeRouter,
        initialPackets: [EnergyPacket],
        maxSteps: Int = 1000
    ) {
        self.router = router
        self.maxSteps = maxSteps
        
        self.activePackets = initialPackets
        self.membranes = [Float](repeating: 0, count: initialPackets.count)
        self.outputAccumulator = [:]
        self.currentStep = 0
        self.completedStreams = []
        self.deadStreams = []
    }
    
    // MARK: - Simulation
    
    /// Executes one simulation step.
    ///
    /// - Returns: True if simulation should continue, false if finished
    @discardableResult
    public func step() -> Bool {
        guard !activePackets.isEmpty && currentStep < maxSteps else {
            return false
        }
        
        // Track packets reaching output
        var nextPackets: [EnergyPacket] = []
        var nextMembranes: [Float] = []
        
        for i in 0..<activePackets.count {
            let packet = activePackets[i]
            var membrane = membranes[i]
            
            // Check if packet reached output layer
            if router.grid.isOutputLayer(packet.x) {
                // Accumulate output energy
                outputAccumulator[packet.streamID, default: 0] += packet.energy
                completedStreams.insert(packet.streamID)
                continue
            }
            
            // Route packet
            if let nextPacket = router.route(packet: packet, membrane: &membrane) {
                nextPackets.append(nextPacket)
                nextMembranes.append(membrane)
            } else {
                // Packet died
                deadStreams.insert(packet.streamID)
            }
        }
        
        // Update state
        activePackets = nextPackets
        membranes = nextMembranes
        currentStep += 1
        
        return !activePackets.isEmpty
    }
    
    /// Runs simulation until completion or maxSteps reached.
    ///
    /// - Parameter maxSteps: Optional override for maxSteps
    /// - Returns: Final simulation result
    public func run(maxSteps: Int? = nil) -> SimulationResult {
        let limit = maxSteps ?? self.maxSteps
        
        while currentStep < limit && !activePackets.isEmpty {
            step()
        }
        
        return SimulationResult(
            outputEnergies: outputAccumulator,
            completedStreams: completedStreams,
            deadStreams: deadStreams,
            steps: currentStep,
            didTimeout: !activePackets.isEmpty
        )
    }
    
    /// Runs until specific condition met.
    ///
    /// - Parameter condition: Condition to check after each step
    /// - Returns: Final simulation result
    public func run(until condition: (EnergyFlowSimulator) -> Bool) -> SimulationResult {
        while currentStep < maxSteps && !activePackets.isEmpty {
            step()
            if condition(self) {
                break
            }
        }
        
        return SimulationResult(
            outputEnergies: outputAccumulator,
            completedStreams: completedStreams,
            deadStreams: deadStreams,
            steps: currentStep,
            didTimeout: !activePackets.isEmpty
        )
    }
    
    // MARK: - Query
    
    /// Returns current output energies.
    public func collectOutputs() -> [Int: Float] {
        outputAccumulator
    }
    
    /// Returns current active packet count.
    public var activeCount: Int {
        activePackets.count
    }
    
    /// Returns current step number.
    public var currentStepNumber: Int {
        currentStep
    }
    
    /// Checks if simulation is finished.
    public var isFinished: Bool {
        activePackets.isEmpty || currentStep >= maxSteps
    }

    /// Produces a detailed snapshot of the current simulator state.
    public func snapshot() -> EnergyFlowFrame {
        let gridDescriptor = EnergyFlowFrame.GridDescriptor(
            layers: router.grid.layers,
            nodesPerLayer: router.grid.nodesPerLayer
        )

        var packets: [EnergyFlowFrame.PacketState] = []
        packets.reserveCapacity(activePackets.count)

        var layerAggregates: [Int: (energy: Float, count: Int)] = [:]
        layerAggregates.reserveCapacity(router.grid.layers)

        for (index, packet) in activePackets.enumerated() {
            let membrane = index < membranes.count ? membranes[index] : 0
            packets.append(
                EnergyFlowFrame.PacketState(
                    streamID: packet.streamID,
                    x: packet.x,
                    y: packet.y,
                    energy: packet.energy,
                    time: packet.time,
                    membrane: membrane,
                    index: index
                )
            )

            let aggregate = layerAggregates[packet.x] ?? (0, 0)
            layerAggregates[packet.x] = (
                aggregate.energy + packet.energy,
                aggregate.count + 1
            )
        }

        var perLayer: [EnergyFlowFrame.LayerEnergy] = []
        perLayer.reserveCapacity(router.grid.layers)

        for layer in 0..<router.grid.layers {
            let aggregate = layerAggregates[layer] ?? (0, 0)
            perLayer.append(
                EnergyFlowFrame.LayerEnergy(
                    layer: layer,
                    packetCount: aggregate.count,
                    totalEnergy: aggregate.energy
                )
            )
        }

        let membraneSummary: EnergyFlowFrame.MembraneSummary?
        if !membranes.isEmpty {
            let minValue = membranes.min() ?? 0
            let maxValue = membranes.max() ?? 0
            let sum = membranes.reduce(0, +)
            let average = sum / Float(membranes.count)
            membraneSummary = EnergyFlowFrame.MembraneSummary(
                min: minValue,
                max: maxValue,
                average: average
            )
        } else {
            membraneSummary = nil
        }

        let totalActiveEnergy = packets.reduce(Float(0)) { $0 + $1.energy }

        return EnergyFlowFrame(
            step: currentStep,
            grid: gridDescriptor,
            activePackets: packets,
            perLayer: perLayer,
            outputEnergies: outputAccumulator,
            completedStreams: completedStreams,
            deadStreams: deadStreams,
            totalActiveEnergy: totalActiveEnergy,
            membraneSummary: membraneSummary
        )
    }
}

// MARK: - Simulation Result

/// Result of energy flow simulation.
public struct SimulationResult: Sendable {
    /// Output energies per stream ID
    public let outputEnergies: [Int: Float]
    
    /// Stream IDs that reached output
    public let completedStreams: Set<Int>
    
    /// Stream IDs that died (energy below floor)
    public let deadStreams: Set<Int>
    
    /// Number of steps executed
    public let steps: Int
    
    /// Whether simulation timed out (active packets remain)
    public let didTimeout: Bool
    
    public init(
        outputEnergies: [Int: Float],
        completedStreams: Set<Int>,
        deadStreams: Set<Int>,
        steps: Int,
        didTimeout: Bool
    ) {
        self.outputEnergies = outputEnergies
        self.completedStreams = completedStreams
        self.deadStreams = deadStreams
        self.steps = steps
        self.didTimeout = didTimeout
    }
    
    /// Total energy that reached output.
    public var totalOutputEnergy: Float {
        outputEnergies.values.reduce(0, +)
    }
    
    /// Number of streams that completed.
    public var completedCount: Int {
        completedStreams.count
    }
    
    /// Number of streams that died.
    public var deadCount: Int {
        deadStreams.count
    }
}
