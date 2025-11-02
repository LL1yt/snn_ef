import Foundation

/// Snapshot of the energy flow simulator at a single step.
public struct EnergyFlowFrame: Sendable, Identifiable {
    public let id: UUID
    public let step: Int
    public let timestamp: Date
    public let grid: GridDescriptor
    public let activePackets: [PacketState]
    public let perLayer: [LayerEnergy]
    public let outputEnergies: [Int: Float]
    public let completedStreams: Set<Int>
    public let deadStreams: Set<Int>
    public let totalActiveEnergy: Float
    public let membraneSummary: MembraneSummary?

    public init(
        id: UUID = UUID(),
        step: Int,
        timestamp: Date = Date(),
        grid: GridDescriptor,
        activePackets: [PacketState],
        perLayer: [LayerEnergy],
        outputEnergies: [Int: Float],
        completedStreams: Set<Int>,
        deadStreams: Set<Int>,
        totalActiveEnergy: Float,
        membraneSummary: MembraneSummary?
    ) {
        self.id = id
        self.step = step
        self.timestamp = timestamp
        self.grid = grid
        self.activePackets = activePackets
        self.perLayer = perLayer
        self.outputEnergies = outputEnergies
        self.completedStreams = completedStreams
        self.deadStreams = deadStreams
        self.totalActiveEnergy = totalActiveEnergy
        self.membraneSummary = membraneSummary
    }

    public var maxLayerEnergy: Float {
        perLayer.map(\.totalEnergy).max() ?? 0
    }

    public struct GridDescriptor: Sendable {
        public let layers: Int
        public let nodesPerLayer: Int

        public init(layers: Int, nodesPerLayer: Int) {
            self.layers = layers
            self.nodesPerLayer = nodesPerLayer
        }
    }

    public struct LayerEnergy: Sendable, Identifiable {
        public let layer: Int
        public let packetCount: Int
        public let totalEnergy: Float
        public let averageEnergy: Float

        public init(layer: Int, packetCount: Int, totalEnergy: Float) {
            self.layer = layer
            self.packetCount = packetCount
            self.totalEnergy = totalEnergy
            if packetCount > 0 {
                self.averageEnergy = totalEnergy / Float(packetCount)
            } else {
                self.averageEnergy = 0
            }
        }

        public var id: Int { layer }
    }

    public struct PacketState: Sendable, Identifiable {
        public let id: String
        public let streamID: Int
        public let x: Int
        public let y: Int
        public let energy: Float
        public let time: Int
        public let membrane: Float

        public init(streamID: Int, x: Int, y: Int, energy: Float, time: Int, membrane: Float, index: Int) {
            self.streamID = streamID
            self.x = x
            self.y = y
            self.energy = energy
            self.time = time
            self.membrane = membrane
            self.id = "\(streamID)-\(time)-\(index)"
        }
    }

    public struct MembraneSummary: Sendable {
        public let min: Float
        public let max: Float
        public let average: Float

        public init(min: Float, max: Float, average: Float) {
            self.min = min
            self.max = max
            self.average = average
        }
    }
}
