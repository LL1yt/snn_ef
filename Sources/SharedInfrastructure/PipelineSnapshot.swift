import Foundation

/// Configuration pipeline snapshot for JSON export (config summary)
public struct ConfigPipelineSnapshot: Codable {
    public struct CapsuleSummary: Codable {
        public let base: Int
        public let blockSize: Int
        public let pipelineExample: String
    }

    public struct RouterSummary: Codable {
        public let backend: String
        public let T: Int
        public let radius: Double
        public let surrogate: String
        public let energyAlpha: Double
        public let energyFloor: Double
        public let bins: Int
    }

    public struct EnergyFlowSnapshot: Codable {
        public struct PacketSnapshot: Codable {
            public let streamID: Int
            public let layer: Int
            public let node: Int
            public let energy: Double
            public let time: Int
            public let membrane: Double

            public init(streamID: Int, layer: Int, node: Int, energy: Double, time: Int, membrane: Double) {
                self.streamID = streamID
                self.layer = layer
                self.node = node
                self.energy = energy
                self.time = time
                self.membrane = membrane
            }
        }

        public struct LayerSnapshot: Codable {
            public let layer: Int
            public let packetCount: Int
            public let totalEnergy: Double
            public let averageEnergy: Double

            public init(layer: Int, packetCount: Int, totalEnergy: Double, averageEnergy: Double) {
                self.layer = layer
                self.packetCount = packetCount
                self.totalEnergy = totalEnergy
                self.averageEnergy = averageEnergy
            }
        }

        public struct TraceEventSnapshot: Codable {
            public let step: Int
            public let layer: Int
            public let node: Int
            public let energy: Double
            public let membrane: Double
            public let spike: Bool

            public init(step: Int, layer: Int, node: Int, energy: Double, membrane: Double, spike: Bool) {
                self.step = step
                self.layer = layer
                self.node = node
                self.energy = energy
                self.membrane = membrane
                self.spike = spike
            }
        }

        public struct TraceSnapshot: Codable {
            public let streamID: Int
            public let events: [TraceEventSnapshot]
            public let totalSpikes: Int

            public init(streamID: Int, events: [TraceEventSnapshot], totalSpikes: Int) {
                self.streamID = streamID
                self.events = events
                self.totalSpikes = totalSpikes
            }
        }

        public struct SpikeSummarySnapshot: Codable {
            public let totalSpikes: Int
            public let spikeRate: Double
            public let spikesPerLayer: [Int: Int]
            public let spikesPerStream: [Int: Int]
            public let layersWithSpikes: Int
            public let activeStreams: Int

            public init(totalSpikes: Int, spikeRate: Double, spikesPerLayer: [Int: Int], spikesPerStream: [Int: Int], layersWithSpikes: Int, activeStreams: Int) {
                self.totalSpikes = totalSpikes
                self.spikeRate = spikeRate
                self.spikesPerLayer = spikesPerLayer
                self.spikesPerStream = spikesPerStream
                self.layersWithSpikes = layersWithSpikes
                self.activeStreams = activeStreams
            }
        }

        public let step: Int
        public let timestamp: String
        public let gridLayers: Int
        public let gridNodesPerLayer: Int
        public let activePackets: [PacketSnapshot]
        public let perLayer: [LayerSnapshot]
        public let outputEnergies: [Int: Double]
        public let completedStreams: [Int]
        public let deadStreams: [Int]
        public let totalActiveEnergy: Double
        public let traces: [TraceSnapshot]
        public let spikeSummary: SpikeSummarySnapshot?

        public init(
            step: Int,
            timestamp: String,
            gridLayers: Int,
            gridNodesPerLayer: Int,
            activePackets: [PacketSnapshot],
            perLayer: [LayerSnapshot],
            outputEnergies: [Int: Double],
            completedStreams: [Int],
            deadStreams: [Int],
            totalActiveEnergy: Double,
            traces: [TraceSnapshot],
            spikeSummary: SpikeSummarySnapshot?
        ) {
            self.step = step
            self.timestamp = timestamp
            self.gridLayers = gridLayers
            self.gridNodesPerLayer = gridNodesPerLayer
            self.activePackets = activePackets
            self.perLayer = perLayer
            self.outputEnergies = outputEnergies
            self.completedStreams = completedStreams
            self.deadStreams = deadStreams
            self.totalActiveEnergy = totalActiveEnergy
            self.traces = traces
            self.spikeSummary = spikeSummary
        }
    }

    // MARK: - Flow backend snapshot (ring seeds + boundary histogram)
    public struct FlowSnapshot: Codable {
        public struct RingSeed: Codable {
            public let id: Int
            public let angle: Double // radians [-pi, pi]
            public let x: Double
            public let y: Double
            public let energy: Double
            public init(id: Int, angle: Double, x: Double, y: Double, energy: Double) {
                self.id = id
                self.angle = angle
                self.x = x
                self.y = y
                self.energy = energy
            }
        }
        public struct ParticleSample: Codable {
            public let id: Int
            public let x: Double
            public let y: Double
            public let vx: Double
            public let vy: Double
            public let energy: Double
            public let V: Double
            public init(id: Int, x: Double, y: Double, vx: Double, vy: Double, energy: Double, V: Double) {
                self.id = id
                self.x = x
                self.y = y
                self.vx = vx
                self.vy = vy
                self.energy = energy
                self.V = V
            }
        }
        public let bins: [Double]
        public let radius: Double
        public let stepCount: Int
        public let ringSeeds: [RingSeed]
        public let samples: [ParticleSample]
        public init(bins: [Double], radius: Double, stepCount: Int, ringSeeds: [RingSeed], samples: [ParticleSample]) {
            self.bins = bins
            self.radius = radius
            self.stepCount = stepCount
            self.ringSeeds = ringSeeds
            self.samples = samples
        }
    }

    public let generatedAt: Date
    public let profile: String
    public let capsule: CapsuleSummary
    public let router: RouterSummary
    public let hint: String
    public let lastEvents: [String: Date]
    public let energyFlowSnapshot: EnergyFlowSnapshot?
    public let flow: FlowSnapshot?
}

public enum PipelineSnapshotExporter {
    public static func export(snapshot: ConfigSnapshot, fileManager: FileManager = .default) throws -> ConfigPipelineSnapshot {
        let pipelineSnapshot = makeSnapshot(from: snapshot)
        let url = try resolvedURL(for: snapshot.root.paths.pipelineSnapshot, fileManager: fileManager)
        try ensureDirectory(for: url, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pipelineSnapshot)
        try data.write(to: url, options: .atomic)
        return pipelineSnapshot
    }

    public static func load(from config: ConfigRoot, fileManager: FileManager = .default) -> ConfigPipelineSnapshot? {
        do {
            let url = try resolvedURL(for: config.paths.pipelineSnapshot, fileManager: fileManager)
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConfigPipelineSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    public static func resolvedURL(for path: String, fileManager: FileManager = .default) throws -> URL {
        let base = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let url = URL(fileURLWithPath: path)
        return url.path.hasPrefix("/") ? url : base.appendingPathComponent(path)
    }

    private static func ensureDirectory(for url: URL, fileManager: FileManager) throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func makeSnapshot(from snapshot: ConfigSnapshot) -> ConfigPipelineSnapshot {
        let root = snapshot.root
        let capsule = ConfigPipelineSnapshot.CapsuleSummary(
            base: root.capsule.base,
            blockSize: root.capsule.blockSize,
            pipelineExample: root.capsule.pipelineExampleText
        )
        let router = ConfigPipelineSnapshot.RouterSummary(
            backend: root.router.backend,
            T: root.router.flow.T,
            radius: root.router.flow.radius,
            surrogate: root.router.flow.lif.surrogate,
            energyAlpha: root.router.flow.dynamics.energyAlpha,
            energyFloor: root.router.flow.dynamics.energyFloor,
            bins: root.router.flow.projection.bins
        )

        let processes = ["capsule.encode", "router.step", "router.spike", "ui.pipeline", "cli.main"]
        var lastEvents: [String: Date] = [:]
        for alias in processes {
            if let timestamp = LoggingHub.lastEventTimestamp(for: alias) {
                lastEvents[alias] = timestamp
            }
        }

        let hint = CLIRenderer.hint(for: root)

        return ConfigPipelineSnapshot(
            generatedAt: Date(),
            profile: root.profile,
            capsule: capsule,
            router: router,
            hint: hint,
            lastEvents: lastEvents,
            energyFlowSnapshot: nil,
            flow: nil
        )
    }

    /// Exports snapshot with EnergyFlowFrame data
    public static func export(
        snapshot: ConfigSnapshot,
        energyFlowFrame: ConfigPipelineSnapshot.EnergyFlowSnapshot?,
        fileManager: FileManager = .default
    ) throws -> ConfigPipelineSnapshot {
        let pipelineSnapshot = makeSnapshot(from: snapshot, energyFlowSnapshot: energyFlowFrame, flow: nil)
        let url = try resolvedURL(for: snapshot.root.paths.pipelineSnapshot, fileManager: fileManager)
        try ensureDirectory(for: url, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pipelineSnapshot)
        try data.write(to: url, options: .atomic)
        return pipelineSnapshot
    }

    /// Exports snapshot with Flow (ring + histogram) data
    public static func export(
        snapshot: ConfigSnapshot,
        flow: ConfigPipelineSnapshot.FlowSnapshot?,
        fileManager: FileManager = .default
    ) throws -> ConfigPipelineSnapshot {
        let pipelineSnapshot = makeSnapshot(from: snapshot, energyFlowSnapshot: nil, flow: flow)
        let url = try resolvedURL(for: snapshot.root.paths.pipelineSnapshot, fileManager: fileManager)
        try ensureDirectory(for: url, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pipelineSnapshot)
        try data.write(to: url, options: .atomic)
        return pipelineSnapshot
    }

    private static func makeSnapshot(
        from snapshot: ConfigSnapshot,
        energyFlowSnapshot: ConfigPipelineSnapshot.EnergyFlowSnapshot?,
        flow: ConfigPipelineSnapshot.FlowSnapshot?
    ) -> ConfigPipelineSnapshot {
        let root = snapshot.root
        let capsule = ConfigPipelineSnapshot.CapsuleSummary(
            base: root.capsule.base,
            blockSize: root.capsule.blockSize,
            pipelineExample: root.capsule.pipelineExampleText
        )
        let router = ConfigPipelineSnapshot.RouterSummary(
            backend: root.router.backend,
            T: root.router.flow.T,
            radius: root.router.flow.radius,
            surrogate: root.router.flow.lif.surrogate,
            energyAlpha: root.router.flow.dynamics.energyAlpha,
            energyFloor: root.router.flow.dynamics.energyFloor,
            bins: root.router.flow.projection.bins
        )

        let processes = ["capsule.encode", "router.step", "router.spike", "ui.pipeline", "cli.main"]
        var lastEvents: [String: Date] = [:]
        for alias in processes {
            if let timestamp = LoggingHub.lastEventTimestamp(for: alias) {
                lastEvents[alias] = timestamp
            }
        }

        let hint = CLIRenderer.hint(for: root)

        return ConfigPipelineSnapshot(
            generatedAt: Date(),
            profile: root.profile,
            capsule: capsule,
            router: router,
            hint: hint,
            lastEvents: lastEvents,
            energyFlowSnapshot: energyFlowSnapshot,
            flow: flow
        )
    }
}
