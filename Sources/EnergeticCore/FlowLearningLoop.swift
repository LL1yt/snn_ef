import Foundation

#if canImport(SharedInfrastructure)
import SharedInfrastructure
#endif

// MARK: - Learning Configuration

public struct LearningConfig {
    public let enabled: Bool
    public let epochs: Int
    public let stepsPerEpoch: Int
    public let targetSpikeRate: Float
    public let learningRates: LearningRates
    public let lossWeights: LossWeights
    public let bounds: Bounds
    public let aggregatorConfig: AggregatorConfig

    public init(
        enabled: Bool,
        epochs: Int,
        stepsPerEpoch: Int,
        targetSpikeRate: Float,
        learningRates: LearningRates,
        lossWeights: LossWeights,
        bounds: Bounds,
        aggregatorConfig: AggregatorConfig
    ) {
        self.enabled = enabled
        self.epochs = epochs
        self.stepsPerEpoch = stepsPerEpoch
        self.targetSpikeRate = targetSpikeRate
        self.learningRates = learningRates
        self.lossWeights = lossWeights
        self.bounds = bounds
        self.aggregatorConfig = aggregatorConfig
    }

    public struct LearningRates {
        public let gain: Float
        public let lif: Float
        public let dynamics: Float

        public init(gain: Float, lif: Float, dynamics: Float) {
            self.gain = gain
            self.lif = lif
            self.dynamics = dynamics
        }
    }

    public struct LossWeights {
        public let spike: Float
        public let boundary: Float

        public init(spike: Float, boundary: Float) {
            self.spike = spike
            self.boundary = boundary
        }
    }

    public struct Bounds {
        public let theta: (min: Float, max: Float)
        public let radialBias: (min: Float, max: Float)
        public let spikeKick: (min: Float, max: Float)
        public let gain: (min: Float, max: Float)

        public init(theta: (Float, Float), radialBias: (Float, Float), spikeKick: (Float, Float), gain: (Float, Float)) {
            self.theta = theta
            self.radialBias = radialBias
            self.spikeKick = spikeKick
            self.gain = gain
        }
    }

    #if canImport(SharedInfrastructure)
    public static func from(_ cfg: ConfigRoot.Router.Flow, radius: Float) -> LearningConfig {
        let learning = cfg.learning
        return LearningConfig(
            enabled: learning.enabled,
            epochs: learning.epochs,
            stepsPerEpoch: learning.stepsPerEpoch,
            targetSpikeRate: Float(learning.targetSpikeRate),
            learningRates: .init(
                gain: Float(learning.lr.gain),
                lif: Float(learning.lr.lif),
                dynamics: Float(learning.lr.dynamics)
            ),
            lossWeights: .init(
                spike: Float(learning.weights.spike),
                boundary: Float(learning.weights.boundary)
            ),
            bounds: .init(
                theta: (Float(learning.bounds.theta[0]), Float(learning.bounds.theta[1])),
                radialBias: (Float(learning.bounds.radialBias[0]), Float(learning.bounds.radialBias[1])),
                spikeKick: (Float(learning.bounds.spikeKick[0]), Float(learning.bounds.spikeKick[1])),
                gain: (Float(learning.bounds.gain[0]), Float(learning.bounds.gain[1]))
            ),
            aggregatorConfig: AggregatorConfig.from(learning, radius: radius)
        )
    }
    #endif
}

// MARK: - Learning Loop

/// Main coordinator for the learning pipeline
public final class FlowLearningLoop {
    private let flowConfig: FlowConfig
    private let learningConfig: LearningConfig
    private var params: LearnableParameters
    private var router: FlowRouter
    private var previousBinLoss: Float = .infinity

    public init(flowConfig: FlowConfig, learningConfig: LearningConfig, seed: UInt64) {
        self.flowConfig = flowConfig
        self.learningConfig = learningConfig
        self.params = LearnableParameters(
            bins: flowConfig.bins,
            lifThreshold: flowConfig.lif.threshold,
            radialBias: flowConfig.dynamics.radialBias,
            spikeKick: 0.5  // Initial spike kick value
        )
        self.router = FlowRouter(cfg: flowConfig, seed: seed)
    }

    /// Runs one epoch of learning
    public func runEpoch(
        epoch: Int,
        energies: [Float],
        targets: [Float]
    ) -> LearningMetrics {
        // Create seeds from energies
        let seeds = FlowSeeds.makeSeeds(
            energies: energies,
            layout: flowConfig.seedLayout,
            radius: flowConfig.seedRadius,
            bins: flowConfig.bins
        )

        // Run simulation with event tracking
        var state = FlowState(step: 0, particles: seeds, bins: flowConfig.bins)
        var allCompletions: [CompletionEvent] = []
        var totalSpikes = 0
        var totalParticleSteps = 0
        let initialParticleCount = seeds.count

        // Store initial bin indices for alignment weight
        var initialBins: [Int: Int] = [:]
        for (idx, seed) in seeds.enumerated() {
            let theta = atan2(seed.pos.y, seed.pos.x)
            let binIdx = FlowProjector.binIndex(theta: theta, bins: flowConfig.bins)
            initialBins[seed.id] = binIdx
        }

        for step in 0..<learningConfig.stepsPerEpoch {
            guard !state.particles.isEmpty else { break }

            let events = router.stepWithEvents(state: &state)

            for event in events {
                totalParticleSteps += 1
                if event.spiked {
                    totalSpikes += 1
                }
                if let bin = event.projectedBin {
                    let completion = CompletionEvent(
                        particleID: event.id,
                        binIndex: bin,
                        position: event.pos,
                        energy: event.energy,
                        spiked: event.spiked,
                        initialBinIndex: initialBins[event.id]
                    )
                    allCompletions.append(completion)
                }
            }
        }

        // Aggregate completions
        let yHat = CompletionAggregator.aggregate(
            completions: allCompletions,
            targets: targets,
            config: learningConfig.aggregatorConfig,
            bins: flowConfig.bins
        )

        // Compute losses
        let binLoss = LossFunctions.binLoss(yHat: yHat, target: targets, gains: params.gains)
        let spikeRate = totalParticleSteps > 0 ? Float(totalSpikes) / Float(totalParticleSteps) : 0
        let spikeLoss = LossFunctions.spikeRateLoss(observed: spikeRate, target: learningConfig.targetSpikeRate)
        let boundaryLoss = LossFunctions.boundaryLoss(completions: allCompletions, radius: flowConfig.radius)
        let totalLoss = LossFunctions.totalLoss(
            binLoss: binLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeWeight: learningConfig.lossWeights.spike,
            boundaryWeight: learningConfig.lossWeights.boundary
        )

        // Compute metrics
        let completionRate = Float(allCompletions.count) / Float(initialParticleCount)
        let meanRadialMiss = computeMeanRadialMiss(completions: allCompletions, radius: flowConfig.radius)
        let nonzeroBins = yHat.filter { $0 > 0 }.count
        let yHatStats = computeBinStatistics(yHat)

        // Store old parameters for delta computation
        let oldGains = params.gains
        let oldThreshold = params.lifThreshold
        let oldRadialBias = params.radialBias
        let oldSpikeKick = params.spikeKick

        // Update parameters
        ParameterUpdater.updateGains(
            gains: &params.gains,
            yHat: yHat,
            target: targets,
            learningRate: learningConfig.learningRates.gain,
            bounds: learningConfig.bounds.gain
        )

        ParameterUpdater.updateLifThreshold(
            threshold: &params.lifThreshold,
            observedRate: spikeRate,
            targetRate: learningConfig.targetSpikeRate,
            learningRate: learningConfig.learningRates.lif,
            bounds: learningConfig.bounds.theta
        )

        ParameterUpdater.updateRadialBias(
            radialBias: &params.radialBias,
            completionRate: completionRate,
            meanRadialMiss: meanRadialMiss,
            learningRate: learningConfig.learningRates.dynamics,
            bounds: learningConfig.bounds.radialBias
        )

        let binLossTrend = binLoss - previousBinLoss
        ParameterUpdater.updateSpikeKick(
            spikeKick: &params.spikeKick,
            meanRadialMiss: meanRadialMiss,
            binLossTrend: binLossTrend,
            learningRate: learningConfig.learningRates.dynamics,
            bounds: learningConfig.bounds.spikeKick
        )

        previousBinLoss = binLoss

        // Compute parameter deltas
        let gainDeltas = zip(oldGains, params.gains).map { $1 - $0 }
        let gainDeltaMean = gainDeltas.reduce(0, +) / Float(gainDeltas.count)
        let gainDeltaVariance = gainDeltas.map { d in (d - gainDeltaMean) * (d - gainDeltaMean) }.reduce(0, +) / Float(gainDeltas.count)

        let paramDeltas = LearningMetrics.ParameterDeltas(
            gainMean: gainDeltaMean,
            gainVariance: gainDeltaVariance,
            lifThreshold: params.lifThreshold - oldThreshold,
            radialBias: params.radialBias - oldRadialBias,
            spikeKick: params.spikeKick - oldSpikeKick
        )

        // Update router config with new parameters (for next epoch)
        updateRouterConfig()

        return LearningMetrics(
            epoch: epoch,
            totalLoss: totalLoss,
            binLoss: binLoss,
            spikeLoss: spikeLoss,
            boundaryLoss: boundaryLoss,
            spikeRate: spikeRate,
            completionRate: completionRate,
            meanRadialMiss: meanRadialMiss,
            nonzeroBins: nonzeroBins,
            yHatStats: yHatStats,
            paramDeltas: paramDeltas
        )
    }

    /// Returns current learnable parameters
    public func getParameters() -> LearnableParameters {
        return params
    }

    /// Loads parameters from a checkpoint
    public func loadParameters(_ params: LearnableParameters) {
        self.params = params
        updateRouterConfig()
    }

    // MARK: - Private Helpers

    private func updateRouterConfig() {
        // Create new FlowConfig with updated parameters
        let updatedLIF = FlowConfig.LIF(
            decay: flowConfig.lif.decay,
            threshold: params.lifThreshold,
            resetValue: flowConfig.lif.resetValue,
            surrogate: flowConfig.lif.surrogate
        )
        let updatedDynamics = FlowConfig.Dynamics(
            radialBias: params.radialBias,
            noiseStdPos: flowConfig.dynamics.noiseStdPos,
            noiseStdDir: flowConfig.dynamics.noiseStdDir,
            maxSpeed: flowConfig.dynamics.maxSpeed,
            energyAlpha: flowConfig.dynamics.energyAlpha,
            energyFloor: flowConfig.dynamics.energyFloor
        )
        let updatedConfig = FlowConfig(
            T: flowConfig.T,
            radius: flowConfig.radius,
            bins: flowConfig.bins,
            seedLayout: flowConfig.seedLayout,
            seedRadius: flowConfig.seedRadius,
            lif: updatedLIF,
            dynamics: updatedDynamics
        )
        // Note: We need to preserve RNG state, so create new router with same seed would reset it.
        // For now, we manually update the router's cfg field (requires making it mutable or using a different approach)
        // Temporary: recreate router (loses RNG state, acceptable for v0)
        self.router = FlowRouter(cfg: updatedConfig, seed: 0)  // TODO: preserve seed state
    }

    private func computeMeanRadialMiss(completions: [CompletionEvent], radius: Float) -> Float {
        guard !completions.isEmpty else { return 0 }
        let sum: Float = completions.reduce(0.0) { sum, comp in
            let r = length(comp.position)
            return sum + abs(r - radius)
        }
        return sum / Float(completions.count)
    }

    private func computeBinStatistics(_ bins: [Float]) -> LearningMetrics.BinStatistics {
        guard !bins.isEmpty else {
            return LearningMetrics.BinStatistics(mean: 0, variance: 0, min: 0, max: 0)
        }

        let mean = bins.reduce(0, +) / Float(bins.count)
        let variance = bins.map { b in (b - mean) * (b - mean) }.reduce(0, +) / Float(bins.count)
        let min = bins.min() ?? 0
        let max = bins.max() ?? 0

        return LearningMetrics.BinStatistics(mean: mean, variance: variance, min: min, max: max)
    }
}
