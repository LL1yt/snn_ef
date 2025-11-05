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

    // Legacy grid simulator removed; UI runs in headless mode for Flow backend.

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
        // Disable simulator; show hint
        self.currentFrame = nil
        self.frameHistory = []
        self.hasFinished = true
        self.errorDescription = "Flow backend UI is not implemented yet (headless only)."
    }

    public func reset() {
        // No-op for flow backend
        self.currentFrame = nil
        self.frameHistory = []
        self.hasFinished = true
        self.errorDescription = "Flow backend UI is not implemented yet (headless only)."
    }

    public func step() {
        // No-op
    }

    public func stepMultiple(count: Int) {
        // No-op
    }

    public func runToEnd(maxIterations: Int? = nil) {
        // No-op
    }

    private func rebuildSimulator() {
        // No-op (kept for API compatibility)
        self.currentFrame = nil
        self.frameHistory = []
        self.hasFinished = true
        self.errorDescription = "Flow backend UI is not implemented yet (headless only)."
    }

    private func captureFrame(from simulator: Any, resetHistory: Bool = false) {
        // No-op placeholder to satisfy call sites if any linger
        self.currentFrame = nil
        self.hasFinished = true
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
