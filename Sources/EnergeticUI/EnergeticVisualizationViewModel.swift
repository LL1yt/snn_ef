import Foundation
import EnergeticCore

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
}
