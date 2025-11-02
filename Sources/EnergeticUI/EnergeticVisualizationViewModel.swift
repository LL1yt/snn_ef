import Foundation
import EnergeticCore
import SharedInfrastructure

@MainActor
public final class EnergeticVisualizationViewModel: ObservableObject {
    @Published public private(set) var currentFrame: EnergyFlowFrame?
    @Published public private(set) var frameHistory: [EnergyFlowFrame] = []
    @Published public private(set) var hasFinished: Bool = false
    @Published public private(set) var errorDescription: String?

    public var routerConfig: RouterConfig { config }
    public var maxSteps: Int { configurationMaxSteps }

    private let config: RouterConfig
    private let initialPackets: [EnergyPacket]
    private let configurationMaxSteps: Int
    private let historyLimit: Int

    private var simulator: EnergyFlowSimulator?

    public init(
        config: RouterConfig,
        initialPackets: [EnergyPacket],
        maxSteps: Int = 256,
        historyLimit: Int = 128
    ) {
        self.config = config
        self.initialPackets = initialPackets
        self.configurationMaxSteps = maxSteps
        self.historyLimit = historyLimit
        rebuildSimulator()
    }

    public func reset() {
        rebuildSimulator()
    }

    public func step() {
        guard let simulator else { return }
        _ = simulator.step()
        captureFrame(from: simulator)
    }

    public func stepMultiple(count: Int) {
        guard count > 0 else { return }
        guard let simulator else { return }
        for _ in 0..<count where !simulator.isFinished {
            simulator.step()
            captureFrame(from: simulator)
        }
    }

    public func runToEnd(maxIterations: Int? = nil) {
        guard let simulator else { return }
        var iterations = 0
        let limit = maxIterations ?? configurationMaxSteps
        while !simulator.isFinished && iterations < limit {
            simulator.step()
            captureFrame(from: simulator)
            iterations += 1
        }
    }

    private func rebuildSimulator() {
        do {
            let router = try SpikeRouter.create(from: config)
            let simulator = EnergyFlowSimulator(
                router: router,
                initialPackets: initialPackets,
                maxSteps: configurationMaxSteps
            )
            self.simulator = simulator
            errorDescription = nil
            captureFrame(from: simulator, resetHistory: true)
        } catch {
            simulator = nil
            currentFrame = nil
            frameHistory = []
            hasFinished = true
            errorDescription = error.localizedDescription
        }
    }

    private func captureFrame(from simulator: EnergyFlowSimulator, resetHistory: Bool = false) {
        let frame = simulator.snapshot()
        currentFrame = frame
        hasFinished = simulator.isFinished

        if resetHistory {
            frameHistory = [frame]
        } else {
            frameHistory.append(frame)
            if frameHistory.count > historyLimit {
                frameHistory.removeFirst(frameHistory.count - historyLimit)
            }
        }
    }

    /// Exports current frame to JSON snapshot
    /// - Parameter configSnapshot: Configuration snapshot to include
    /// - Returns: Exported pipeline snapshot
    public func exportSnapshot(configSnapshot: ConfigSnapshot) throws -> ConfigPipelineSnapshot {
        guard let frame = currentFrame else {
            throw ExportError.noFrameAvailable
        }

        return try PipelineSnapshotExporter.export(
            snapshot: configSnapshot,
            energyFlowFrame: frame.toSnapshot()
        )
    }

    /// Exports current frame to specific path
    /// - Parameters:
    ///   - path: File path for export
    ///   - configSnapshot: Configuration snapshot to include
    public func exportSnapshot(to path: String, configSnapshot: ConfigSnapshot) throws {
        guard let frame = currentFrame else {
            throw ExportError.noFrameAvailable
        }

        // Create modified config snapshot with custom path
        var modifiedSnapshot = configSnapshot
        // Note: This would require ConfigSnapshot to be mutable or provide a copy method
        // For now, we'll use the export method with the current path

        let snapshot = try PipelineSnapshotExporter.export(
            snapshot: configSnapshot,
            energyFlowFrame: frame.toSnapshot()
        )

        // Write to custom path
        let url = URL(fileURLWithPath: path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public enum ExportError: Error, CustomStringConvertible {
        case noFrameAvailable

        public var description: String {
            switch self {
            case .noFrameAvailable:
                return "No energy flow frame available for export"
            }
        }
    }
}
